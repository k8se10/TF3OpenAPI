-- Generated from PAGE in tools/road_map.py by tools/build_viewer.py. Do not edit; rebuild instead.
-- The street-map viewer page; __TITLE__ and __DATA__ are filled in by the naming script.
return { page = [===[
<!doctype html>
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
  <span id="pc"></span>
  <input id="search" placeholder="Find a street, town or postcode" autocomplete="off"><ul id="hits"></ul></div>
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

// Postcodes, worked out the way the game mod does (core.postcode): the nearest post town gives the outward
// code - inside a city's outline one of the city's own towns - and squares counted from that town give the
// sector and unit; land beyond the town's own block of nine sectors is a further district of it.
const PC = DATA.postcodes, cities = DATA.cities || [], UNIT_LETTERS = 'ABDEFGHJLNPQRSTUWXYZ';
function inOutline(o, x, y) {
  let inside = false;
  for (let i = 0, j = o.length - 2; i < o.length; j = i, i += 2) {
    const xi = o[i], yi = o[i + 1], xj = o[j], yj = o[j + 1];
    if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) inside = !inside;
  }
  return inside;
}
function postcode(x, y) {
  if (!PC || !PC.places || !PC.places.length || !PC.places[0].code) return null;
  let city = 0;
  for (let i = 0; i < cities.length; i++) if (cities[i].outline && inOutline(cities[i].outline, x, y)) { city = i + 1; break; }
  let place = null, best = Infinity;
  for (let pass = 0; pass < 2 && !place; pass++)
    for (const p of PC.places) if (pass === 1 || (p.city || 0) === city) { const d = (x - p.x) ** 2 + (y - p.y) ** 2; if (d < best) { best = d; place = p; } }
  const fx = (x - place.x) / PC.sector + 1.5, fy = (y - place.y) / PC.sector + 1.5;
  const bx = Math.floor(fx / 3), by = Math.floor(fy / 3), ring = Math.max(Math.abs(bx), Math.abs(by));
  let block = 0;
  if (ring > 0) {
    let off;
    if (bx === ring && by > -ring) off = by + ring - 1;
    else if (by === ring) off = 2 * ring + (ring - bx) - 1;
    else if (bx === -ring) off = 4 * ring + (ring - by) - 1;
    else off = 6 * ring + (bx + ring) - 1;
    block = (2 * ring - 1) ** 2 + off;
  }
  const outward = place.code + (place.number + place.count * block);
  const ux = fx - bx * 3, uy = fy - by * 3, cx = Math.min(2, Math.floor(ux)), cy = Math.min(2, Math.floor(uy));
  const lx = Math.min(19, Math.floor((ux - cx) * 20)), ly = Math.min(19, Math.floor((uy - cy) * 20));
  return [outward + ' ' + (1 + cx + 3 * cy) + UNIT_LETTERS[lx] + UNIT_LETTERS[ly], outward, place.name];
}
// motorway junction numbers: white on black, from fairly close
function drawJunctions() {
  if (view.scale < 0.06) return;
  ctx.font = '700 11px Roboto, "Segoe UI", Arial, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  for (const j of DATA.junctions || []) {
    const px = sx(j.x), py = sy(j.y);
    if (px < -20 || py < -20 || px > W + 20 || py > H + 20) continue;
    const text = String(j.number), w = ctx.measureText(text).width + 8;
    ctx.fillStyle = '#181818'; ctx.fillRect(px - w / 2, py - 8, w, 16);
    ctx.fillStyle = '#fff'; ctx.fillText(text, px, py + 0.5);
  }
}
// city outlines and names, under the road labels
function drawCities() {
  for (const c of cities) {
    if (!c.outline || c.outline.length < 6) continue;
    ctx.beginPath();
    for (let i = 0; i < c.outline.length; i += 2) { const px = sx(c.outline[i]), py = sy(c.outline[i + 1]); if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py); }
    ctx.closePath();
    ctx.setLineDash([8, 6]); ctx.lineWidth = 2; ctx.strokeStyle = 'rgba(120,80,160,.75)'; ctx.stroke(); ctx.setLineDash([]);
    ctx.fillStyle = 'rgba(120,80,160,.05)'; ctx.fill();
    if (view.scale < 0.12) {
      ctx.font = '600 22px Roboto, "Segoe UI", Arial, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.lineWidth = 5; ctx.strokeStyle = 'rgba(255,255,255,.95)'; ctx.strokeText(c.name, sx(c.x), sy(c.y));
      ctx.fillStyle = '#4a2f6b'; ctx.fillText(c.name, sx(c.x), sy(c.y));
    }
  }
}

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
    if (!free(x, y, w + 10, townSize + 4)) continue;                 // zoom in to see the towns this one hides
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
    if (!st[0] || st[0] === st[6]) continue;                        // motorways are known by number only; slip roads have no name
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
  drawCities();
  drawLabels();
  drawJunctions();
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
// the postcode under the pointer
canvas.addEventListener('pointermove', e => {
  if (drag) return;
  const code = postcode(view.x + (e.clientX - W / 2) / view.scale, view.y - (e.clientY - H / 2) / view.scale);
  document.getElementById('pc').textContent = code ? code[0] + (code[2] ? ' \u00b7 ' + code[2] : '') : '';
});
canvas.addEventListener('wheel', e => { e.preventDefault(); zoomAt(e.clientX, e.clientY, Math.exp(-e.deltaY * 0.0015)); }, { passive: false });
document.getElementById('zin').onclick = () => zoomAt(W / 2, H / 2, 1.5);
document.getElementById('zout').onclick = () => zoomAt(W / 2, H / 2, 1 / 1.5);
addEventListener('resize', resize);

