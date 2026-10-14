"""Builds the departure boards mod (mod/tf3api_departure_boards) from a board model.

    python -I tools/build_boards.py <folder with the three board models> [--quick] [--preview dots.pgm]
    python -I tools/build_boards.py <board.glb>          (the modern board only)

--quick writes screen 0's texture only (the other 31 take most of the time).

The model is a .glb with the casing as separate parts (boxes with a colour each) and the dot field as one
mesh named LED_Matrix_<columns>x<rows>. What is written:

  - the casing as one mesh, a material for each colour, shading worked out here (the model has none);
  - a flat screen in place of the dot field: the modelled dots (hundreds of thousands of triangles) only say
    where the display is. The screen carries one picture in which every dot is a small block of points, and
    the native layer writes into that picture while the game runs;
  - that picture as the mod ships it: every dot unlit, and over them the message a board shows when nothing
    live has been written to it;
  - a post and an arm to stand it on, a model of the whole in each casing colour, and constructions to place
    it (departures and arrivals, per style), with the pictures the game's menu shows for them.

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

# The styles: which model, the name its files go by, the height of the board's middle, where the arm meets it,
# and the names in the menu.
STYLES = [
    {'id': 'modern', 'file': 'modern', 'base': 'board_modern_pole', 'height': 3.0, 'arm': 'middle',
     'title': 'modern, on a post'},
    {'id': 'heritage', 'file': 'heritage', 'base': 'board_heritage_pole', 'height': 3.0, 'arm': 'middle',
     'title': 'heritage, on a post'},
    {'id': 'hanging', 'file': 'suspended', 'base': 'board_hanging', 'height': 3.2, 'arm': 'top',
     'title': 'hanging, under a canopy'},
]
# The casing colours a board can be built in (the body of the casing; trims and the screen's surround stay).
# None: as the model has it.
CASINGS = [
    ('As designed', None),
    ('Black', (18, 19, 22)),
    ('Network blue', (22, 46, 112)),
    ('Dark grey', (58, 62, 66)),
    ('Silver', (150, 154, 158)),
    ('Green', (22, 78, 52)),
    ('Maroon', (96, 22, 32)),
]
STEEL = (112, 118, 122)


# ---- pictures for the menu ---------------------------------------------------------------------------------
# The game shows a construction's pictures from files beside it: <name>@2x.tga (240 x 150, with
# transparency) in the menu and <name>_preview@2x.tga (720 x 405) when it is pointed at. Rendered here from
# the board itself, with sample departures on its screen.

def sample_dots():
    lit = [[False] * COLUMNS for _ in range(ROWS)]
    # as the native layout puts a departure: the platform keeps 3 columns clear of the expected time
    def departure(time, place, platform, expected):
        right = min(198, 238 - len(board_font.line(expected)) - 3)
        return ('<2 ' + time, '<34 ' + place, '>%d %s' % (right, platform), '>238 ' + expected)
    rows = (departure('10:42', 'Penryn', '2', 'On time'), departure('10:51', 'Falmouth Docks', '1', 'On time'),
            departure('11:03', 'Truro', '3', '11:05'), ('12:34:56',))
    for r, fields in enumerate(rows):
        top = (4, 15, 26, 38)[r]
        for field in fields:
            if field[0] in '<>':
                at, text = field[1:].split(' ', 1)
                columns = board_font.line(text)
                left = int(at) if field[0] == '<' else int(at) - len(columns)
            else:
                text = field
                columns = board_font.line(text)
                left = (COLUMNS - len(columns)) // 2
            for i, column in enumerate(columns):
                if 0 <= left + i < COLUMNS:
                    for row in range(board_font.HEIGHT):
                        if column >> row & 1:
                            lit[top + row][left + i] = True
    return lit


def render(triangles, screen, lit, width, height, background):
    """triangles: ((a, b, c), colour) in the game's frame (face looking along +x); screen: the four corners
    tl, tr, bl, br. Seen from in front, a little from the right and above; drawn twice the size and halved."""
    scale = 2
    W, H = width * scale, height * scale
    yaw, pitch = math.radians(22), math.radians(8)

    def view(p):
        x, y, z = p
        # turn round z so that the face (+x) looks towards the viewer standing at front right
        vx = x * math.cos(yaw) - y * math.sin(yaw)
        vy = x * math.sin(yaw) + y * math.cos(yaw)
        # tilt: looking slightly down
        depth = vx * math.cos(pitch) + z * math.sin(pitch)
        up = -vx * math.sin(pitch) + z * math.cos(pitch)
        return (vy, up, depth)   # right on the picture, up, nearer the viewer

    tl, tr, bl, br = screen
    quads = [((bl, br, tr), 'screen'), ((bl, tr, tl), 'screen')]
    every = [(tuple(view(p) for p in tri), colour, tri) for tri, colour in list(triangles) + quads]
    # framed on the board itself: the post runs off the bottom of the picture
    framed = [p for tri, colour, _w in every if colour != STEEL for p in tri]
    xs = [p[0] for p in framed]
    ys = [p[1] for p in framed]
    span = max((max(xs) - min(xs)) / (W * 0.86), (max(ys) - min(ys)) / (H * 0.62))
    ox, oy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2 - (max(ys) - min(ys)) * 0.12
    light = unit((0.6, 0.5, 0.65))
    pixels = [None] * (W * H)
    depth = [-1e30] * (W * H)
    # the screen's corners as seen, to look up a point of the screen
    for tri, colour, world in every:
        pts = [((p[0] - ox) / span + W / 2, H / 2 - (p[1] - oy) / span, p[2]) for p in tri]
        (x0, y0, z0), (x1, y1, z1), (x2, y2, z2) = pts
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-9:
            continue
        lo_x, hi_x = max(0, int(min(x0, x1, x2))), min(W - 1, int(max(x0, x1, x2)) + 1)
        lo_y, hi_y = max(0, int(min(y0, y1, y2))), min(H - 1, int(max(y0, y1, y2)) + 1)
        if colour == 'screen':
            shade = None
        else:
            n = unit(cross(sub(world[1], world[0]), sub(world[2], world[0])))
            if n[2] < 0:
                n = (-n[0], -n[1], -n[2])
            # direction in the view: light from the viewer's upper right
            lum = 0.45 + 0.55 * max(0.0, n[0] * 0.35 + n[1] * 0.25 + n[2] * 0.9)
            shade = tuple(min(255, int(v * lum)) for v in colour)
        for py in range(lo_y, hi_y + 1):
            for px in range(lo_x, hi_x + 1):
                cx, cy = px + 0.5, py + 0.5
                w0 = ((x1 - cx) * (y2 - cy) - (x2 - cx) * (y1 - cy)) / area
                w1 = ((x2 - cx) * (y0 - cy) - (x0 - cx) * (y2 - cy)) / area
                w2 = 1 - w0 - w1
                if w0 < 0 or w1 < 0 or w2 < 0:
                    continue
                z = w0 * z0 + w1 * z1 + w2 * z2
                k = py * W + px
                if z <= depth[k]:
                    continue
                depth[k] = z
                if shade is not None:
                    pixels[k] = shade
                    continue
                # a point of the screen: which dot it falls on
                sy = w0 * world[0][1] + w1 * world[1][1] + w2 * world[2][1]
                sz = w0 * world[0][2] + w1 * world[1][2] + w2 * world[2][2]
                u = (sy - tl[1]) / (tr[1] - tl[1])
                v = (tl[2] - sz) / (tl[2] - bl[2])
                col = min(COLUMNS - 1, max(0, int(u * COLUMNS)))
                row = min(ROWS - 1, max(0, int(v * ROWS)))
                pixels[k] = LIT if lit[row][col] else UNLIT
    out = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            total, count = [0, 0, 0], 0
            for dy in range(scale):
                for dx in range(scale):
                    p = pixels[(y * scale + dy) * W + x * scale + dx]
                    if p is not None:
                        count += 1
                        for i in range(3):
                            total[i] += p[i]
            if background is None:
                if count:
                    rgb = [t // count for t in total]
                else:
                    rgb = [0, 0, 0]
                alpha = 255 * count // (scale * scale)
            else:
                rgb = [(total[i] + background[i] * (scale * scale - count)) // (scale * scale) for i in range(3)]
                alpha = 255
            out[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes((rgb[2], rgb[1], rgb[0], alpha))
    return bytes(out)


def tga(width, height, bgra, alpha):
    """An uncompressed .tga, rows from the bottom up as the game's own are."""
    bpp = 32 if alpha else 24
    header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, width, height, bpp, 8 if alpha else 0)
    rows = []
    for y in range(height - 1, -1, -1):
        row = bgra[y * width * 4:(y + 1) * width * 4]
        rows.append(row if alpha else b''.join(row[i:i + 3] for i in range(0, len(row), 4)))
    return header + b''.join(rows)


