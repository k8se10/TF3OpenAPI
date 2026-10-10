"""Turn a tf3opt_road_names export into a street map you can open in a browser.

The in-game mod writes <userdata>/tf3opt_road_names/export.lua (roads grouped into named streets, town names).
This script reads that file and writes one self-contained HTML page: a pan-and-zoom street map in the style of
Google Maps as seen in the UK: white streets, yellow main roads, British road-number shields (blue M, green A,
white B), street names drawn along the roads and town names on top.

Usage:  python road_map.py <export.lua> [-o base] [--title "My map"] [--formats html,svg,geojson,osm]

Formats (all are written unless --formats says otherwise):
  html     the interactive map: drag to move, wheel to zoom, search box. One file, no internet needed.
  svg      a fixed vector picture of the whole map, for printing or a drawing program.
  geojson  roads and towns with names, for GIS tools and web map libraries.
  osm      OpenStreetMap XML, for JOSM, Maperitive, QGIS and other OSM tools.
The game map is flat and in metres; geojson and osm place its centre at --lat/--lon (default: central England).
No third-party packages needed.
"""
import argparse
import json
import math
import os
import re
import sys


# ---- Lua table literal reader (the subset the game writes: numbers, strings, booleans, nested tables) ----

class LuaReader:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in ' \t\r\n':
                self.i += 1
            elif s.startswith('--', self.i):
                end = s.find('\n', self.i)
                self.i = n if end < 0 else end + 1
            else:
                break

    def value(self):
        self.ws()
        s = self.s
        c = s[self.i]
        if c == '{':
            return self.table()
        if c in '"\'':
            return self.string()
        m = re.compile(r'-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)').match(s, self.i)
        if m:
            self.i = m.end()
            text = m.group(0)
            if re.fullmatch(r'-?\d+', text):
                return int(text)
            return float(int(text, 16)) if 'x' in text.lower() else float(text)
        m = re.compile(r'[A-Za-z_][A-Za-z0-9_]*').match(s, self.i)
        if m:
            self.i = m.end()
            word = m.group(0)
            if word in ('true', 'false'):
                return word == 'true'
            if word == 'nil':
                return None
            if word in ('inf', 'nan'):
                return 0.0
            raise ValueError(f'unexpected word {word!r} at {m.start()}')
        raise ValueError(f'unexpected character {c!r} at {self.i}')

    def string(self):
        s = self.s
        quote = s[self.i]
        self.i += 1
        out = []
        while s[self.i] != quote:
            c = s[self.i]
            if c == '\\':
                self.i += 1
                e = s[self.i]
                out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(e, e))
            else:
                out.append(c)
            self.i += 1
        self.i += 1
        return ''.join(out)

    def table(self):
        s = self.s
        self.i += 1  # {
        array, mapping = [], {}
        while True:
            self.ws()
            if s[self.i] == '}':
                self.i += 1
                break
            key = None
            if s[self.i] == '[':
                self.i += 1
                key = self.value()
                self.ws()
                assert s[self.i] == ']', f'expected ] at {self.i}'
                self.i += 1
                self.ws()
                assert s[self.i] == '=', f'expected = at {self.i}'
                self.i += 1
            else:
                m = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)').match(s, self.i)
                if m:
                    key = m.group(1)
                    self.i = m.end()
            v = self.value()
            if key is None:
                array.append(v)
            else:
                mapping[key] = v
            self.ws()
            if s[self.i] in ',;':
                self.i += 1
        if not mapping:
            return array
        # integer keys 1..n written explicitly ([1] = ...) are an array too
        if all(isinstance(k, int) for k in mapping) and not array:
            n = len(mapping)
            if set(mapping) == set(range(1, n + 1)):
                return [mapping[k] for k in range(1, n + 1)]
        for index, v in enumerate(array, 1):
            mapping.setdefault(index, v)
        return mapping


