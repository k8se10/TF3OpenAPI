"""Builds the departure boards mod (mod/tf3api_departure_boards) from a board model.

    python -I tools/build_boards.py <board.glb> [--preview preview.png]

The model is a .glb with the casing as separate parts (boxes with a colour each) and the dot field as one
mesh named LED_Matrix_<columns>x<rows>. What is written:

  - the casing as one mesh, a material for each colour, shading worked out here (the model has none);
  - a flat screen in place of the dot field: the modelled dots (hundreds of thousands of triangles) only say
    where the display is. The screen carries one picture in which every dot is a small block of points, and
    the native layer writes into that picture while the game runs;
  - that picture as the mod ships it: every dot unlit, and over them the message a board shows when nothing
    live has been written to it;
  - a post and an arm to stand it on, a model of the whole, and a construction to place it.

Standard library only for reading the model (it is a downloaded file: run with -I).
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import board_font  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_ID = 'tf3api_departure_boards'
OUT = os.path.join(ROOT, 'mod', MOD_ID)

COLUMNS, ROWS = 240, 50
SLOTS = 32           # screens (see native/src/boards.h kSlots)
DOT = 8                      # points of the picture to a dot, each way
UNLIT = (30, 17, 4)          # a dark dot: red, green, blue
LIT = (255, 150, 24)         # a lit one: amber
# where the lines of text start (rows of dots, from the top): three lines and the clock
LINE_TOPS = (4, 15, 26)
CLOCK_TOP = 38
FALLBACK = ('TF3OpenAPI', 'Departure information unavailable', 'github.com/k8se10/TF3OpenAPI')
NO_CLOCK = '--:--:--'

BOARD_HEIGHT = 3.0           # the middle of the board above the ground, metres
POST_RADIUS, POST_TOP, POST_BACK = 0.057, 3.35, 0.20


# ---- reading the model -------------------------------------------------------------------------------

def read_glb(path):
    data = open(path, 'rb').read()
    length = struct.unpack_from('<I', data, 12)[0]
    doc = json.loads(data[20:20 + length])
    blob = data[20 + length + 8:]

    def accessor(index):
        a = doc['accessors'][index]
        view = doc['bufferViews'][a['bufferView']]
        size = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
        kind = {5121: 'B', 5123: 'H', 5125: 'I', 5126: 'f'}[a['componentType']]
        offset = view.get('byteOffset', 0) + a.get('byteOffset', 0)
        flat = struct.unpack_from('<%d%s' % (a['count'] * size, kind), blob, offset)
        return [flat[i:i + size] for i in range(0, len(flat), size)], kind

    parts = []

    def walk(index, at):
        node = doc['nodes'][index]
        move = node.get('translation') or (node['matrix'][12:15] if 'matrix' in node else (0, 0, 0))
        here = [at[k] + move[k] for k in range(3)]
        if 'mesh' in node:
            for primitive in doc['meshes'][node['mesh']]['primitives']:
                positions, _ = accessor(primitive['attributes']['POSITION'])
                positions = [tuple(p[k] + here[k] for k in range(3)) for p in positions]
                colour = (128, 128, 128)
                if 'COLOR_0' in primitive['attributes']:
                    colours, kind = accessor(primitive['attributes']['COLOR_0'])
                    c = colours[0]
                    colour = tuple(int(round(v * 255)) if kind == 'f' else (int(v) >> 8 if kind == 'H' else int(v)) for v in c[:3])
                if 'indices' in primitive:
                    order, _ = accessor(primitive['indices'])
                    order = [i[0] for i in order]
                else:
                    order = list(range(len(positions)))
                parts.append({'name': node.get('name', ''), 'positions': positions, 'order': order, 'colour': colour})
        for child in node.get('children', []):
            walk(child, here)

    for root in doc['scenes'][doc.get('scene', 0)]['nodes']:
        walk(root, (0, 0, 0))
    return parts


def turn(p):
    """The model has its width along x and its face towards +y; in the game the face looks along +x."""
    return (p[1], -p[0], p[2])


# ---- meshes in the game's form -------------------------------------------------------------------------

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def unit(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return (v[0] / n, v[1] / n, v[2] / n) if n > 1e-12 else (0.0, 0.0, 1.0)


def lua(value, indent=''):
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return ('%d' % value) if float(value).is_integer() else ('%.9g' % value)
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'
    if isinstance(value, (list, tuple)):
        if not value:
            return '{ }'   # "{ , }" is not Lua: the game refuses the whole file for it
        if all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in value):
            return '{ ' + ', '.join(lua(v) for v in value) + ', }'
        return '{\n' + ''.join(indent + '\t' + lua(v, indent + '\t') + ',\n' for v in value) + indent + '}'
    if isinstance(value, dict):
        out = '{\n'
        for key in sorted(value):
            name = key if key.isidentifier() else '[' + lua(key) + ']'
            out += indent + '\t' + name + ' = ' + lua(value[key], indent + '\t') + ',\n'
        return out + indent + '}'
    raise TypeError(type(value))


def data_file(value):
    return 'function data()\nreturn ' + lua(value) + '\nend\n'


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = 'wb' if isinstance(content, bytes) else 'w'
    with open(path, mode, **({} if isinstance(content, bytes) else {'encoding': 'utf-8', 'newline': '\n'})) as f:
        f.write(content)


def mesh_files(groups):
    """groups: a list of triangle lists, one list a material; a triangle is three (position, uv) pairs.
    Every corner gets its own point, with the triangle's own direction: flat shading, as the boxes need."""
    uv, normal, tangent, position = b'', b'', b'', b''
    orders = []
    count = 0
    for triangles in groups:
        start = count
        for corners in triangles:
            a, b, c = (corner[0] for corner in corners)
            n = unit(cross(sub(b, a), sub(c, a)))
            t = unit(cross(n, (0.0, 0.0, 1.0)) if abs(n[2]) < 0.9 else (1.0, 0.0, 0.0))
            for corner in corners:
                position += struct.pack('<3f', *corner[0])
                uv += struct.pack('<2f', *corner[1])
                normal += struct.pack('<3f', *n)
                tangent += struct.pack('<4f', t[0], t[1], t[2], 1.0)
                count += 1
        orders.append(struct.pack('<%dI' % (count - start), *range(start, count)))
    blob = uv + normal + tangent + position
    at = len(blob)
    sub_meshes = []
    for order in orders:
        indices = {}
        for name in ('uv0', 'normal', 'tangent', 'position'):
            indices[name] = {'count': len(order), 'offset': at}
            blob += order
            at += len(order)
        sub_meshes.append({'indices': indices})
    description = {
        'subMeshes': sub_meshes,
        'vertexAttr': {
            'uv0': {'count': len(uv), 'numComp': 2, 'offset': 0},
            'normal': {'count': len(normal), 'numComp': 3, 'offset': len(uv)},
            'tangent': {'count': len(tangent), 'numComp': 4, 'offset': len(uv) + len(normal)},
            'position': {'count': len(position), 'numComp': 3, 'offset': len(uv) + len(normal) + len(tangent)},
        },
    }
    return data_file(description), blob