# ---- pictures for the board window (the station plan) ---------------------------------------------------------
# plan_main.tga and plan_overview.tga are what the native layer paints the station into; it knows them by
# their sizes (native/src/boards.h, kPlanWidth / kPlanHeight). As shipped they say what is missing when
# nothing paints into them. The rest are the legend's and the markers' small pictures.

PLAN_SIZES = ((1040, 650), (330, 206))
GROUND = (24, 29, 37)


class Picture:
    def __init__(self, w, h, colour=None):
        self.w, self.h = w, h
        self.px = [[(colour + (255,)) if colour else (0, 0, 0, 0) for _ in range(w)] for _ in range(h)]

    def rect(self, x0, y0, x1, y1, colour):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.px[y][x] = colour + (255,)

    def disc(self, cx, cy, r, colour):
        for y in range(self.h):
            for x in range(self.w):
                d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
                if d <= r + 0.5:
                    a = int(255 * max(0.0, min(1.0, r + 0.5 - d)))
                    old = self.px[y][x]
                    if a >= old[3]:
                        self.px[y][x] = colour + (a,)

    def text(self, text, top, scale, colour):
        columns = board_font.line(text)
        left = (self.w - len(columns) * scale) // 2
        for i, column in enumerate(columns):
            for row in range(board_font.HEIGHT):
                if column >> row & 1:
                    self.rect(left + i * scale, top + row * scale, left + (i + 1) * scale, top + (row + 1) * scale, colour)

    def tga(self):
        rows = b''.join(bytes((p[2], p[1], p[0], p[3])) for row in self.px for p in row)
        return tga(self.w, self.h, rows, True)