def read_export(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    start = text.index('{')
    reader = LuaReader(text)
    reader.i = start
    return reader.value()


# ---- Page -------------------------------------------------------------------------------------------

PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
  html, body { margin: 0; height: 100%; overflow: hidden; background: #f1f3f4; font-family: Roboto, "Segoe UI", Arial, sans-serif; }
  canvas { display: block; width: 100vw; height: 100vh; cursor: grab; }
  canvas.dragging { cursor: grabbing; }
  #panel { position: fixed; left: 12px; top: 12px; background: #fff; border-radius: 8px; padding: 8px 12px;
           box-shadow: 0 1px 4px rgba(0,0,0,.3); font-size: 13px; color: #333; max-width: 70vw; }
  #panel b { font-size: 15px; }
  #search { margin-top: 6px; width: 220px; max-width: 60vw; padding: 5px 8px; border: 1px solid #ccc; border-radius: 4px; font-size: 13px; }
  #hits { margin: 4px 0 0; padding: 0; list-style: none; max-height: 40vh; overflow: auto; }
  #hits li { padding: 3px 4px; cursor: pointer; border-radius: 3px; }
  #hits li:hover { background: #e8f0fe; }
  #zoom { position: fixed; right: 12px; bottom: 28px; display: flex; flex-direction: column; box-shadow: 0 1px 4px rgba(0,0,0,.3); border-radius: 8px; overflow: hidden; }
  #zoom button { width: 36px; height: 36px; border: 0; background: #fff; font-size: 20px; color: #555; cursor: pointer; }
  #zoom button:hover { background: #f1f1f1; }
  #scale { position: fixed; left: 12px; bottom: 10px; font-size: 11px; color: #444; }
  #scale div { border: 2px solid #444; border-top: 0; height: 5px; margin-top: 2px; }
</style></head><body>
<canvas id="map"></canvas>
<div id="panel"><b>__TITLE__</b><br><span id="stats"></span><br>
  <input id="search" placeholder="Find a street or town" autocomplete="off"><ul id="hits"></ul></div>
<div id="zoom"><button id="zin" title="Zoom in">+</button><button id="zout" title="Zoom out">&minus;</button></div>
<div id="scale"><span id="scaleText"></span><div id="scaleBar"></div></div>
<script>
const DATA = __DATA__;
// segments: [street, x0, y0, x1, y1, tx0, ty0, tx1, ty1, width, speed, template, kind]
// streets:  [name, class, length, x, y, segmentCount, road number ("" if none)]
const canvas = document.getElementById('map'), ctx = canvas.getContext('2d');
const segs = DATA.segments, streets = DATA.streets, towns = DATA.towns || [];
let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
for (const s of segs) { minX = Math.min(minX, s[1], s[3]); maxX = Math.max(maxX, s[1], s[3]); minY = Math.min(minY, s[2], s[4]); maxY = Math.max(maxY, s[2], s[4]); }
if (!isFinite(minX)) { minX = minY = 0; maxX = maxY = 1000; }
const view = { x: (minX + maxX) / 2, y: (minY + maxY) / 2, scale: 1 };   // scale = pixels per metre
let W = 0, H = 0, dpr = 1, highlight = -1;

// street -> its segments, longest first (labels go on the longest pieces)
const byStreet = streets.map(() => []);
segs.forEach((s, i) => { if (s[0] >= 1 && s[0] <= streets.length) byStreet[s[0] - 1].push(i); });
const segLen = s => Math.hypot(s[3] - s[1], s[4] - s[2]);
byStreet.forEach(list => list.sort((a, b) => segLen(segs[b]) - segLen(segs[a])));

function resize() {
  dpr = window.devicePixelRatio || 1; W = innerWidth; H = innerHeight;
  canvas.width = W * dpr; canvas.height = H * dpr; draw();
}
function fit() { view.scale = Math.min(W / (maxX - minX + 200), H / (maxY - minY + 200)); view.x = (minX + maxX) / 2; view.y = (minY + maxY) / 2; }
const sx = x => (x - view.x) * view.scale + W / 2;
const sy = y => H / 2 - (y - view.y) * view.scale;        // game north (+y) is up

// A segment is a cubic curve: end points plus the game's tangents (Hermite form -> Bezier control points).
function path(s) {
  ctx.moveTo(sx(s[1]), sy(s[2]));
  const straight = Math.abs(s[5]) + Math.abs(s[6]) + Math.abs(s[7]) + Math.abs(s[8]) < 0.01;
  if (straight) { ctx.lineTo(sx(s[3]), sy(s[4])); return; }
  ctx.bezierCurveTo(sx(s[1] + s[5] / 3), sy(s[2] + s[6] / 3), sx(s[3] - s[7] / 3), sy(s[4] - s[8] / 3), sx(s[3]), sy(s[4]));
}
// Google Maps (UK) look: white local streets, pale yellow main roads, deeper yellow motorways.
const STYLE = {            // fill, casing, minimum width in pixels
  1: ['#ffffff', '#dadce0', 1.2],
  2: ['#fde293', '#f1bf42', 2.2],
  3: ['#f9c74f', '#e69b1f', 3.0],
};
function visible(s, pad) {
  const ax = sx(s[1]), ay = sy(s[2]), bx = sx(s[3]), by = sy(s[4]);
  return Math.max(ax, bx) > -pad && Math.min(ax, bx) < W + pad && Math.max(ay, by) > -pad && Math.min(ay, by) < H + pad;
}
function strokeClass(cls, casing) {
  const st = STYLE[cls];
  ctx.strokeStyle = casing ? st[1] : st[0];
  // roads are drawn by real width once zoomed in, never thinner than the class minimum
  const groups = new Map();
  for (let i = 0; i < segs.length; i++) {
    const s = segs[i];
    if (streets[s[0] - 1][1] !== cls || !visible(s, 60)) continue;
    const real = Math.max(s[9] || 6, 4) * view.scale;
    const w = Math.round(Math.max(st[2], real) * 2) / 2 + (casing ? 2 : 0);
    if (!groups.has(w)) groups.set(w, []);
    groups.get(w).push(s);
  }
  for (const [w, list] of groups) {
    ctx.lineWidth = w; ctx.beginPath();
    for (const s of list) path(s);
    ctx.stroke();
  }
}
function shield(ref, x, y) {
  // British road signs: motorways and A(M) sections = white on blue; primary A roads (one or two digits) =
  // yellow on green; other A roads and B roads = black on white
  const digits = (ref.match(/[0-9]+/) || [''])[0].length;
  const kind = (ref[0] === 'M' || ref.endsWith('(M)')) ? 'M' : (ref[0] === 'A' && digits <= 2) ? 'A' : 'B';
  ctx.font = '700 11px Roboto, "Segoe UI", Arial, sans-serif';
  const w = ctx.measureText(ref).width + 8, h = 16;
  ctx.beginPath(); ctx.roundRect(x - w / 2, y - h / 2, w, h, 3);
  ctx.fillStyle = kind === 'M' ? '#0079c1' : kind === 'A' ? '#00703c' : '#ffffff'; ctx.fill();
  if (kind !== 'M' && kind !== 'A') { ctx.lineWidth = 1; ctx.strokeStyle = '#70757a'; ctx.stroke(); }
  ctx.fillStyle = kind === 'M' ? '#ffffff' : kind === 'A' ? '#ffd200' : '#202124';
  ctx.fillText(ref, x, y + 0.5);
  return [w, h];
}
function drawLabels() {
  const taken = [];
  const free = (x, y, w, h) => { for (const b of taken) if (Math.abs(b[0] - x) < (b[2] + w) / 2 && Math.abs(b[1] - y) < (b[3] + h) / 2) return false; return true; };
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.lineJoin = 'round';
  // towns first: they win the space
  const townSize = Math.max(13, Math.min(24, 11 + view.scale * 40));
  ctx.font = '500 ' + townSize + 'px Roboto, "Segoe UI", Arial, sans-serif';
  for (const t of towns) {
    const x = sx(t.x), y = sy(t.y); if (x < -100 || x > W + 100 || y < -30 || y > H + 30) continue;
    const w = ctx.measureText(t.name).width;
    ctx.lineWidth = 4; ctx.strokeStyle = 'rgba(255,255,255,.95)'; ctx.strokeText(t.name, x, y);
    ctx.fillStyle = '#202124'; ctx.fillText(t.name, x, y); taken.push([x, y, w + 16, townSize + 10]);
  }
  // numbered roads and long streets first
  const order = streets.map((s, i) => i).sort((a, b) => (streets[b][1] - streets[a][1]) || (streets[b][2] - streets[a][2]));
  // road-number shields, repeated along the road
  for (const i of order) {
    const st = streets[i], ref = st[6];
    if (!ref || st[2] * view.scale < 90) continue;
    let placed = 0, lastX = 0, lastY = 0;
    for (const si of byStreet[i]) {
      const s = segs[si];
      if (!visible(s, 0)) continue;
      const mx = (sx(s[1]) + sx(s[3])) / 2, my = (sy(s[2]) + sy(s[4])) / 2;
      if (placed && Math.hypot(mx - lastX, my - lastY) < 380) continue;
      if (!free(mx, my, 40, 20)) continue;
      shield(ref, mx, my); taken.push([mx, my, 40, 20]);
      placed++; lastX = mx; lastY = my;
      if (placed >= 8) break;
    }
  }
  // street names along the road; a name is drawn only where it fits on a piece of its own road
  for (const i of order) {
    const st = streets[i], cls = st[1];
    if (st[0] === st[6]) continue;                                 // motorways are known by number only
    const size = cls === 2 ? 12 : 11;
    if (st[2] * view.scale < 60 && i !== highlight) continue;       // street too short on screen to carry a name
    ctx.font = (cls >= 2 ? '500 ' : '') + size + 'px Roboto, "Segoe UI", Arial, sans-serif';
    const w = ctx.measureText(st[0]).width;
    let placed = 0, lastX = 0, lastY = 0;
    for (const si of byStreet[i]) {
      const s = segs[si];
      if (!visible(s, 0)) continue;
      const ax = sx(s[1]), ay = sy(s[2]), bx = sx(s[3]), by = sy(s[4]);
      const len = Math.hypot(bx - ax, by - ay);
      if (len < w * 0.9) continue;                                   // does not fit on this piece
      const mx = (ax + bx) / 2, my = (ay + by) / 2;
      if (placed && Math.hypot(mx - lastX, my - lastY) < 420) continue;   // repeat along long streets, not too often
      let ang = Math.atan2(by - ay, bx - ax); if (ang > Math.PI / 2) ang -= Math.PI; if (ang < -Math.PI / 2) ang += Math.PI;
      const bw = Math.abs(Math.cos(ang)) * w + Math.abs(Math.sin(ang)) * size + 6, bh = Math.abs(Math.sin(ang)) * w + Math.abs(Math.cos(ang)) * size + 6;
      if (!free(mx, my, bw, bh)) continue;
      taken.push([mx, my, bw, bh]);
      ctx.save(); ctx.translate(mx, my); ctx.rotate(ang);
      ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(255,255,255,.95)'; ctx.strokeText(st[0], 0, 0);
      ctx.fillStyle = i === highlight ? '#c5221f' : '#5f6368'; ctx.fillText(st[0], 0, 0);
      ctx.restore();
      placed++; lastX = mx; lastY = my;
      if (placed >= 6) break;
    }
  }
}
function draw() {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#f1f3f4'; ctx.fillRect(0, 0, W, H);
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const cls of [1, 2, 3]) strokeClass(cls, true);      // casings underneath
  for (const cls of [1, 2, 3]) strokeClass(cls, false);     // fills on top, bigger roads last
  if (highlight >= 0) {
    ctx.strokeStyle = 'rgba(197,34,31,.55)'; ctx.lineWidth = Math.max(5, 10 * view.scale); ctx.beginPath();
    for (const si of byStreet[highlight]) path(segs[si]);
    ctx.stroke();
  }
  drawLabels();
  // scale bar: a round number of metres about 120 px wide
  const target = 120 / view.scale, pow = Math.pow(10, Math.floor(Math.log10(target)));
  const nice = [1, 2, 5, 10].map(m => m * pow).filter(m => m <= target).pop() || pow;
  document.getElementById('scaleBar').style.width = (nice * view.scale) + 'px';
  document.getElementById('scaleText').textContent = nice >= 1000 ? (nice / 1000) + ' km' : nice + ' m';
}
function zoomAt(px, py, factor) {
  const wx = view.x + (px - W / 2) / view.scale, wy = view.y - (py - H / 2) / view.scale;
  view.scale = Math.max(0.01, Math.min(20, view.scale * factor));
  view.x = wx - (px - W / 2) / view.scale; view.y = wy + (py - H / 2) / view.scale; draw();
}
let drag = null;
canvas.addEventListener('pointerdown', e => { drag = [e.clientX, e.clientY]; canvas.classList.add('dragging'); canvas.setPointerCapture(e.pointerId); });
canvas.addEventListener('pointermove', e => { if (!drag) return; view.x -= (e.clientX - drag[0]) / view.scale; view.y += (e.clientY - drag[1]) / view.scale; drag = [e.clientX, e.clientY]; draw(); });
canvas.addEventListener('pointerup', () => { drag = null; canvas.classList.remove('dragging'); });
canvas.addEventListener('wheel', e => { e.preventDefault(); zoomAt(e.clientX, e.clientY, Math.exp(-e.deltaY * 0.0015)); }, { passive: false });
document.getElementById('zin').onclick = () => zoomAt(W / 2, H / 2, 1.5);
document.getElementById('zout').onclick = () => zoomAt(W / 2, H / 2, 1 / 1.5);
addEventListener('resize', resize);

const search = document.getElementById('search'), hits = document.getElementById('hits');
search.addEventListener('input', () => {
  const q = search.value.trim().toLowerCase(); hits.innerHTML = ''; if (q.length < 2) return;
  const found = [];
  towns.forEach(t => { if (t.name.toLowerCase().includes(q)) found.push([t.name + ' (town)', t.x, t.y, -1, 0.35]); });
  streets.forEach((s, i) => { const label = s[6] && s[6] !== s[0] ? s[0] + ' (' + s[6] + ')' : s[0]; if (label.toLowerCase().includes(q)) found.push([label, s[3], s[4], i, 1.2]); });
  for (const f of found.slice(0, 12)) {
    const li = document.createElement('li'); li.textContent = f[0];
    li.onclick = () => { view.x = f[1]; view.y = f[2]; view.scale = Math.max(view.scale, f[4]); highlight = f[3]; draw(); };
    hits.appendChild(li);
  }
});
const km = streets.reduce((a, s) => a + s[2], 0) / 1000;
document.getElementById('stats').textContent = streets.length.toLocaleString() + ' streets, ' + km.toFixed(0) + ' km of road, ' + towns.length + ' towns';
dpr = window.devicePixelRatio || 1; W = innerWidth; H = innerHeight; fit(); resize();
</script></body></html>
'''


# ---- Shared geometry ----------------------------------------------------------------------------------

# segment row: [street, x0, y0, x1, y1, tx0, ty0, tx1, ty1, width, speed, template, kind]
# street row:  [name, class, length, x, y, segmentCount, roadNumber]

def curve_points(seg, steps=8):
    """Points along a segment: a cubic curve from the end points and the game's tangents."""
    x0, y0, x1, y1, tx0, ty0, tx1, ty1 = seg[1:9]
    if abs(tx0) + abs(ty0) + abs(tx1) + abs(ty1) < 0.01:
        return [(x0, y0), (x1, y1)]
    c1 = (x0 + tx0 / 3, y0 + ty0 / 3)
    c2 = (x1 - tx1 / 3, y1 - ty1 / 3)
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        pts.append((u ** 3 * x0 + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * x1,
                    u ** 3 * y0 + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * y1))
    return pts


def bounds(segments):
    xs = [v for s in segments for v in (s[1], s[3])]
    ys = [v for s in segments for v in (s[2], s[4])]
    return min(xs), min(ys), max(xs), max(ys)


# The game works in metres on a flat map. Formats that need latitude/longitude get the map laid over a
# real place (default: the middle of England) with the map centre at that point.
class Projection:
    def __init__(self, segments, lat0, lon0):
        x0, y0, x1, y1 = bounds(segments)
        self.cx, self.cy = (x0 + x1) / 2, (y0 + y1) / 2
        self.lat0, self.lon0 = lat0, lon0
        self.m_per_deg_lat = 111320.0
        self.m_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))

    def lonlat(self, x, y):
        return (round(self.lon0 + (x - self.cx) / self.m_per_deg_lon, 7), round(self.lat0 + (y - self.cy) / self.m_per_deg_lat, 7))


HIGHWAY_TAG = {3: 'motorway', 2: 'primary', 1: 'residential'}


def highway_tag(street):
    """OSM highway value for a street row, following British usage of the tags."""
    ref = street[6] if len(street) > 6 else ''
    if street[1] == 3:
        return 'motorway'
    if ref.startswith('A'):
        return 'primary' if shield_kind(ref) == 'A' else 'secondary'
    if ref.startswith('B'):
        return 'tertiary'
    return 'tertiary' if street[1] == 2 else 'residential'


def shield_kind(ref):
    """British sign colours: 'M' blue (motorways and A(M) sections), 'A' green (primary A roads: one or two
    digits), 'B' white (other A roads and B roads)."""
    digits = len(re.search(r'[0-9]+', ref).group(0)) if re.search(r'[0-9]+', ref) else 0
    if ref.startswith('M') or ref.endswith('(M)'):
        return 'M'
    return 'A' if ref.startswith('A') and digits <= 2 else 'B'


def road_names(street):
    """(name, road number) for a street row; motorways have a number and no separate name."""
    name, ref = street[0], (street[6] if len(street) > 6 else '')
    return ('' if name == ref else name), ref


# ---- GeoJSON ------------------------------------------------------------------------------------------

def write_geojson(data, path, proj):
    features = []
    for seg in data['segments']:
        street = data['streets'][seg[0] - 1]
        name, ref = road_names(street)
        props = {'highway': highway_tag(street), 'street_id': seg[0], 'width_m': seg[9]}
        if name:
            props['name'] = name
        if ref:
            props['ref'] = ref
        kind = str(seg[12]) if len(seg) > 12 else ''
        if 'BRIDGE' in kind.upper():
            props['bridge'] = 'yes'
        if 'TUNNEL' in kind.upper():
            props['tunnel'] = 'yes'
        features.append({'type': 'Feature', 'properties': props,
                         'geometry': {'type': 'LineString', 'coordinates': [proj.lonlat(x, y) for x, y in curve_points(seg)]}})
    for town in data['towns']:
        features.append({'type': 'Feature', 'properties': {'place': 'town', 'name': town['name']},
                         'geometry': {'type': 'Point', 'coordinates': proj.lonlat(town['x'], town['y'])}})
    json.dump({'type': 'FeatureCollection', 'features': features}, open(path, 'w', encoding='utf-8'), separators=(',', ':'))


# ---- OpenStreetMap XML --------------------------------------------------------------------------------

def write_osm(data, path, proj):
    """OSM XML with negative ids (the convention for data that is not in the real OSM database)."""
    def esc(text):
        return (str(text).replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;'))

    node_ids, nodes, ways = {}, [], []

    def node_at(x, y, shared):
        # end points are shared between segments so the road network stays connected
        key = (round(x * 2), round(y * 2)) if shared else None
        if key is not None and key in node_ids:
            return node_ids[key]
        nid = -(len(nodes) + 1)
        lon, lat = proj.lonlat(x, y)
        nodes.append((nid, lat, lon, None))
        if key is not None:
            node_ids[key] = nid
        return nid

    for seg in data['segments']:
        pts = curve_points(seg)
        refs = [node_at(x, y, i == 0 or i == len(pts) - 1) for i, (x, y) in enumerate(pts)]
        street = data['streets'][seg[0] - 1]
        name, ref = road_names(street)
        tags = {'highway': highway_tag(street)}
        if name:
            tags['name'] = name
        if ref:
            tags['ref'] = ref
        kind = str(seg[12]).upper() if len(seg) > 12 else ''
        if 'BRIDGE' in kind:
            tags['bridge'] = 'yes'
        if 'TUNNEL' in kind:
            tags['tunnel'] = 'yes'
        ways.append((refs, tags))
    for town in data['towns']:
        lon, lat = proj.lonlat(town['x'], town['y'])
        nodes.append((-(len(nodes) + 1), lat, lon, {'place': 'town', 'name': town['name']}))

    with open(path, 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<osm version="0.6" generator="tf3opt road_map.py">\n')
        for nid, lat, lon, tags in nodes:
            if tags:
                f.write(f'  <node id="{nid}" lat="{lat}" lon="{lon}">\n')
                for k, v in tags.items():
                    f.write(f'    <tag k="{k}" v="{esc(v)}"/>\n')
                f.write('  </node>\n')
            else:
                f.write(f'  <node id="{nid}" lat="{lat}" lon="{lon}"/>\n')
        for index, (refs, tags) in enumerate(ways, 1):
            f.write(f'  <way id="{-index}">\n')
            for r in refs:
                f.write(f'    <nd ref="{r}"/>\n')
            for k, v in tags.items():
                f.write(f'    <tag k="{k}" v="{esc(v)}"/>\n')
            f.write('  </way>\n')
        f.write('</osm>\n')


# ---- SVG (a fixed picture of the whole map, for printing or editing) ------------------------------------

SVG_STYLE = {1: ('#ffffff', '#dadce0', 1.2), 2: ('#fde293', '#f1bf42', 2.2), 3: ('#f9c74f', '#e69b1f', 3.0)}


def write_svg(data, path, title, max_pixels=6000):
    def esc(text):
        return str(text).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

    segments, streets = data['segments'], data['streets']
    x0, y0, x1, y1 = bounds(segments)
    pad = 100.0
    scale = min(1.0, max_pixels / max(x1 - x0 + 2 * pad, y1 - y0 + 2 * pad))   # pixels per metre
    width, height = (x1 - x0 + 2 * pad) * scale, (y1 - y0 + 2 * pad) * scale

    def px(x, y):
        return (x - x0 + pad) * scale, (y1 - y + pad) * scale   # north up

    def d_of(seg):
        ax, ay = px(seg[1], seg[2])
        bx, by = px(seg[3], seg[4])
        tx0, ty0, tx1, ty1 = seg[5:9]
        if abs(tx0) + abs(ty0) + abs(tx1) + abs(ty1) < 0.01:
            return f'M{ax:.1f} {ay:.1f}L{bx:.1f} {by:.1f}'
        c1 = px(seg[1] + tx0 / 3, seg[2] + ty0 / 3)
        c2 = px(seg[3] - tx1 / 3, seg[4] - ty1 / 3)
        return f'M{ax:.1f} {ay:.1f}C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {bx:.1f} {by:.1f}'

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" viewBox="0 0 {width:.0f} {height:.0f}" '
           f'font-family="Roboto, \'Segoe UI\', Arial, sans-serif">',
           f'<title>{esc(title)}</title>', f'<rect width="100%" height="100%" fill="#f1f3f4"/>']
    for casing in (True, False):
        for cls in (1, 2, 3):
            fill, edge, minimum = SVG_STYLE[cls]
            by_width = {}
            for seg in segments:
                if streets[seg[0] - 1][1] != cls:
                    continue
                w = round(max(minimum, max(seg[9] or 6, 4) * scale) * 2) / 2 + (2 if casing else 0)
                by_width.setdefault(w, []).append(d_of(seg))
            for w, paths in sorted(by_width.items()):
                out.append(f'<path d="{"".join(paths)}" fill="none" stroke="{edge if casing else fill}" stroke-width="{w}" '
                           f'stroke-linecap="round" stroke-linejoin="round"/>')

    # labels: one per street on its longest piece, where the name fits; shields on numbered roads
    by_street = {}
    for seg in segments:
        by_street.setdefault(seg[0], []).append(seg)
    boxes = []

    def free(x, y, w, h):
        for bx, by, bw, bh in boxes:
            if abs(bx - x) < (bw + w) / 2 and abs(by - y) < (bh + h) / 2:
                return False
        boxes.append((x, y, w, h))
        return True

    labels = []
    for town in data['towns']:
        x, y = px(town['x'], town['y'])
        free(x, y, len(town['name']) * 11 + 16, 30)
        labels.append(f'<text x="{x:.1f}" y="{y:.1f}" font-size="20" font-weight="500" text-anchor="middle" dominant-baseline="middle" '
                      f'fill="#202124" stroke="#fff" stroke-width="4" paint-order="stroke" stroke-linejoin="round">{esc(town["name"])}</text>')
    order = sorted(range(len(streets)), key=lambda i: (-streets[i][1], -streets[i][2]))
    for i in order:
        street = streets[i]
        name, ref = road_names(street)
        pieces = sorted(by_street.get(i + 1, []), key=lambda s: -math.hypot(s[3] - s[1], s[4] - s[2]))
        if not pieces:
            continue
        if ref:
            seg = pieces[0]
            x, y = px((seg[1] + seg[3]) / 2, (seg[2] + seg[4]) / 2)
            w = len(ref) * 7 + 8
            if free(x, y, w + 4, 20):
                kind = shield_kind(ref)
                bg, fg = (('#0079c1', '#ffffff') if kind == 'M' else ('#00703c', '#ffd200') if kind == 'A' else ('#ffffff', '#202124'))
                border = '' if kind in 'MA' else ' stroke="#70757a" stroke-width="1"'
                labels.append(f'<rect x="{x - w / 2:.1f}" y="{y - 8:.1f}" width="{w}" height="16" rx="3" fill="{bg}"{border}/>'
                              f'<text x="{x:.1f}" y="{y + 0.5:.1f}" font-size="11" font-weight="700" text-anchor="middle" dominant-baseline="middle" fill="{fg}">{esc(ref)}</text>')
        if not name:
            continue
        size = 12 if street[1] == 2 else 11
        text_w = len(name) * size * 0.55
        for seg in pieces[1:] if ref and len(pieces) > 1 else pieces:
            ax, ay = px(seg[1], seg[2])
            bx, by = px(seg[3], seg[4])
            if math.hypot(bx - ax, by - ay) < text_w * 0.9:
                break   # pieces are longest first: nothing shorter will fit either
            mx, my = (ax + bx) / 2, (ay + by) / 2
            ang = math.degrees(math.atan2(by - ay, bx - ax))
            if ang > 90:
                ang -= 180
            if ang < -90:
                ang += 180
            rad = math.radians(ang)
            if not free(mx, my, abs(math.cos(rad)) * text_w + abs(math.sin(rad)) * size + 6, abs(math.sin(rad)) * text_w + abs(math.cos(rad)) * size + 6):
                continue
            weight = ' font-weight="500"' if street[1] >= 2 else ''
            labels.append(f'<text transform="translate({mx:.1f} {my:.1f}) rotate({ang:.1f})" font-size="{size}"{weight} text-anchor="middle" '
                          f'dominant-baseline="middle" fill="#5f6368" stroke="#fff" stroke-width="3" paint-order="stroke" stroke-linejoin="round">{esc(name)}</text>')
            break
    out.extend(labels)
    out.append('</svg>')
    open(path, 'w', encoding='utf-8').write('\n'.join(out))


# ---- Main ---------------------------------------------------------------------------------------------

FORMATS = ('html', 'svg', 'geojson', 'osm')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('export')
    ap.add_argument('-o', '--out', help='output path without extension (default: next to the export, "<name>_map")')
    ap.add_argument('--title', default='Transport Fever 3 street map')
    ap.add_argument('--formats', default=','.join(FORMATS), help='comma-separated: ' + ', '.join(FORMATS) + ' (default: all)')
    ap.add_argument('--lat', type=float, default=52.5, help='latitude the map centre is placed at for .osm / .geojson (default 52.5)')
    ap.add_argument('--lon', type=float, default=-1.5, help='longitude the map centre is placed at (default -1.5)')
    args = ap.parse_args()

    raw = read_export(args.export)
    for key in ('segments', 'streets'):
        if not isinstance(raw.get(key), list) or not raw[key]:
            sys.exit(f'{args.export}: no "{key}" in the export - was the scan finished?')
    towns = raw.get('towns') or []
    if isinstance(towns, dict):
        towns = list(towns.values())
    data = {
        'segments': [[round(v, 1) if isinstance(v, float) else v for v in row] for row in raw['segments']],
        'streets': [list(row) + [''] * (7 - len(row)) for row in raw['streets']],
        'towns': [{'name': t.get('name', '?'), 'x': t.get('x', 0), 'y': t.get('y', 0)} for t in towns if isinstance(t, dict)],
    }
    wanted = [f.strip().lower() for f in args.formats.split(',') if f.strip()]
    unknown = [f for f in wanted if f not in FORMATS]
    if unknown:
        sys.exit('unknown format(s): ' + ', '.join(unknown) + ' - choose from ' + ', '.join(FORMATS))
    base = args.out or os.path.splitext(args.export)[0] + '_map'
    proj = Projection(data['segments'], args.lat, args.lon)
    written = []
    if 'html' in wanted:
        title = args.title.replace('<', '&lt;')
        open(base + '.html', 'w', encoding='utf-8').write(
            PAGE.replace('__TITLE__', title).replace('__DATA__', json.dumps(data, separators=(',', ':'))))
        written.append(base + '.html')
    if 'svg' in wanted:
        write_svg(data, base + '.svg', args.title)
        written.append(base + '.svg')
    if 'geojson' in wanted:
        write_geojson(data, base + '.geojson', proj)
        written.append(base + '.geojson')
    if 'osm' in wanted:
        write_osm(data, base + '.osm', proj)
        written.append(base + '.osm')
    print(f'{len(data["segments"])} segments, {len(data["streets"])} streets, {len(data["towns"])} towns')
    for path in written:
        print(f'  {path}  ({os.path.getsize(path) / 1024:.0f} KB)')


if __name__ == '__main__':
    main()