def box(lo, hi):
    x0, y0, z0 = lo
    x1, y1, z1 = hi
    p = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (2, 3, 7, 6), (1, 2, 6, 5), (3, 0, 4, 7)]
    out = []
    for a, b, c, d in faces:
        out.append(((p[a], (0, 0)), (p[b], (1, 0)), (p[c], (1, 1))))
        out.append(((p[a], (0, 0)), (p[c], (1, 1)), (p[d], (0, 1))))
    return out


def post(radius, top, sides=16):
    out = []
    for i in range(sides):
        a0, a1 = 2 * math.pi * i / sides, 2 * math.pi * (i + 1) / sides
        p0 = (radius * math.cos(a0), radius * math.sin(a0))
        p1 = (radius * math.cos(a1), radius * math.sin(a1))
        out.append((((p0[0], p0[1], 0.0), (0, 0)), ((p1[0], p1[1], 0.0), (1, 0)), ((p1[0], p1[1], top), (1, 1))))
        out.append((((p0[0], p0[1], 0.0), (0, 0)), ((p1[0], p1[1], top), (1, 1)), ((p0[0], p0[1], top), (0, 1))))
        out.append((((0.0, 0.0, top), (0, 0)), ((p0[0], p0[1], top), (1, 0)), ((p1[0], p1[1], top), (1, 1))))
    return out


# ---- pictures ------------------------------------------------------------------------------------------