def board_icon(colour, selected):
    p = Picture(28, 28)
    if selected:
        p.rect(0, 0, 28, 28, (240, 242, 246))
    p.rect(2, 2, 26, 26, colour)
    p.rect(5, 6, 23, 22, (20, 22, 28))
    for y in (9, 13, 17):
        p.rect(7, y, 21, y + 2, colour)
    return p


def gui_pictures():
    out = os.path.join(OUT, 'content', 'gui', 'tf3api_boards')
    main = Picture(PLAN_SIZES[0][0], PLAN_SIZES[0][1], GROUND)
    main.text('Station plan', 270, 4, (150, 156, 164))
    main.text('drawn by the TF3OpenAPI native layer', 320, 3, (110, 116, 126))
    main.text('(not loaded, or [Boards] Enabled=0)', 356, 3, (110, 116, 126))
    write(os.path.join(out, 'plan_main.tga'), main.tga())
    write(os.path.join(out, 'plan_overview.tga'), Picture(PLAN_SIZES[1][0], PLAN_SIZES[1][1], GROUND).tga())
    for name, colour in (('d', (250, 196, 30)), ('a', (70, 140, 255))):
        write(os.path.join(out, 'icon_board_%s.tga' % name), board_icon(colour, False).tga())
        write(os.path.join(out, 'icon_board_%s_sel.tga' % name), board_icon(colour, True).tga())
    entrance = Picture(28, 28)
    entrance.disc(14, 14, 7, (60, 205, 90))
    write(os.path.join(out, 'icon_entrance.tga'), entrance.tga())
    platform = Picture(28, 28)
    platform.rect(0, 6, 28, 22, (132, 130, 124))
    platform.rect(0, 8, 28, 9, (222, 178, 40))
    platform.rect(0, 19, 28, 20, (222, 178, 40))
    write(os.path.join(out, 'swatch_platform.tga'), platform.tga())
    track = Picture(28, 28)
    track.rect(0, 7, 28, 21, (54, 50, 46))
    for x in range(1, 28, 4):
        track.rect(x, 8, x + 1, 20, (84, 72, 60))
    track.rect(0, 10, 28, 11, (150, 156, 164))
    track.rect(0, 17, 28, 18, (150, 156, 164))
    write(os.path.join(out, 'swatch_track.tga'), track.tga())
    building = Picture(28, 28)
    building.rect(2, 5, 26, 23, (82, 90, 104))
    building.rect(3, 6, 25, 22, (46, 52, 62))
    write(os.path.join(out, 'swatch_building.tga'), building.tga())
    north = Picture(36, 36)           # an arrow pointing up the picture, with an N under it
    for y in range(4, 20):
        half = (y - 4) * 7 // 16
        north.rect(18 - half, y, 18 + half + 1, y + 1, (240, 242, 246))
    north.rect(16, 18, 21, 24, (240, 242, 246))
    north.text('N', 26, 1, (240, 242, 246))
    write(os.path.join(out, 'arrow_north.tga'), north.tga())
    print('window pictures: plan_main %d x %d, plan_overview %d x %d, icons' % (PLAN_SIZES[0] + PLAN_SIZES[1]), flush=True)