const search = document.getElementById('search'), hits = document.getElementById('hits');
search.addEventListener('input', () => {
  const q = search.value.trim().toLowerCase(); hits.innerHTML = ''; if (q.length < 2) return;
  const found = [];
  towns.forEach(t => { if (t.name.toLowerCase().includes(q)) found.push([t.name + ' (town)', t.x, t.y, -1, 0.35]); });
  cities.forEach(c => { if (c.name && c.name.toLowerCase().includes(q)) found.push([c.name + ' (city)', c.x, c.y, -1, 0.1]); });
  // a postcode district ("LE4"), or a full postcode's outward part
  if (PC && PC.places) {
    const want = q.toUpperCase().split(' ')[0];
    PC.places.forEach(p => { if (p.code && (p.code + p.number).startsWith(want)) found.push([p.code + p.number + ' \u00b7 ' + p.name + ' (postcode district)', p.x, p.y, -1, 0.5]); });
  }
  streets.forEach((s, i) => { const label = s[6] && s[6] !== s[0] ? s[0] + ' (' + s[6] + ')' : s[0]; if (label && label.toLowerCase().includes(q)) found.push([label, s[3], s[4], i, 1.2]); });
  for (const f of found.slice(0, 12)) {
    const li = document.createElement('li'); li.textContent = f[0];
    li.onclick = () => { view.x = f[1]; view.y = f[2]; view.scale = Math.max(view.scale, f[4]); highlight = f[3]; draw(); };
    hits.appendChild(li);
  }
});
const km = streets.reduce((a, s) => a + s[2], 0) / 1000;
document.getElementById('stats').textContent = streets.length.toLocaleString() + ' streets, ' + km.toFixed(0) + ' km of road, ' + towns.length + ' towns';
dpr = window.devicePixelRatio || 1; W = innerWidth; H = innerHeight; fit();
// a link can open the map at a place: map.html#x,y,pixels-per-metre (game coordinates)
const at = location.hash.slice(1).split(',').map(Number);
if (at.length === 3 && at.every(isFinite) && at[2] > 0) { view.x = at[0]; view.y = at[1]; view.scale = at[2]; }
resize();
</script></body></html>
]===] }