def dds(width, height, rows):
    """An unpacked .dds with every mip level; rows: bytes, blue green red opacity, top row first."""
    levels = [(width, height, rows)]
    w, h, level = width, height, rows
    while w > 1 or h > 1:
        nw, nh = max(1, w // 2), max(1, h // 2)
        smaller = bytearray(nw * nh * 4)
        for y in range(nh):
            for x in range(nw):
                for k in range(4):
                    total = 0
                    for dy in (0, 1):
                        for dx in (0, 1):
                            sx, sy = min(w - 1, x * 2 + dx), min(h - 1, y * 2 + dy)
                            total += level[(sy * w + sx) * 4 + k]
                    smaller[(y * nw + x) * 4 + k] = (total + 2) // 4
        levels.append((nw, nh, bytes(smaller)))
        w, h, level = nw, nh, bytes(smaller)
    header = struct.pack('<4s7I44x', b'DDS ', 124, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | 0x20000, height, width, width * 4, 0, len(levels))
    header += struct.pack('<2I4s5I', 32, 0x41, b'\0\0\0\0', 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    header += struct.pack('<5I', 0x1000 | 0x8 | 0x400000, 0, 0, 0, 0)
    assert len(header) == 128
    return header + b''.join(level[2] for level in levels), len(levels)


def plain_picture(colour, size=4):
    r, g, b = colour
    return dds(size, size, bytes((b, g, r, 255)) * (size * size))


def screen_picture(lines, clock):
    """The board's picture: every dot dark, the given lines lit."""
    lit = [[False] * COLUMNS for _ in range(ROWS)]

    def put(text, top):
        columns = board_font.line(text)
        left = max(0, (COLUMNS - len(columns)) // 2)
        for i, column in enumerate(columns[:COLUMNS - left]):
            for row in range(board_font.HEIGHT):
                if column >> row & 1:
                    lit[top + row][left + i] = True

    for text, top in zip(lines, LINE_TOPS):
        put(text, top)
    if clock:
        put(clock, CLOCK_TOP)
    width, height = COLUMNS * DOT, ROWS * DOT
    # one dot, once: how much of each point of its block the round dot covers
    shape = []
    middle, radius = (DOT - 1) / 2.0, DOT * 0.36
    for y in range(DOT):
        for x in range(DOT):
            d = math.hypot(x - middle, y - middle)
            shape.append(max(0.0, min(1.0, radius + 0.5 - d)))
    rows = bytearray(width * height * 4)
    for row in range(ROWS):
        for column in range(COLUMNS):
            r, g, b = LIT if lit[row][column] else UNLIT
            for y in range(DOT):
                base = ((row * DOT + y) * width + column * DOT) * 4
                for x in range(DOT):
                    cover = shape[y * DOT + x]
                    rows[base + x * 4:base + x * 4 + 4] = bytes((int(b * cover), int(g * cover), int(r * cover), 255))
    return width, height, bytes(rows), lit


# ---- materials, model, construction ----------------------------------------------------------------------

def plain_material(texture):
    return {
        '__version': '', 'order': 0, 'type': 'PHYSICAL',
        'params': {
            'albedo_scale': {'fragmentProperties': [{'albedoScale': [1, 1, 1]}]},
            'fade_out_range': {'vertexProperties': [{'fadeOutEndDist': 20000, 'fadeOutStartDist': 10000}]},
            'light_receiver': {'fragmentProperties': [{'isLegacyMaterial': True, 'lightMask': 2}]},
            'map_albedo': {'fragmentSamplers': {'albedoTex': {'fileName': texture, 'type': 'TWOD', 'wrapS': 'REPEAT', 'wrapT': 'REPEAT'}}},
            'map_metal_gloss_ao': {'fragmentSamplers': {'metalGlossAoTex': {'fileName': '/textures/' + MOD_ID + '/plain_mga.dds', 'type': 'TWOD', 'wrapS': 'REPEAT', 'wrapT': 'REPEAT'}}},
            'polygon_offset': {'fragmentProperties': [{'factor': 0, 'forceDepthWrite': False, 'units': 0}]},
            'two_sided': {'fragmentProperties': [{'flipNormal': True, 'twoSided': False}]},
        },
    }


def screen_material(texture):
    return {
        '__version': '', 'order': 0, 'type': 'EMISSIVE',
        'params': {
            'emissive_scale': {'fragmentProperties': [{'emissiveScale': [4, 4, 4], 'fromTime': 0, 'toTime': 24}]},
            'fade_out_range': {'vertexProperties': [{'fadeOutEndDist': 20000, 'fadeOutStartDist': 10000}]},
            'light_receiver': {'fragmentProperties': [{'isLegacyMaterial': True, 'lightMask': 2}]},
            'map_emissive': {'fragmentSamplers': {'emissiveTex': {
                'compressionAllowed': False, 'fileName': texture, 'magFilter': 'LINEAR', 'minFilter': 'LINEAR_MIPMAP_LINEAR',
                'type': 'TWOD', 'wrapS': 'CLAMP_TO_EDGE', 'wrapT': 'CLAMP_TO_EDGE'}}},
            'polygon_offset': {'fragmentProperties': [{'factor': -1, 'units': -1}]},
            'two_sided': {'fragmentProperties': [{'twoSided': False}]},
        },
    }


IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    source = sys.argv[1]
    preview = sys.argv[sys.argv.index('--preview') + 1] if '--preview' in sys.argv else None
    parts = read_glb(source)
    field = [p for p in parts if p['name'].startswith('LED_Matrix')]
    casing = [p for p in parts if not p['name'].startswith('LED_Matrix')]
    if not field or not casing:
        sys.exit('the model needs casing parts and a dot field named LED_Matrix_...')
    lift = (0.0, 0.0, BOARD_HEIGHT)

    def place(p):
        t = turn(p)
        return (t[0] + lift[0], t[1] + lift[1], t[2] + lift[2])

    textures = {}        # name in the mod -> (bytes, width, height, levels)
    tex_dir = 'textures/' + MOD_ID + '/'
    mat_dir = 'models/material/' + MOD_ID + '/'
    mesh_dir = 'models/mesh/' + MOD_ID + '/'

    # the casing: one group of triangles to a colour
    by_colour = {}
    for part in casing:
        triangles = by_colour.setdefault(part['colour'], [])
        order, positions = part['order'], part['positions']
        for i in range(0, len(order) - 2, 3):
            a, b, c = (place(positions[order[i + k]]) for k in range(3))
            triangles.append(((a, (0, 0)), (b, (1, 0)), (c, (1, 1))))
    # the post and its arm, in a grey of their own
    steel = (112, 118, 122)
    stand = by_colour.setdefault(steel, [])
    for corners in post(POST_RADIUS, POST_TOP):
        stand.append(tuple(((p[0] - POST_BACK, p[1], p[2]), uv) for p, uv in corners))
    back = min(place(p)[0] for part in casing for p in part['positions'])
    stand.extend(box((-POST_BACK, -0.04, BOARD_HEIGHT - 0.05), (back + 0.01, 0.04, BOARD_HEIGHT + 0.05)))
    stand.extend(box((-POST_BACK - 0.15, -0.15, 0.0), (-POST_BACK + 0.15, 0.15, 0.015)))

    colours = sorted(by_colour)
    materials = []
    for index, colour in enumerate(colours):
        name = 'colour_%02x%02x%02x' % colour
        content, levels = plain_picture(colour)
        textures[tex_dir + name + '.dds'] = (content, 4, 4, levels)
        write(os.path.join(OUT, 'content', mat_dir + name + '.mtl'), data_file(plain_material('/' + tex_dir + name + '.dds')))
        materials.append('/' + mat_dir + name + '.mtl')
    content, levels = plain_picture((0, 96, 255))   # no metal, some gloss, full ambient light (red, green, blue)
    textures[tex_dir + 'plain_mga.dds'] = (content, 4, 4, levels)
    text, blob = mesh_files([by_colour[c] for c in colours])
    write(os.path.join(OUT, 'content', mesh_dir + 'board_modern_pole.msh'), text)
    write(os.path.join(OUT, 'content', mesh_dir + 'board_modern_pole.msh.blob'), blob)

    # the screen: where the modelled dots are, with dots as far apart down as across
    xs = [place(p) for p in field[0]['positions']]
    front = max(p[0] for p in xs) + 0.0015
    y0, y1 = min(p[1] for p in xs), max(p[1] for p in xs)
    z0, z1 = min(p[2] for p in xs), max(p[2] for p in xs)
    pitch = min((y1 - y0) / COLUMNS, (z1 - z0) / ROWS)
    half_w, half_h = pitch * COLUMNS / 2, pitch * ROWS / 2
    cy, cz = (y0 + y1) / 2, (z0 + z1) / 2
    # seen from the front (looking along -x) +y is to the right: the picture's left edge is at the low y
    tl, tr = (front, cy - half_w, cz + half_h), (front, cy + half_w, cz + half_h)
    bl, br = (front, cy - half_w, cz - half_h), (front, cy + half_w, cz - half_h)
    # One screen per number: boards at different stations show different things, so each number has a
    # texture of its own. The native layer can tell the game's images apart only by their size, so every
    # screen's texture has a size of its own: the dots in the top left corner, a black margin to the right
    # and below that the screen's mesh does not show (see native/src/boards.h, SlotWidth / SlotHeight).
    width, height, rows, lit = screen_picture(FALLBACK, NO_CLOCK)
    for slot in range(SLOTS):
        w, h = width + 16 * (slot % 8), height + 16 * (slot // 8)
        u, v = width / w, height / h
        quad = [((bl, (0, v)), (br, (u, v)), (tr, (u, 0))), ((bl, (0, v)), (tr, (u, 0)), (tl, (0, 0)))]
        text, blob = mesh_files([quad])
        write(os.path.join(OUT, 'content', mesh_dir + 'board_modern_screen_%02d.msh' % slot), text)
        write(os.path.join(OUT, 'content', mesh_dir + 'board_modern_screen_%02d.msh.blob' % slot), blob)
        margin = b'\0\0\0\xff'
        padded = b''.join(rows[y * width * 4:(y + 1) * width * 4] + margin * (w - width) for y in range(height)) + margin * (w * (h - height))
        content, levels = dds(w, h, padded)
        textures[tex_dir + 'screen_%02d.dds' % slot] = (content, w, h, levels)
        write(os.path.join(OUT, 'content', mat_dir + 'screen_%02d.mtl' % slot), data_file(screen_material('/' + tex_dir + 'screen_%02d.dds' % slot)))
        print('screen %02d: %d x %d, %d levels' % (slot, w, h, levels), flush=True)
    for old in ('board_modern_screen.msh', 'board_modern_screen.msh.blob'):
        stale = os.path.join(OUT, 'content', mesh_dir + old)
        if os.path.exists(stale):
            os.remove(stale)

    for name, (content, w, h, levels) in textures.items():
        write(os.path.join(OUT, 'content', name), content)
    cache = {name: {'channels': 4, 'extent': [w, h], 'numMipmaps': levels, 'numStrippedMipmaps': 0} for name, (c, w, h, levels) in textures.items()}
    write(os.path.join(OUT, 'texture_metadata_cache.lua'), data_file(cache))

    everything = [corner[0] for group in by_colour.values() for tri in group for corner in tri] + [tl, tr, bl, br]
    lo = [min(p[k] for p in everything) for k in range(3)]
    hi = [max(p[k] for p in everything) for k in range(3)]
    def model_of(slot):
      return {
        'boundingInfo': {'bbMax': hi, 'bbMin': lo},
        # A box round the whole board. The game finds what is under the mouse by a thing's collider: without
        # one a board cannot be clicked (the game's own stations and depots have boxes like this).
        'collider': {
            'params': {'halfExtents': [max((hi[k] - lo[k]) / 2, 0.3) for k in range(3)]},
            'transf': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, 1],
            'type': 'BOX',
        },
        'lods': [{
            'node': {'name': 'RootNode', 'transf': IDENTITY, 'children': [
                {'name': 'board', 'mesh': '/' + mesh_dir + 'board_modern_pole.msh', 'materials': materials, 'transf': IDENTITY},
                {'name': 'screen', 'mesh': '/' + mesh_dir + 'board_modern_screen_%02d.msh' % slot, 'materials': ['/' + mat_dir + 'screen_%02d.mtl' % slot], 'transf': IDENTITY},
            ]},
            'static': False, 'visibleFrom': 0, 'visibleTo': 1500,
        }],
        'metadata': {},
        'version': 2,
      }
    for slot in range(SLOTS):
        write(os.path.join(OUT, 'content', MOD_ID, 'board_modern_pole_%02d.mdl' % slot), data_file(model_of(slot)))
    # Boards placed before there were screen numbers were built from this model: it stays, as screen 1, so
    # that a save holding such a board still finds it.
    write(os.path.join(OUT, 'content', MOD_ID, 'board_modern_pole.mdl'), data_file(model_of(0)))

    # Two boards, one model: what a board shows is its kind. No settings: a board joins the station it is
    # placed at by itself; the station and the screen it uses are kept in its settings by our script
    # (params.station, params.screen), not chosen by the player.
    script = MOD_ID + '::/asset/' + MOD_ID + '/board_modern_pole.con.script'
    def construction_of(name, text, order):
        return {
            # No constructionType: an asset (ASSET_DEFAULT) is merged by the game into an "asset group" - it is
            # then no construction any more, cannot be clicked and loses its settings. A plain construction
            # keeps both, as the game's own stations do.
            'description': {'name': name, 'description': text},
            'availability': {'yearFrom': 0, 'yearTo': 0},
            'order': order,
            'skipCollision': True,
            'autoRemovable': False,
            'menuCategory': {'categories': [{'category': 'rail_buildings', 'filterCategories': [], 'order': order}]},
            'params': [],
            'updateScript': {'fileName': script + '@updateFn', 'params': {}},
        }
    write(os.path.join(OUT, 'content', 'asset', MOD_ID, 'board_modern_pole.con.lua'), data_file(construction_of(
        'Departures board for a station',
        'A dot-matrix board showing the vehicles leaving a station. Place it within 100 m of the station: it joins it by itself and stays the board of that station. TF3OpenAPI.', 9000)))
    write(os.path.join(OUT, 'content', 'asset', MOD_ID, 'board_modern_pole_arrivals.con.lua'), data_file(construction_of(
        'Arrivals board for a station',
        'A dot-matrix board showing the vehicles approaching a station. Place it within 100 m of the station: it joins it by itself and stays the board of that station. TF3OpenAPI.', 9001)))
    write(os.path.join(OUT, 'content', 'asset', MOD_ID, 'board_modern_pole.con.script.lua'), '''-- The departure board's construction: one model, standing where it is placed.
function data()
	return {
		updateFn = function(captureParams, params)
			-- the screen this board uses, counted from 1; set by the boards' script when the board joins a station
			-- (never by the player). A board that has joined nothing has none and is built with the first.
			local screen = math.floor(tonumber(type(params) == "table" and params.screen or 1) or 1)
			if screen < 1 or screen > SCREENS then screen = 1 end
			return {
				subconstructions = { {
					models = { {
						id = string.format("%s::/%s/board_modern_pole_%%02d.mdl", screen - 1),
						transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
					} },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
'''.replace('SCREENS', str(SLOTS)) % (MOD_ID, MOD_ID))
    write(os.path.join(OUT, 'mod.json'), json.dumps({
        'modId': MOD_ID, 'revision': 1, 'severityAdd': 'None', 'severityRemove': 'Warning', 'cosmetic': False,
        'name': 'TF3OpenAPI departure boards',
        'description': 'Dot-matrix departures and arrivals boards for stations. Place one near a station and it joins it by itself. The live display needs the TF3OpenAPI native layer; without it a board shows its resting message.',
    }, indent=4) + '\n')

    triangles = sum(len(g) for g in by_colour.values()) + 2
    print('board: %d triangles in %d colours; screen %.3f x %.3f m, dots %.2f mm apart; picture %d x %d, %d levels' % (
        triangles, len(colours), half_w * 2, half_h * 2, pitch * 1000, width, height, levels))
    print('extent', [round(v, 3) for v in lo], [round(v, 3) for v in hi])
    if preview:
        with open(preview, 'wb') as f:      # a plain picture of the dots, for a look: portable grey map
            f.write(b'P5\n%d %d\n255\n' % (COLUMNS * 4, ROWS * 4))
            for row in range(ROWS):
                line = b''.join((b'\xff' if lit[row][c] else b'\x30') * 3 + b'\x00' for c in range(COLUMNS))
                f.write(line * 3 + bytes(COLUMNS * 4))
        print('preview:', preview)


if __name__ == '__main__':
    main()