# ---- one style ------------------------------------------------------------------------------------------

def build_style(style, source, textures, slots, menu_lit):
    """Writes a style's meshes and models; returns what the constructions and pictures need."""
    tex_dir = 'textures/' + MOD_ID + '/'
    mat_dir = 'models/material/' + MOD_ID + '/'
    mesh_dir = 'models/mesh/' + MOD_ID + '/'
    base = style['base']
    parts = read_glb(source)
    field = [p for p in parts if p['name'].startswith('LED_Matrix')]
    casing = [p for p in parts if not p['name'].startswith('LED_Matrix')]
    if not field or not casing:
        sys.exit('%s: the model needs casing parts and a dot field named LED_Matrix_...' % source)
    lift = style['height']

    def place(p):
        t = turn(p)
        return (t[0], t[1], t[2] + lift)

    # the casing: one group of triangles to a colour; the colour with the most surface is the body
    by_colour, area = {}, {}
    for part in casing:
        triangles = by_colour.setdefault(part['colour'], [])
        order, positions = part['order'], part['positions']
        for i in range(0, len(order) - 2, 3):
            a, b, c = (place(positions[order[i + k]]) for k in range(3))
            triangles.append(((a, (0, 0)), (b, (1, 0)), (c, (1, 1))))
            n = cross(sub(b, a), sub(c, a))
            area[part['colour']] = area.get(part['colour'], 0.0) + 0.5 * math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2)
    body = max(area, key=area.get)
    # a post behind the board, an arm to it at its middle, a foot - not for a hanging board, which hangs from a
    # canopy (its own, on the model)
    pts = [corner[0] for group in by_colour.values() for tri in group for corner in tri]
    back = min(p[0] for p in pts)
    top = max(p[2] for p in pts)
    arm_z = lift if style['arm'] == 'middle' else top - 0.05
    post_top = max(POST_TOP, arm_z + 0.35) if style['arm'] == 'middle' else top + 0.12
    if style['arm'] != 'top':
        stand = by_colour.setdefault(STEEL, [])
        for corners in post(POST_RADIUS, post_top):
            stand.append(tuple(((p[0] - POST_BACK + back, p[1], p[2]), uv) for p, uv in corners))
        stand.extend(box((-POST_BACK + back, -0.04, arm_z - 0.05), (back + 0.01, 0.04, arm_z + 0.05)))
        if style['arm'] == 'top':
            # over the canopy to its middle
            mid_x = (back + max(p[0] for p in pts)) / 2
            stand.extend(box((-POST_BACK + back, -0.04, top + 0.02), (mid_x, 0.04, top + 0.10)))
        stand.extend(box((-POST_BACK + back - 0.15, -0.15, 0.0), (-POST_BACK + back + 0.15, 0.15, 0.015)))

    colours = sorted(by_colour)

    def material_of(colour):
        name = 'colour_%02x%02x%02x' % colour
        if tex_dir + name + '.dds' not in textures:
            content, levels = plain_picture(colour)
            textures[tex_dir + name + '.dds'] = (content, 4, 4, levels)
            write(os.path.join(OUT, 'content', mat_dir + name + '.mtl'), data_file(plain_material('/' + tex_dir + name + '.dds')))
        return '/' + mat_dir + name + '.mtl'

    text, blob = mesh_files([by_colour[c] for c in colours])
    write(os.path.join(OUT, 'content', mesh_dir + base + '.msh'), text)
    write(os.path.join(OUT, 'content', mesh_dir + base + '.msh.blob'), blob)

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
    width, height = COLUMNS * DOT, ROWS * DOT
    screen_mesh = mesh_dir + base.replace('_pole', '') + '_screen_%02d.msh'
    for slot in slots:
        w, h = width + 16 * (slot % 8), height + 16 * (slot // 8)
        u, v = width / w, height / h
        quad = [((bl, (0, v)), (br, (u, v)), (tr, (u, 0))), ((bl, (0, v)), (tr, (u, 0)), (tl, (0, 0)))]
        text, blob = mesh_files([quad])
        write(os.path.join(OUT, 'content', screen_mesh % slot), text)
        write(os.path.join(OUT, 'content', (screen_mesh % slot) + '.blob'), blob)

    everything = [corner[0] for group in by_colour.values() for tri in group for corner in tri] + [tl, tr, bl, br]
    lo = [min(p[k] for p in everything) for k in range(3)]
    hi = [max(p[k] for p in everything) for k in range(3)]

    def model_of(slot, casing_colour):
        materials = [material_of(casing_colour if (casing_colour is not None and c == body) else c) for c in colours]
        return {
            'boundingInfo': {'bbMax': hi, 'bbMin': lo},
            # A box round the whole board: the game finds what is under the mouse by a thing's collider.
            'collider': {
                'params': {'halfExtents': [max((hi[k] - lo[k]) / 2, 0.3) for k in range(3)]},
                'transf': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, 1],
                'type': 'BOX',
            },
            'lods': [{
                'node': {'name': 'RootNode', 'transf': IDENTITY, 'children': [
                    {'name': 'board', 'mesh': '/' + mesh_dir + base + '.msh', 'materials': materials, 'transf': IDENTITY},
                    {'name': 'screen', 'mesh': '/' + screen_mesh % slot, 'materials': ['/' + mat_dir + 'screen_%02d.mtl' % slot], 'transf': IDENTITY},
                ]},
                'static': False, 'visibleFrom': 0, 'visibleTo': 1500,
            }],
            'metadata': {},
            'version': 2,
        }

    for slot in slots:
        if slot != 0 or style['id'] == 'modern':
            write(os.path.join(OUT, 'content', MOD_ID, base + '_%02d.mdl' % slot), data_file(model_of(slot, None)))
    for k, (_name, colour) in enumerate(CASINGS):
        write(os.path.join(OUT, 'content', MOD_ID, base + '_c%d.mdl' % k), data_file(model_of(0, colour)))
    if style['id'] == 'modern':
        # Boards placed before there were screen numbers were built from this model: it stays, as screen 1.
        write(os.path.join(OUT, 'content', MOD_ID, base + '.mdl'), data_file(model_of(0, None)))

    # the menu's pictures
    shaded = [((tri[0][0], tri[1][0], tri[2][0]), c) for c in colours for tri in by_colour[c]]
    icon = render(shaded, (tl, tr, bl, br), menu_lit, 240, 150, None)
    preview = render(shaded, (tl, tr, bl, br), menu_lit, 720, 405, (46, 52, 60))
    pictures = (tga(240, 150, icon, True), tga(720, 405, preview, False))
    triangles = sum(len(g) for g in by_colour.values()) + 2
    print('%s: %d triangles in %d colours (body %s); screen %.3f x %.3f m, dots %.2f mm apart' % (
        style['id'], triangles, len(colours), body, half_w * 2, half_h * 2, pitch * 1000), flush=True)
    return pictures


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args:
        sys.exit(__doc__)
    # one folder holding the three models, or one model (the modern one) as before
    sources = {}
    if len(args) == 1 and os.path.isdir(args[0]):
        for style in STYLES:
            path = os.path.join(args[0], '%s_display_remastered_240x50.glb' % style['file'])
            if os.path.exists(path):
                sources[style['id']] = path
    else:
        sources['modern'] = args[0]
    if 'modern' not in sources:
        sys.exit('the modern model is needed')

    textures = {}        # name in the mod -> (bytes, width, height, levels)
    tex_dir = 'textures/' + MOD_ID + '/'
    mat_dir = 'models/material/' + MOD_ID + '/'
    content, levels = plain_picture((0, 96, 255))   # no metal, some gloss, full ambient light (red, green, blue)
    textures[tex_dir + 'plain_mga.dds'] = (content, 4, 4, levels)

    # One screen texture per number, each of a size of its own (see native/src/boards.h, SlotWidth /
    # SlotHeight): the dots in the top left corner, a black margin the screen's mesh does not show. Every
    # style shares them: the dot grid is the same.
    width, height, rows, lit = screen_picture(FALLBACK, NO_CLOCK)
    only_first = '--quick' in sys.argv     # for a look at the models: screen 0 only
    for slot in range(1 if only_first else SLOTS):
        w, h = width + 16 * (slot % 8), height + 16 * (slot // 8)
        margin = b'\0\0\0\xff'
        padded = b''.join(rows[y * width * 4:(y + 1) * width * 4] + margin * (w - width) for y in range(height)) + margin * (w * (h - height))
        content, levels = dds(w, h, padded)
        textures[tex_dir + 'screen_%02d.dds' % slot] = (content, w, h, levels)
        write(os.path.join(OUT, 'content', mat_dir + 'screen_%02d.mtl' % slot), data_file(screen_material('/' + tex_dir + 'screen_%02d.dds' % slot)))
        print('screen %02d: %d x %d, %d levels' % (slot, w, h, levels), flush=True)
    for old in ('board_modern_screen.msh', 'board_modern_screen.msh.blob'):
        stale = os.path.join(OUT, 'content', 'models/mesh/' + MOD_ID + '/' + old)
        if os.path.exists(stale):
            os.remove(stale)

    menu_lit = sample_dots()
    built = []
    for style in STYLES:
        if style['id'] not in sources:
            continue
        slots = range(SLOTS) if style['id'] == 'modern' else [0]
        pictures = build_style(style, sources[style['id']], textures, slots, menu_lit)
        built.append((style, pictures))

    for name, (content, w, h, levels) in textures.items():
        if not (only_first and name.endswith('.dds') and '/screen_' in name and not name.endswith('_00.dds')):
            write(os.path.join(OUT, 'content', name), content)
    cache = {name: {'channels': 4, 'extent': [w, h], 'numMipmaps': levels, 'numStrippedMipmaps': 0} for name, (c, w, h, levels) in textures.items()}
    if only_first:
        # keep the other screens' entries as a full build wrote them
        for slot in range(1, SLOTS):
            w, h = width + 16 * (slot % 8), height + 16 * (slot // 8)
            cache[tex_dir + 'screen_%02d.dds' % slot] = {'channels': 4, 'extent': [w, h], 'numMipmaps': levels_of(w, h), 'numStrippedMipmaps': 0}
    write(os.path.join(OUT, 'texture_metadata_cache.lua'), data_file(cache))

    # Constructions: per style, departures and arrivals. A board joins the station it is placed at by itself;
    # the casing colour is chosen when it is built (a built board is kept by the game as it was built).
    script = MOD_ID + '::/asset/' + MOD_ID + '/board_modern_pole.con.script'
    casing_param = {
        'key': 'tf3api_casing', 'name': 'Casing colour', 'uiType': 'ComboBox',
        'values': [name for name, _c in CASINGS], 'defaultIndex': 1,
    }
    order = 9000
    for style, (icon, preview) in built:
        for kind, kind_name, what in (('', 'Departures', 'leaving'), ('_arrivals', 'Arrivals', 'approaching')):
            name = style['base'] + kind
            con = {
                # No constructionType (see re_notes/boards/boards.md: what the game makes of a placed board).
                'description': {
                    'name': '%s board (%s)' % (kind_name, style['title']),
                    'description': 'A dot-matrix board showing the vehicles %s a station. Place it within 100 m of the station: it joins it by itself. Click it for its settings. TF3OpenAPI.' % what,
                },
                'availability': {'yearFrom': 0, 'yearTo': 0},
                'order': order,
                'skipCollision': True,
                'autoRemovable': False,
                'menuCategory': {'categories': [{'category': 'rail_buildings', 'filterCategories': [], 'order': order}]},
                'params': [casing_param],
                'updateScript': {'fileName': script + '@updateFn', 'params': {'style': style['base']}},
            }
            order += 1
            write(os.path.join(OUT, 'content', 'asset', MOD_ID, name + '.con.lua'), data_file(con))
            write(os.path.join(OUT, 'content', 'asset', MOD_ID, name + '@2x.tga'), icon)
            write(os.path.join(OUT, 'content', 'asset', MOD_ID, name + '_preview@2x.tga'), preview)
    write(os.path.join(OUT, 'content', 'asset', MOD_ID, 'board_modern_pole.con.script.lua'), '''-- The departure boards' constructions: one model, standing where it is placed.
-- captureParams: what the construction file gives (the style); params: the player's choices (the casing
-- colour, counted from 1) and, for a board the boards' script rebuilt, the screen it uses.
function data()
	return {
		updateFn = function(captureParams, params)
			local style = type(captureParams) == "table" and captureParams.style or "board_modern_pole"
			if style ~= "board_modern_pole" and style ~= "board_heritage_pole" and style ~= "board_hanging" then style = "board_modern_pole" end
			local casing = math.floor(tonumber(type(params) == "table" and params.tf3api_casing or 1) or 1)
			if casing < 1 or casing > CASINGS then casing = 1 end
			local screen = math.floor(tonumber(type(params) == "table" and params.screen or 0) or 0)
			local file
			if style == "board_modern_pole" and casing == 1 and screen >= 1 and screen <= SCREENS then
				file = string.format("%s::/%s/board_modern_pole_%%02d.mdl", screen - 1)
			else
				file = string.format("%s::/%s/%%s_c%%d.mdl", style, casing - 1)
			end
			local transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
			return {
				subconstructions = { {
					models = { { id = file, transf = transf } },
					terrainAlignmentLists = { { type = "EQUAL", faces = { } } },
				} },
			}
		end,
	}
end
'''.replace('SCREENS', str(SLOTS)).replace('CASINGS', str(len(CASINGS))) % (MOD_ID, MOD_ID, MOD_ID, MOD_ID))
    write(os.path.join(OUT, 'mod.json'), json.dumps({
        'modId': MOD_ID, 'revision': 1, 'severityAdd': 'None', 'severityRemove': 'Warning', 'cosmetic': False,
        'name': 'TF3OpenAPI departure boards',
        'description': 'Dot-matrix departures and arrivals boards for stations, in three styles. Place one near a station and it joins it by itself. The live display needs the TF3OpenAPI native layer; without it a board shows its resting message.',
    }, indent=4) + '\n')
    gui_pictures()
    print('styles built:', ', '.join(style['id'] for style, _p in built))
    preview = sys.argv[sys.argv.index('--preview') + 1] if '--preview' in sys.argv else None
    if preview:
        with open(preview, 'wb') as f:      # a plain picture of the dots, for a look: portable grey map
            f.write(b'P5\n%d %d\n255\n' % (COLUMNS * 4, ROWS * 4))
            for row in range(ROWS):
                line = b''.join((b'\xff' if lit[row][c] else b'\x30') * 3 + b'\x00' for c in range(COLUMNS))
                f.write(line * 3 + bytes(COLUMNS * 4))
        print('preview:', preview)


def levels_of(w, h):
    n = 1
    while w > 1 or h > 1:
        w, h = max(1, w // 2), max(1, h // 2)
        n += 1
    return n


if __name__ == '__main__':
    main()
