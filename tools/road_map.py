"""Turn a tf3opt_road_names export into a street map you can open in a browser.

The in-game mod writes <userdata>/tf3opt_road_names/export.lua (roads grouped into named streets, town names).
This script reads that file and writes one self-contained HTML page: a pan-and-zoom street map in the style of
an online map, with street names drawn along the roads and town names on top.

Usage:  python road_map.py <export.lua> [-o map.html] [--title "My map"]
No third-party packages needed.
"""
import argparse
import json
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
  html, body { margin: 0; height: 100%; overflow: hidden; background: #f2efe9; font-family: "Segoe UI", Roboto, Arial, sans-serif; }
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
// streets:  [name, class, length, x, y, segmentCount]
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
const STYLE = {            // fill, casing, minimum width in pixels
  1: ['#ffffff', '#d6d2c8', 1.2],
  2: ['#fdf0a6', '#e0b84f', 2.2],
  3: ['#f9a97a', '#d5683a', 3.0],
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
function drawLabels() {
  const taken = [];
  const free = (x, y, w, h) => { for (const b of taken) if (Math.abs(b[0] - x) < (b[2] + w) / 2 && Math.abs(b[1] - y) < (b[3] + h) / 2) return false; return true; };
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.lineJoin = 'round';
  // towns first: they win the space
  const townSize = Math.max(13, Math.min(26, 11 + view.scale * 40));
  ctx.font = '600 ' + townSize + 'px "Segoe UI", Roboto, Arial, sans-serif';
  for (const t of towns) {
    const x = sx(t.x), y = sy(t.y); if (x < -100 || x > W + 100 || y < -30 || y > H + 30) continue;
    const w = ctx.measureText(t.name).width;
    ctx.lineWidth = 4; ctx.strokeStyle = 'rgba(255,255,255,.9)'; ctx.strokeText(t.name, x, y);
    ctx.fillStyle = '#3a3a3a'; ctx.fillText(t.name, x, y); taken.push([x, y, w + 16, townSize + 10]);
  }
  // streets: longest first; a name is drawn only where it fits on a piece of its own road
  const order = streets.map((s, i) => i).sort((a, b) => (streets[b][1] - streets[a][1]) || (streets[b][2] - streets[a][2]));
  for (const i of order) {
    const st = streets[i], cls = st[1];
    const size = cls === 3 ? 12 : cls === 2 ? 12 : 11;
    if (st[2] * view.scale < 60 && i !== highlight) continue;       // street too short on screen to carry a name
    ctx.font = (cls >= 2 ? '600 ' : '') + size + 'px "Segoe UI", Roboto, Arial, sans-serif';
    const w = ctx.measureText(st[0]).width;
    let placed = 0, lastX = 0, lastY = 0;
    for (const si of byStreet[i]) {
      const s = segs[si];
      if (!visible(s, 0)) continue;
      const ax = sx(s[1]), ay = sy(s[2]), bx = sx(s[3]), by = sy(s[4]);
      const len = Math.hypot(bx - ax, by - ay);
      if (cls !== 3 && len < w * 0.9) continue;                      // does not fit on this piece
      const mx = (ax + bx) / 2, my = (ay + by) / 2;
      if (placed && Math.hypot(mx - lastX, my - lastY) < 420) continue;   // repeat along long streets, not too often
      let ang = Math.atan2(by - ay, bx - ax); if (ang > Math.PI / 2) ang -= Math.PI; if (ang < -Math.PI / 2) ang += Math.PI;
      const bw = Math.abs(Math.cos(ang)) * w + Math.abs(Math.sin(ang)) * size + 6, bh = Math.abs(Math.sin(ang)) * w + Math.abs(Math.cos(ang)) * size + 6;
      if (!free(mx, my, bw, bh)) continue;
      taken.push([mx, my, bw, bh]);
      ctx.save(); ctx.translate(mx, my);
      if (cls === 3) {                                               // route shield
        ctx.fillStyle = '#2f6db5'; const pw = w + 10, ph = size + 6;
        ctx.beginPath(); ctx.roundRect(-pw / 2, -ph / 2, pw, ph, 4); ctx.fill();
        ctx.fillStyle = '#fff'; ctx.fillText(st[0], 0, 0.5);
      } else {
        ctx.rotate(ang);
        ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(255,255,255,.95)'; ctx.strokeText(st[0], 0, 0);
        ctx.fillStyle = i === highlight ? '#c5221f' : '#555'; ctx.fillText(st[0], 0, 0);
      }
      ctx.restore();
      placed++; lastX = mx; lastY = my;
      if (placed >= 6) break;
    }
  }
}
function draw() {
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#f2efe9'; ctx.fillRect(0, 0, W, H);
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
  streets.forEach((s, i) => { if (s[0].toLowerCase().includes(q)) found.push([s[0], s[3], s[4], i, 1.2]); });
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('export')
    ap.add_argument('-o', '--out')
    ap.add_argument('--title', default='Transport Fever 3 street map')
    args = ap.parse_args()

    data = read_export(args.export)
    for key in ('segments', 'streets'):
        if not isinstance(data.get(key), list) or not data[key]:
            sys.exit(f'{args.export}: no "{key}" in the export - was the scan finished?')
    towns = data.get('towns') or []
    if isinstance(towns, dict):
        towns = list(towns.values())
    slim = {
        'segments': [[round(v, 1) if isinstance(v, float) else v for v in row] for row in data['segments']],
        'streets': data['streets'],
        'towns': [{'name': t.get('name', '?'), 'x': t.get('x', 0), 'y': t.get('y', 0)} for t in towns if isinstance(t, dict)],
    }
    title = args.title.replace('<', '&lt;')
    page = PAGE.replace('__TITLE__', title).replace('__DATA__', json.dumps(slim, separators=(',', ':')))
    out = args.out or os.path.splitext(args.export)[0] + '_map.html'
    open(out, 'w', encoding='utf-8').write(page)
    print(f'{out}  ({len(slim["segments"])} segments, {len(slim["streets"])} streets, {len(slim["towns"])} towns)')


if __name__ == '__main__':
    main()
