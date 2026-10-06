// Mapa ilustrado de la red: relieve y ríos esquemáticos, luz solar por longitud, luces urbanas,
// tramos coloreados por línea y tráfico, trenes sobre su trazado, estaciones y obras.
import {CITIES, CITY, PROJECTS} from './data.js';
import {COUNTRIES} from './assets/geography.js';
import {RAILWAYS, RAIL_PATHS} from './assets/railways.js';
import * as S from './schedule.js';
import {sunAltitude, constructionStatus, STAGES} from './operations.js';

// Población aproximada del área urbana (miles) para dimensionar las luces nocturnas.
const POP = {mad: 6700, bcn: 5600, vlc: 1600, ali: 760, mur: 700, car: 215, lor: 95, alm: 200, gra: 530, mal: 1000, sev: 1500, cor: 320, cad: 400, hue: 145,
  alg: 260, ron: 34, ant: 41, jae: 112, cic: 75, pue: 47, cue: 54, alb: 173, xat: 30, enc: 2, cas: 300, tar: 300, gir: 200, fig: 47, zar: 760, lle: 140, huc: 53,
  ter: 36, sag: 68, pam: 370, log: 150, bil: 1000, vit: 255, don: 440, iru: 62, san: 300, bur: 175, pal: 78, vll: 420, seg: 52, leo: 200, ovi: 220, gij: 270,
  fer: 65, aco: 420, scq: 98, vig: 480, pon: 83, our: 105, lug: 98, zam: 60, sal: 150, avi: 57, pla: 40, cac: 96, mer: 60, bad: 150, tol: 85, gua: 87, cal: 20, alc: 30, med: 20};
const FOREIGN = [['Lisboa', -9.14, 38.72, 2900], ['Porto', -8.61, 41.15, 1700], ['Braga', -8.42, 41.55, 190], ['Coimbra', -8.43, 40.2, 140], ['Faro', -7.93, 37.02, 120],
  ['Évora', -7.91, 38.57, 55], ['Toulouse', 1.44, 43.6, 1000], ['Perpignan', 2.9, 42.7, 200], ['Montpellier', 3.88, 43.61, 450], ['Bayonne', -1.47, 43.49, 300],
  ['Andorra', 1.52, 42.51, 80], ['Palma', 2.65, 39.57, 420], ['Eivissa', 1.43, 38.91, 50], ['Maó', 4.26, 39.89, 30], ['Tánger', -5.81, 35.77, 1000],
  ['Tetuán', -5.37, 35.57, 380], ['Ceuta', -5.31, 35.89, 85], ['Gibraltar', -5.35, 36.14, 34], ['Pau', -0.37, 43.3, 150]];
// Relieve y ríos esquemáticos: ilustración orientativa, no cartografía de precisión.
const RANGES = [
  [[-1.9, 43.12], [-0.8, 42.86], [0.0, 42.72], [0.7, 42.66], [1.5, 42.55], [2.4, 42.45], [3.1, 42.45]],
  [[-7.1, 42.85], [-6.0, 42.98], [-5.0, 43.04], [-4.2, 43.05], [-3.5, 43.06], [-2.7, 42.98]],
  [[-7.2, 40.22], [-6.1, 40.3], [-5.3, 40.25], [-4.4, 40.55], [-3.8, 40.85], [-3.2, 41.12]],
  [[-3.0, 42.08], [-2.5, 41.85], [-1.9, 41.42], [-1.5, 40.92], [-1.2, 40.42], [-0.6, 40.12]],
  [[-7.0, 37.96], [-5.8, 38.03], [-4.5, 38.3], [-3.4, 38.36], [-2.6, 38.42]],
  [[-5.4, 36.72], [-4.6, 36.94], [-3.6, 37.06], [-2.9, 37.1], [-2.2, 37.38], [-1.6, 37.88], [-0.9, 38.5], [-0.1, 38.76]],
  [[-5.2, 39.45], [-4.4, 39.46], [-3.9, 39.56]],
  [[-7.7, 42.15], [-7.1, 42.48], [-6.85, 42.82]],
];
const RIVERS = [
  [[-4.18, 43.0], [-3.6, 42.9], [-2.95, 42.68], [-2.45, 42.47], [-1.61, 42.06], [-0.88, 41.66], [-0.04, 41.24], [0.3, 41.37], [0.55, 41.23], [0.52, 40.81], [0.86, 40.72]],
  [[-1.7, 40.4], [-2.59, 40.7], [-3.1, 40.3], [-3.6, 40.03], [-4.02, 39.86], [-4.83, 39.96], [-5.8, 39.78], [-6.88, 39.72], [-8.2, 39.46], [-8.9, 39.0], [-9.1, 38.72]],
  [[-2.85, 41.98], [-2.47, 41.76], [-3.69, 41.67], [-4.7, 41.6], [-5.0, 41.5], [-5.75, 41.5], [-6.27, 41.49], [-7.4, 41.1], [-8.62, 41.14]],
  [[-2.9, 39.0], [-3.93, 39.06], [-5.0, 39.1], [-6.35, 38.92], [-6.97, 38.88], [-7.3, 38.4], [-7.5, 37.8], [-7.4, 37.2]],
  [[-2.95, 37.9], [-3.6, 38.0], [-4.06, 38.04], [-4.78, 37.88], [-5.5, 37.6], [-5.99, 37.38], [-6.2, 37.05], [-6.35, 36.78]],
  [[-7.56, 43.0], [-7.86, 42.34], [-8.3, 42.1], [-8.64, 42.05], [-8.87, 41.9]],
  [[-1.9, 40.3], [-2.13, 40.07], [-2.08, 39.55], [-1.3, 39.25], [-0.43, 39.15], [-0.25, 39.17]],
  [[-2.4, 38.1], [-1.7, 38.23], [-1.13, 37.98], [-0.94, 38.08], [-0.65, 38.09]],
];

const PALETTE = {sea: '#8dbac0', seaDeep: '#6f9fa8', spain: '#ecdfbd', portugal: '#e3dcc0', other: '#ddd8c2', border: '#7d6f5a', rail: '#8f7f62'};

function smoothPath(c, pts) {
  c.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2;
    c.quadraticCurveTo(pts[i][0], pts[i][1], mx, my);
  }
  const l = pts[pts.length - 1];
  c.lineTo(l[0], l[1]);
}
function hash(n) { const x = Math.sin(n * 12.9898) * 43758.5453; return x - Math.floor(x); }
function mix(a, b, t) { return a + (b - a) * t; }

export class RailMap {
  constructor(canvas, opts) {
    Object.assign(this, {canvas, ctx: canvas.getContext('2d'), opts, zoom: 1, pan: {x: 0, y: 0}, layer: 'network', selected: null, selectedTrain: null,
      hover: null, dirty: true, lastFrame: 0, pointers: new Map(), follow: false, lastInteraction: 0});
    this.caches = {base: document.createElement('canvas'), lights: document.createElement('canvas'), lines: document.createElement('canvas'), labels: document.createElement('canvas')};
    this.edgeBox = [];
    for (let i = 0; i < S.EDGE_COUNT; i++) {
      const e = S.edge(i);
      let a = Infinity, b = Infinity, c = -Infinity, d = -Infinity;
      for (const [x, y] of e.pts) { a = Math.min(a, x); b = Math.min(b, y); c = Math.max(c, x); d = Math.max(d, y); }
      this.edgeBox.push([a, b, c, d]);
    }
    new ResizeObserver(() => this.resize()).observe(canvas);
    canvas.addEventListener('wheel', e => { e.preventDefault(); this.zoomAt(this.zoom * (e.deltaY < 0 ? 1.22 : .82), e.offsetX, e.offsetY); }, {passive: false});
    canvas.addEventListener('pointerdown', e => {
      const p = this.local(e); this.pointers.set(e.pointerId, p); canvas.setPointerCapture(e.pointerId);
      this.drag = {id: e.pointerId, x: p[0], y: p[1], px: this.pan.x, py: this.pan.y, moved: false};
      if (this.pointers.size === 2) this.pinch = {distance: this.pointerDistance(), zoom: this.zoom};
    });
    canvas.addEventListener('pointermove', e => {
      const p = this.local(e);
      this.lastPointer = p;
      if (this.pointers.has(e.pointerId)) this.pointers.set(e.pointerId, p);
      if (this.pointers.size === 2 && this.pinch) { this.zoomAt(this.pinch.zoom * this.pointerDistance() / this.pinch.distance); this.drag.moved = true; }
      else if (this.drag?.id === e.pointerId) {
        const dx = p[0] - this.drag.x, dy = p[1] - this.drag.y;
        this.drag.moved ||= Math.hypot(dx, dy) > 4;
        if (this.drag.moved) { this.pan.x = this.drag.px + dx; this.pan.y = this.drag.py + dy; this.follow = false; this.touch(); }
      } else this.hover = this.hit(...p);
      canvas.style.cursor = this.drag?.moved ? 'grabbing' : this.hover ? 'pointer' : 'grab';
    });
    canvas.addEventListener('pointerup', e => {
      if (this.drag && !this.drag.moved && this.pointers.size === 1) { const h = this.hit(...this.local(e)); this.opts.onPick?.(h); }
      this.pointers.delete(e.pointerId); this.drag = null; this.pinch = null;
    });
    canvas.addEventListener('pointercancel', e => { this.pointers.delete(e.pointerId); this.drag = null; this.pinch = null; });
    canvas.addEventListener('pointerleave', () => { this.hover = null; });
    requestAnimationFrame(t => this.render(t));
  }
  touch() { this.lastInteraction = performance.now(); }
  local(e) { const r = this.canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; }
  pointerDistance() { const p = [...this.pointers.values()]; return Math.hypot(p[0][0] - p[1][0], p[0][1] - p[1][1]); }
  resize() {
    const r = this.canvas.getBoundingClientRect();
    this.w = r.width; this.h = r.height; this.dpr = Math.min(devicePixelRatio || 1, 2);
    for (const c of [this.canvas, ...Object.values(this.caches)]) { c.width = Math.max(1, this.w * this.dpr); c.height = Math.max(1, this.h * this.dpr); }
    this.dirty = true;
  }
  get base() { return Math.min((this.w - 40) / 13.2, (this.h - 90) / 10.6); }
  zoomAt(z, x = this.w / 2, y = this.h / 2) {
    const before = this.zoom;
    this.zoom = Math.max(.7, Math.min(260, z));
    const cx = this.w * .5, cy = this.h * .5;
    this.pan.x = x - cx - (x - cx - this.pan.x) * this.zoom / before;
    this.pan.y = y - cy - (y - cy - this.pan.y) * this.zoom / before;
    this.touch();
  }
  project(lon, lat, view = this) {
    const b = this.base * view.zoom;
    return [(lon + 3.6) * b + this.w * .5 + view.pan.x, (40.1 - lat) * b * 1.3 + this.h * .5 + view.pan.y];
  }
  unproject(x, y) {
    const b = this.base * this.zoom;
    return [(x - this.w * .5 - this.pan.x) / b - 3.6, 40.1 - (y - this.h * .5 - this.pan.y) / (b * 1.3)];
  }
  pxPerKm() { return this.base * this.zoom / 85; }
  reset() { this.zoom = 1; this.pan = {x: 0, y: 0}; this.selected = null; this.selectedTrain = null; this.follow = false; this.touch(); this.dirty = true; }
  focusAt(lon, lat, z = 10) { this.zoom = z; this.pan = {x: 0, y: 0}; const p = this.project(lon, lat); this.pan = {x: this.w * .46 - p[0], y: this.h * .5 - p[1]}; this.touch(); }
  fit(points, max = 60) {
    if (!points.length) return;
    let a = Infinity, b = Infinity, c = -Infinity, d = -Infinity;
    for (const [x, y] of points) { a = Math.min(a, x); b = Math.min(b, y); c = Math.max(c, x); d = Math.max(d, y); }
    const span = Math.max((c - a) / 11.5, (d - b) / 8.6, .004);
    this.focusAt((a + c) / 2, (b + d) / 2, Math.min(max, Math.max(1, .82 / span)));
  }
  routeCoords(id) {
    const edges = S.routeEdges(id);
    if (edges.length) return edges.flatMap(i => S.edge(i).pts);
    const path = RAIL_PATHS[id];
    if (path?.coordinates) return path.coordinates;
    const r = this.opts.getState().routes.find(r => r.id === id);
    return r ? r.via.map(c => [CITY[c].lon, CITY[c].lat]) : [];
  }
  focus(id, zoom = true) { this.selected = id; this.dirty = true; if (zoom) this.fit(this.routeCoords(id)); }

  // ------------------------------------------------------------ interacción
  hit(x, y) {
    const v = this.opts.getView();
    // 1. Trenes
    let best = null, bd = 11;
    for (const p of this.trainPoints || []) { const d = Math.hypot(p.x - x, p.y - y); if (d < bd) { bd = d; best = {type: 'train', id: p.id}; } }
    if (best) return best;
    // 2. Obras
    for (const w of this.workPoints || []) if (Math.hypot(w.x - x, w.y - y) < 14) return {type: 'work', id: w.id};
    // 3. Estaciones
    if (this.zoom >= 4) {
      bd = this.zoom > 12 ? 9 : 6;
      for (const s of this.stationPoints || []) { const d = Math.hypot(s.x - x, s.y - y); if (d < bd) { bd = d; best = {type: 'station', id: s.id}; } }
      if (best) return best;
    }
    // 4. Tramos de la red
    const [lon, lat] = this.unproject(x, y), tol = 9 / (this.base * this.zoom);
    const usage = S.edgeUsage(v.dayType || 'L'), state = this.opts.getState(), active = new Set(state.routes.filter(r => r.active).map(r => r.id));
    bd = 9;
    for (let i = 0; i < this.edgeBox.length; i++) {
      const b = this.edgeBox[i];
      if (lon < b[0] - tol || lon > b[2] + tol || lat < b[1] - tol || lat > b[3] + tol) continue;
      const e = S.edge(i), pts = e.pts.map(p => this.project(p[0], p[1]));
      for (let k = 1; k < pts.length; k++) {
        const a = pts[k - 1], c = pts[k], dx = c[0] - a[0], dy = c[1] - a[1];
        const t = Math.max(0, Math.min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy || 1)));
        const d = Math.hypot(x - a[0] - t * dx, y - a[1] - t * dy);
        if (d < bd) {
          const u = usage.get(i);
          if (!u) continue;
          const routes = [...u.routes.entries()].sort((p, q) => (active.has(q[0]) - active.has(p[0])) || q[1] - p[1]);
          bd = d; best = {type: 'route', id: routes[0][0], edge: i};
        }
      }
    }
    if (best) return best;
    // 5. Corredores de campaña sin horario (geometría OSM o conceptual)
    for (const r of state.routes) {
      if (r.real) continue;
      const pts = this.routeCoords(r.id).map(p => this.project(p[0], p[1]));
      for (let k = 1; k < pts.length; k++) {
        const a = pts[k - 1], c = pts[k], dx = c[0] - a[0], dy = c[1] - a[1];
        const t = Math.max(0, Math.min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy || 1)));
        if (Math.hypot(x - a[0] - t * dx, y - a[1] - t * dy) < 7) return {type: 'route', id: r.id};
      }
    }
    return null;
  }

  // ------------------------------------------------------------ capas en caché
  ctxOf(name) { const c = this.caches[name].getContext('2d'); c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0); c.clearRect(0, 0, this.w, this.h); return c; }
  visible(p, m = 60) { return p[0] > -m && p[0] < this.w + m && p[1] > -m && p[1] < this.h + m; }

  drawBase() {
    const c = this.ctxOf('base'), w = this.w, h = this.h, z = this.zoom;
    const sea = c.createLinearGradient(0, 0, w, h);
    sea.addColorStop(0, '#9cc6cb'); sea.addColorStop(1, PALETTE.seaDeep);
    c.fillStyle = sea; c.fillRect(0, 0, w, h);
    const polys = [];
    for (const f of COUNTRIES) for (const rings of (f.geometry.type === 'Polygon' ? [f.geometry.coordinates] : f.geometry.coordinates)) polys.push([f.id, rings]);
    // halo costero
    c.save();
    c.lineJoin = 'round';
    for (const [, rings] of polys) { c.beginPath(); for (const ring of rings) ring.forEach(([lon, lat], i) => { const p = this.project(lon, lat); i ? c.lineTo(...p) : c.moveTo(...p); }); c.strokeStyle = 'rgba(214,236,232,.55)'; c.lineWidth = Math.min(26, 7 * Math.sqrt(z)); c.stroke(); c.strokeStyle = 'rgba(232,245,240,.5)'; c.lineWidth = Math.min(10, 3 * Math.sqrt(z)); c.stroke(); }
    c.restore();
    for (const [id, rings] of polys) {
      c.beginPath();
      for (const ring of rings) { ring.forEach(([lon, lat], i) => { const p = this.project(lon, lat); i ? c.lineTo(...p) : c.moveTo(...p); }); c.closePath(); }
      c.fillStyle = id === 'ESP' ? PALETTE.spain : id === 'PRT' ? PALETTE.portugal : PALETTE.other;
      c.fill('evenodd');
      c.strokeStyle = id === 'ESP' || id === 'PRT' ? 'rgba(96,82,60,.55)' : 'rgba(96,82,60,.3)';
      c.lineWidth = id === 'ESP' || id === 'PRT' ? 1.1 : .7;
      c.setLineDash(id === 'ESP' ? [] : []);
      c.stroke();
    }
    // textura de papel
    c.save(); c.globalAlpha = .05;
    for (let i = 0; i < 900; i++) { const x = hash(i) * w, y = hash(i + 999) * h; c.fillStyle = i % 2 ? '#5b4a2c' : '#fff'; c.fillRect(x, y, 1.2, 1.2); }
    c.restore();
    // relieve: sombra suave y picos ilustrados a lo largo de cada sierra
    const kmPx = this.pxPerKm();
    c.save(); c.lineCap = 'round'; c.lineJoin = 'round';
    for (const [ri, range] of RANGES.entries()) {
      const pts = range.map(([lon, lat]) => this.project(lon, lat));
      for (const [width, alpha] of [[90, .018], [60, .026], [34, .034]]) {
        c.beginPath(); smoothPath(c, pts); c.strokeStyle = `rgba(120,92,58,${alpha})`; c.lineWidth = Math.max(4, width * kmPx); c.stroke();
      }
      // picos: lado iluminado al noroeste y sombreado al sureste
      const step = Math.max(7, 13 * kmPx), size = Math.max(5, Math.min(26, 11 * kmPx));
      let acc = 0;
      for (let k = 1; k < pts.length; k++) {
        const a = pts[k - 1], b = pts[k], L = Math.hypot(b[0] - a[0], b[1] - a[1]);
        for (let d = acc; d < L; d += step) {
          const f = d / L, seed = ri * 1000 + k * 37 + Math.round(d), x = mix(a[0], b[0], f) + (hash(seed) - .5) * size * 1.6, y = mix(a[1], b[1], f) + (hash(seed + 1) - .5) * size * 1.2;
          const hgt = size * (.7 + hash(seed + 2) * .7), wid = hgt * (.9 + hash(seed + 3) * .5);
          if (x < -40 || x > this.w + 40 || y < -40 || y > this.h + 40) continue;
          c.beginPath(); c.moveTo(x - wid, y); c.lineTo(x, y - hgt); c.lineTo(x + wid, y); c.closePath();
          c.fillStyle = 'rgba(214,190,146,.55)'; c.fill();
          c.beginPath(); c.moveTo(x, y - hgt); c.lineTo(x + wid, y); c.lineTo(x + wid * .15, y); c.closePath();
          c.fillStyle = 'rgba(122,92,58,.32)'; c.fill();
          c.beginPath(); c.moveTo(x - wid, y); c.lineTo(x, y - hgt); c.lineTo(x + wid, y);
          c.strokeStyle = 'rgba(96,72,44,.42)'; c.lineWidth = Math.max(.7, Math.min(1.4, size / 12)); c.stroke();
          if (hgt > 9 && hash(seed + 4) > .55) { c.beginPath(); c.moveTo(x - wid * .22, y - hgt * .78); c.lineTo(x, y - hgt); c.lineTo(x + wid * .18, y - hgt * .8); c.strokeStyle = 'rgba(255,252,240,.8)'; c.stroke(); }
        }
        acc = (acc - L) % step; if (acc < 0) acc += step;
      }
    }
    c.restore();
    // ríos
    c.save(); c.lineCap = 'round'; c.lineJoin = 'round';
    for (const river of RIVERS) { c.beginPath(); smoothPath(c, river.map(([lon, lat]) => this.project(lon, lat))); c.strokeStyle = 'rgba(92,150,170,.55)'; c.lineWidth = Math.max(1, Math.min(3.2, .9 * Math.sqrt(z))); c.stroke(); }
    c.restore();
    // vías OSM (base)
    c.lineWidth = z > 6 ? 1.2 : z > 2.5 ? .8 : .5; c.strokeStyle = z > 6 ? 'rgba(110,95,70,.55)' : 'rgba(120,104,78,.38)';
    c.beginPath();
    for (const seg of RAILWAYS) {
      const co = seg.c, a = this.project(co[0][0], co[0][1]), b = this.project(co[co.length - 1][0], co[co.length - 1][1]);
      if ((a[0] < -50 && b[0] < -50) || (a[0] > w + 50 && b[0] > w + 50) || (a[1] < -50 && b[1] < -50) || (a[1] > h + 50 && b[1] > h + 50)) continue;
      c.moveTo(a[0], a[1]);
      for (let i = 1; i < co.length; i++) { const q = this.project(co[i][0], co[i][1]); c.lineTo(q[0], q[1]); }
    }
    c.stroke();
    // nombres de mares y países
    c.save(); c.textAlign = 'center'; c.font = `italic 500 ${Math.round(13 + Math.min(6, z))}px Fraunces, Georgia, serif`; c.fillStyle = 'rgba(48,86,96,.55)';
    for (const [name, lon, lat] of [['Océano Atlántico', -11.2, 41.2], ['Mar Mediterráneo', 2.3, 38.4], ['Mar Cantábrico', -5.5, 44.25], ['Golfo de Cádiz', -7.4, 36.4]]) { const p = this.project(lon, lat); if (this.visible(p)) { c.letterSpacing = '2px'; c.fillText(name, ...p); } }
    c.font = `600 ${Math.round(11 + Math.min(5, z))}px Figtree, sans-serif`; c.fillStyle = 'rgba(90,78,58,.42)';
    for (const [name, lon, lat] of [['PORTUGAL', -8.0, 39.6], ['FRANCIA', 0.9, 44.0], ['ANDORRA', 1.55, 42.62], ['MARRUECOS', -5.4, 35.25]]) { const p = this.project(lon, lat); if (this.visible(p)) { c.letterSpacing = '4px'; c.fillText(name, ...p); } }
    c.restore();
  }

  drawLights() {
    const c = this.ctxOf('lights'), z = this.zoom, s = Math.sqrt(z);
    c.globalCompositeOperation = 'lighter';
    const glow = (x, y, r, a) => {
      if (x < -r || x > this.w + r || y < -r || y > this.h + r) return;
      const g = c.createRadialGradient(x, y, 0, x, y, r);
      g.addColorStop(0, `rgba(255,214,140,${a})`); g.addColorStop(.25, `rgba(255,170,80,${a * .55})`); g.addColorStop(1, 'rgba(255,140,60,0)');
      c.fillStyle = g; c.fillRect(x - r, y - r, r * 2, r * 2);
    };
    for (const city of CITIES) { const p = this.project(city.lon, city.lat), pop = POP[city.id] || 30; glow(p[0], p[1], Math.max(6, Math.sqrt(pop) * 1.25 * s), Math.min(.95, .35 + pop / 4000)); }
    for (const [, lon, lat, pop] of FOREIGN) { const p = this.project(lon, lat); glow(p[0], p[1], Math.max(5, Math.sqrt(pop) * 1.1 * s), Math.min(.8, .3 + pop / 5000)); }
    for (const st of S.STATIONS) { if (!st.traffic) continue; const p = this.project(st.lon, st.lat); glow(p[0], p[1], Math.max(3, Math.sqrt(st.traffic) * .5 * Math.min(s, 4)), .22); }
    // centelleo urbano: puntos de alumbrado alrededor de las ciudades grandes
    c.fillStyle = 'rgba(255,220,150,.85)';
    for (const city of CITIES) {
      const pop = POP[city.id] || 30, n = Math.min(160, Math.round(Math.sqrt(pop) * 2.4)), p = this.project(city.lon, city.lat);
      if (!this.visible(p, 200)) continue;
      for (let i = 0; i < n; i++) { const a = hash(i * 7 + city.lon * 100) * Math.PI * 2, r = Math.pow(hash(i * 13 + city.lat * 100), 1.6) * Math.sqrt(pop) * 1.5 * s; c.fillRect(p[0] + Math.cos(a) * r, p[1] + Math.sin(a) * r, 1.1, 1.1); }
    }
    c.globalCompositeOperation = 'source-over';
  }

  lineColor(line) { return S.LINES[line]?.color || '#8a3550'; }

  drawLines(view, night) {
    const c = this.ctxOf('lines'), state = this.opts.getState(), z = this.zoom;
    const usage = S.edgeUsage(view.dayType || 'L');
    const active = new Map(state.routes.filter(r => r.active).map(r => [r.id, r]));
    const real = view.mode === 'real', works = this.layer === 'works';
    const zw = Math.min(3.2, Math.max(1, Math.pow(z, .38)));
    c.lineCap = 'round'; c.lineJoin = 'round';
    const draw = (pts, color, width, dash = null, alpha = 1) => {
      c.beginPath();
      pts.forEach(([lon, lat], k) => { const p = this.project(lon, lat); k ? c.lineTo(p[0], p[1]) : c.moveTo(p[0], p[1]); });
      c.setLineDash(dash || []); c.globalAlpha = alpha; c.strokeStyle = color; c.lineWidth = width; c.stroke(); c.globalAlpha = 1; c.setLineDash([]);
    };
    const items = [];
    for (const [i, u] of usage) {
      const b = this.edgeBox[i], p1 = this.project(b[0], b[3]), p2 = this.project(b[2], b[1]);
      if (p2[0] < -20 || p1[0] > this.w + 20 || p2[1] < -20 || p1[1] > this.h + 20) continue;
      let count = 0, best = null, bestN = 0;
      if (real) { count = u.count; for (const [line, n] of u.lines) if (n > bestN) { bestN = n; best = line; } }
      else {
        for (const [rid, n] of u.routes) { const r = active.get(rid); if (!r) continue; const share = Math.min(1, r.frequency / (r.baseFrequency || 1)); count += n * share; }
        if (count) { const lines = [...u.lines.entries()].sort((a, b) => b[1] - a[1]); for (const [line] of lines) { best = line; break; } }
      }
      items.push({i, count, best, bus: u.bus === u.count});
    }
    // tramos sin servicio (por recuperar) primero
    for (const it of items) if (!it.count) draw(S.edge(it.i).pts, night > .5 ? 'rgba(210,200,170,.35)' : 'rgba(110,96,74,.45)', Math.max(.8, zw * .8), [2, 4]);
    items.sort((a, b) => a.count - b.count);
    const served = items.filter(it => it.count).map(it => ({...it, e: S.edge(it.i), width: (0.9 + Math.log2(1 + it.count) * .42) * zw * (works ? .6 : 1)}));
    // primero todos los contornos y después los colores: así los tramos consecutivos no se cortan
    if (!works) for (const it of served) if (!it.bus && !it.e.approx) draw(it.e.pts, night > .5 ? 'rgba(10,16,30,.55)' : 'rgba(255,250,236,.85)', it.width + 2.4 * Math.min(2, zw));
    for (const it of served) {
      const color = works ? 'rgba(120,110,90,.6)' : it.bus ? '#c98a1c' : this.lineColor(it.best);
      draw(it.e.pts, color, it.width, it.bus || it.e.approx === 2 ? [4, 4] : it.e.approx ? [6, 3] : null, works ? .7 : 1);
    }
    // corredores activos sin horario publicado: trazado OSM o enlace conceptual
    for (const r of state.routes) {
      if (r.real || (!r.active && !works)) continue;
      const pts = this.routeCoords(r.id), osm = !!RAIL_PATHS[r.id];
      if (pts.length < 2) continue;
      draw(pts, r.active ? '#8a3550' : 'rgba(120,100,80,.5)', r.active ? 2.4 * zw : 1.2, osm && !r.custom ? null : [3, 6]);
    }
  }

  drawLabels(night) {
    const c = this.ctxOf('labels'), z = this.zoom, boxes = [];
    const place = (x, y, wd, ht) => { for (const b of boxes) if (x < b[2] && x + wd > b[0] && y < b[3] && y + ht > b[1]) return false; boxes.push([x, y, x + wd, y + ht]); return true; };
    const label = (text, x, y, size, weight, major) => {
      c.font = `${weight} ${size}px Figtree, 'Segoe UI', sans-serif`;
      const wd = c.measureText(text).width;
      if (!place(x + 6, y - size - 4, wd + 4, size + 6)) return;
      c.lineWidth = 3.4; c.strokeStyle = night > .5 ? 'rgba(10,15,30,.85)' : 'rgba(245,238,218,.92)'; c.strokeText(text, x + 7, y - 6);
      c.fillStyle = night > .5 ? (major ? '#ffe9bf' : '#e5d6b4') : (major ? '#2b2620' : '#4b4234'); c.fillText(text, x + 7, y - 6);
    };
    const cities = CITIES.map(ci => ({...ci, pop: POP[ci.id] || 20})).sort((a, b) => b.pop - a.pop);
    for (const ci of cities) {
      const threshold = z < 1.3 ? 300 : z < 2.2 ? 120 : z < 4 ? 45 : 0;
      if (ci.pop < threshold) continue;
      const p = this.project(ci.lon, ci.lat);
      if (!this.visible(p, 10)) continue;
      const major = ci.pop >= 700, size = Math.round((major ? 15 : ci.pop > 200 ? 13 : 12) + Math.min(5, Math.log2(z) * 1.2));
      c.fillStyle = night > .5 ? '#fff0c8' : '#3c2f2a';
      c.beginPath(); c.arc(p[0], p[1], major ? 3.6 : 2.4, 0, Math.PI * 2); c.fill();
      label(ci.name, p[0], p[1], size, major ? 700 : 600, major);
    }
    if (z >= 7) {
      const list = S.STATIONS.filter(s => s.traffic).sort((a, b) => b.traffic - a.traffic);
      for (const st of list) {
        if (z < 14 && st.traffic < 120) continue;
        if (z < 24 && st.traffic < 30) continue;
        const p = this.project(st.lon, st.lat);
        if (!this.visible(p, 10)) continue;
        label(st.name, p[0], p[1] + 14, Math.round(11 + Math.min(3, z / 30)), 500, false);
      }
    }
  }

  renderCaches(view, night) {
    this.drawBase(); this.drawLights(); this.drawLines(view, night); this.drawLabels(night);
    this.snap = {zoom: this.zoom, pan: {...this.pan}, night: night > .5, layer: this.layer, mode: view.mode, key: view.networkKey};
    this.dirty = false;
  }

  blit(name, alpha = 1) {
    const c = this.ctx, s = this.zoom / this.snap.zoom, cx = this.w * .5, cy = this.h * .5;
    c.setTransform(this.dpr * s, 0, 0, this.dpr * s, this.dpr * (cx + this.pan.x - s * (cx + this.snap.pan.x)), this.dpr * (cy + this.pan.y - s * (cy + this.snap.pan.y)));
    c.globalAlpha = alpha; c.drawImage(this.caches[name], 0, 0, this.w, this.h); c.globalAlpha = 1;
    c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
  }

  // ------------------------------------------------------------ fotograma
  render(t) {
    requestAnimationFrame(t => this.render(t));
    if (!this.w || t - this.lastFrame < 33 || document.hidden) return;
    this.lastFrame = t;
    const view = this.opts.getView(), c = this.ctx, w = this.w, h = this.h;
    const minute = view.minute ?? 840, date = view.date;
    // Luz por longitud: el ocaso avanza de este a oeste sobre la península.
    const [wl] = this.unproject(0, h / 2), [el] = this.unproject(w, h / 2), [, clat] = this.unproject(w / 2, h / 2);
    const altW = sunAltitude(date, minute % 1440, Math.max(-10, wl), clat), altE = sunAltitude(date, minute % 1440, Math.min(4.5, el), clat);
    const lightOf = a => Math.max(0, Math.min(1, (a + 7) / 13));
    const nightW = 1 - lightOf(altW), nightE = 1 - lightOf(altE), night = (nightW + nightE) / 2;
    const idle = performance.now() - this.lastInteraction > 140;
    if (!this.snap || this.dirty || (idle && (this.snap.zoom !== this.zoom || this.snap.pan.x !== this.pan.x || this.snap.pan.y !== this.pan.y)) || this.snap.night !== (night > .5) || this.snap.layer !== this.layer || this.snap.mode !== view.mode || this.snap.key !== view.networkKey) this.renderCaches(view, night);
    c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    c.fillStyle = '#6f9fa8'; c.fillRect(0, 0, w, h);
    this.blit('base');
    // noche: gradiente oeste-este
    if (night > .01) {
      const g = c.createLinearGradient(0, 0, w, 0);
      g.addColorStop(0, `rgba(10,18,44,${nightW * .8})`); g.addColorStop(1, `rgba(10,18,44,${nightE * .8})`);
      c.fillStyle = g; c.fillRect(0, 0, w, h);
    }
    // crepúsculo cálido
    const twilight = Math.max(0, 1 - Math.abs((altW + altE) / 2) / 7);
    if (twilight > 0) {
      const morning = minute % 1440 < 780, g = c.createLinearGradient(morning ? w : 0, 0, morning ? 0 : w, 0);
      g.addColorStop(0, `rgba(255,150,80,${twilight * .22})`); g.addColorStop(1, 'rgba(255,150,80,0)');
      c.fillStyle = g; c.fillRect(0, 0, w, h);
    }
    if (night > .05) this.blit('lights', Math.min(1, night * 1.15));
    this.blit('lines', this.layer === 'works' ? .55 : 1 - night * .12);
    this.drawSelected(view, night);
    this.drawWorks(view, night, t);
    this.blit('labels');
    this.drawStations(view, night);
    this.drawTrains(view, night, t);
    this.drawHover(view, night);
    this.drawScale(night);
  }

  drawSelected(view, night) {
    if (!this.selected) return;
    const c = this.ctx, pts = this.routeCoords(this.selected), edges = S.routeEdges(this.selected);
    c.lineCap = 'round'; c.lineJoin = 'round';
    const paths = edges.length ? edges.map(i => S.edge(i).pts) : [pts];
    for (const [width, color] of [[11, night > .5 ? 'rgba(255,230,150,.25)' : 'rgba(255,255,255,.65)'], [4.5, '#f3b33d']]) {
      c.beginPath();
      for (const path of paths) path.forEach(([lon, lat], k) => { const p = this.project(lon, lat); k ? c.lineTo(p[0], p[1]) : c.moveTo(p[0], p[1]); });
      c.strokeStyle = color; c.lineWidth = width * Math.min(1.6, Math.max(1, Math.pow(this.zoom, .2))); c.stroke();
    }
  }

  workGeometry(job) {
    const def = PROJECTS.find(d => d.id === job.id), routes = def ? def.routes : [job.route];
    const paths = [];
    for (const id of routes) {
      const path = RAIL_PATHS[id]?.coordinates;
      if (path) paths.push({pts: path, conceptual: false});
      else { const r = this.opts.getState().routes.find(r => r.id === id); if (r) paths.push({pts: r.via.map(v => [CITY[v].lon, CITY[v].lat]), conceptual: true}); }
    }
    return paths;
  }

  drawWorks(view, night, t) {
    const state = this.opts.getState(), c = this.ctx, z = this.zoom, showAll = this.layer === 'works';
    this.workPoints = [];
    const jobs = state.projects.filter(p => !p.done && p.type !== 'upgrade');
    const planned = showAll ? PROJECTS.filter(p => !state.projects.some(j => j.id === p.id)) : [];
    c.lineCap = 'round'; c.lineJoin = 'round';
    for (const def of planned) for (const g of this.workGeometry({id: def.id})) {
      c.beginPath(); g.pts.forEach(([lon, lat], k) => { const p = this.project(lon, lat); k ? c.lineTo(...p) : c.moveTo(...p); });
      c.setLineDash([2, 7]); c.strokeStyle = night > .5 ? 'rgba(255,214,140,.55)' : 'rgba(150,100,30,.6)'; c.lineWidth = 2; c.stroke(); c.setLineDash([]);
      const mid = g.pts[Math.floor(g.pts.length / 2)], p = this.project(...mid);
      this.workPoints.push({id: def.id, x: p[0], y: p[1]});
      c.fillStyle = 'rgba(255,248,230,.9)'; c.strokeStyle = '#a06a1c'; c.lineWidth = 1.5; c.beginPath(); c.arc(p[0], p[1], 6, 0, Math.PI * 2); c.fill(); c.stroke();
      c.fillStyle = '#a06a1c'; c.font = '700 9px Figtree'; c.textAlign = 'center'; c.fillText('P', p[0], p[1] + 3); c.textAlign = 'left';
    }
    for (const job of jobs) {
      const st = constructionStatus(state, job);
      for (const g of this.workGeometry(job)) {
        const pts = g.pts.map(p => this.project(p[0], p[1]));
        if (pts.length < 2) continue;
        const len = [0];
        for (let k = 1; k < pts.length; k++) len.push(len[k - 1] + Math.hypot(pts[k][0] - pts[k - 1][0], pts[k][1] - pts[k - 1][1]));
        const total = len[len.length - 1], doneLen = total * st.progress;
        const scale = Math.min(2.4, Math.max(1, Math.pow(z, .3)));
        // calzada de obra
        c.beginPath(); pts.forEach((p, k) => k ? c.lineTo(...p) : c.moveTo(...p));
        c.strokeStyle = night > .5 ? 'rgba(255,190,90,.35)' : 'rgba(214,150,55,.45)'; c.lineWidth = 9 * scale; c.stroke();
        c.setLineDash([7, 5]); c.strokeStyle = '#d18a2a'; c.lineWidth = 2.4 * scale; c.stroke(); c.setLineDash([]);
        // tramo terminado
        c.beginPath(); let k = 0; c.moveTo(...pts[0]);
        for (k = 1; k < pts.length && len[k] <= doneLen; k++) c.lineTo(...pts[k]);
        let front = pts[pts.length - 1];
        if (k < pts.length) { const f = (doneLen - len[k - 1]) / ((len[k] - len[k - 1]) || 1); front = [mix(pts[k - 1][0], pts[k][0], f), mix(pts[k - 1][1], pts[k][1], f)]; c.lineTo(...front); }
        c.strokeStyle = night > .5 ? '#ffe2a6' : '#5a4630'; c.lineWidth = 3.2 * scale; c.stroke();
        // traviesas cuando el zoom lo permite
        if (z > 9) {
          c.strokeStyle = night > .5 ? 'rgba(255,226,166,.7)' : 'rgba(80,60,40,.75)'; c.lineWidth = 1.2;
          for (let d = 0; d < doneLen; d += 6) {
            let j = 1; while (j < pts.length && len[j] < d) j++;
            if (j >= pts.length) break;
            const a = pts[j - 1], b = pts[j], f = (d - len[j - 1]) / ((len[j] - len[j - 1]) || 1), x = mix(a[0], b[0], f), y = mix(a[1], b[1], f), ang = Math.atan2(b[1] - a[1], b[0] - a[0]) + Math.PI / 2;
            c.beginPath(); c.moveTo(x - Math.cos(ang) * 4, y - Math.sin(ang) * 4); c.lineTo(x + Math.cos(ang) * 4, y + Math.sin(ang) * 4); c.stroke();
          }
          // hitos de fase
          c.font = '600 11px Figtree';
          STAGES.forEach((name, si) => {
            const d = total * (si + .5) / 5; let j = 1; while (j < pts.length && len[j] < d) j++;
            if (j >= pts.length) return;
            const f = (d - len[j - 1]) / ((len[j] - len[j - 1]) || 1), x = mix(pts[j - 1][0], pts[j][0], f), y = mix(pts[j - 1][1], pts[j][1], f);
            const done = si < st.stageIndex, now = si === st.stageIndex;
            c.fillStyle = done ? '#3f7d4e' : now ? '#d18a2a' : 'rgba(120,100,70,.8)';
            c.beginPath(); c.arc(x, y, 4.5, 0, Math.PI * 2); c.fill();
            if (z > 16) { const text = (done ? '✓ ' : '') + name; c.lineWidth = 3; c.strokeStyle = night > .5 ? 'rgba(10,15,30,.9)' : 'rgba(255,248,232,.95)'; c.strokeText(text, x + 8, y - 6); c.fillStyle = night > .5 ? '#ffe9bf' : '#3a2f22'; c.fillText(text, x + 8, y - 6); }
          });
        }
        // frente de obra: grúa con baliza
        const blink = (Math.sin(t / 260) + 1) / 2;
        c.save(); c.translate(front[0], front[1]);
        c.fillStyle = `rgba(255,170,40,${.25 + blink * .35})`; c.beginPath(); c.arc(0, 0, 13 * scale, 0, Math.PI * 2); c.fill();
        c.fillStyle = '#f1b43c'; c.strokeStyle = '#4b3420'; c.lineWidth = 1.4;
        c.beginPath(); c.roundRect(-7 * scale, -5 * scale, 14 * scale, 10 * scale, 2); c.fill(); c.stroke();
        c.beginPath(); c.moveTo(-4 * scale, -5 * scale); c.lineTo(-4 * scale, -15 * scale); c.lineTo(9 * scale, -15 * scale); c.moveTo(-4 * scale, -12 * scale); c.lineTo(5 * scale, -15 * scale); c.stroke();
        c.restore();
        this.workPoints.push({id: job.id, x: front[0], y: front[1]});
        if (z > 3 || showAll) {
          const def = PROJECTS.find(d => d.id === job.id), r = state.routes.find(r => r.id === job.route);
          const text = (def ? def.name.split(' · ')[0] : r ? r.name || r.id : 'Obra') + ' · ' + Math.round(st.progress * 100) + '%';
          c.font = '700 12px Figtree'; const wd = c.measureText(text).width;
          c.fillStyle = night > .5 ? 'rgba(20,24,40,.92)' : 'rgba(255,248,232,.95)'; c.beginPath(); c.roundRect(front[0] + 14, front[1] - 30, wd + 16, 22, 11); c.fill();
          c.fillStyle = night > .5 ? '#ffd58a' : '#7a4b12'; c.fillText(text, front[0] + 22, front[1] - 15);
        }
      }
    }
  }

  drawStations(view, night) {
    this.stationPoints = [];
    if (this.zoom < 4) return;
    const c = this.ctx, usage = S.edgeUsage(view.dayType || 'L');
    if (!this.servedStations) { this.servedStations = new Set(); for (const i of usage.keys()) { const e = S.edge(i); this.servedStations.add(e.a); this.servedStations.add(e.b); } }
    const r = this.zoom > 30 ? 4.5 : this.zoom > 12 ? 3.4 : 2.4;
    for (const idx of this.servedStations) {
      const st = S.STATIONS[idx], p = this.project(st.lon, st.lat);
      if (!this.visible(p, 5)) continue;
      if (this.zoom < 9 && st.traffic < 60) continue;
      this.stationPoints.push({id: idx, x: p[0], y: p[1]});
      const big = st.traffic > 400;
      c.fillStyle = night > .5 ? '#fff4d6' : '#fffaf0'; c.strokeStyle = night > .5 ? '#ffcf7a' : '#3b3128'; c.lineWidth = big ? 2 : 1.4;
      c.beginPath(); big ? c.roundRect(p[0] - r - 1.5, p[1] - r, (r + 1.5) * 2, r * 2, r) : c.arc(p[0], p[1], r, 0, Math.PI * 2); c.fill(); c.stroke();
    }
  }

  trainSprite(c, x, y, angle, color, scale, night, delayed, bus, selected) {
    c.save(); c.translate(x, y);
    if (selected) { c.fillStyle = 'rgba(243,179,61,.35)'; c.beginPath(); c.arc(0, 0, 16 * scale, 0, Math.PI * 2); c.fill(); }
    if (delayed) { c.strokeStyle = 'rgba(214,60,50,.9)'; c.lineWidth = 2; c.beginPath(); c.arc(0, 0, 9 * scale, 0, Math.PI * 2); c.stroke(); }
    if (angle === null) {
      c.fillStyle = color; c.strokeStyle = night > .5 ? '#fff6dc' : '#fffaf2'; c.lineWidth = 1.6;
      c.beginPath(); c.arc(0, 0, 3.6 * scale, 0, Math.PI * 2); c.fill(); c.stroke(); c.restore(); return;
    }
    c.rotate(angle);
    if (night > .4 && !bus) { // haz de los faros
      const g = c.createLinearGradient(5 * scale, 0, 34 * scale, 0);
      g.addColorStop(0, `rgba(255,240,180,${.55 * night})`); g.addColorStop(1, 'rgba(255,240,180,0)');
      c.fillStyle = g; c.beginPath(); c.moveTo(6 * scale, 0); c.lineTo(34 * scale, -9 * scale); c.lineTo(34 * scale, 9 * scale); c.closePath(); c.fill();
    }
    if (bus) {
      c.fillStyle = '#f2b13a'; c.strokeStyle = '#5b3d10'; c.lineWidth = 1.2;
      c.beginPath(); c.roundRect(-5 * scale, -3.2 * scale, 10 * scale, 6.4 * scale, 1.5 * scale); c.fill(); c.stroke();
    } else {
      const L = 9 * scale, H = 3.4 * scale;
      c.fillStyle = night > .5 ? '#fff3d0' : '#fffaf2'; c.strokeStyle = color; c.lineWidth = Math.max(1.4, 1.2 * scale);
      c.beginPath(); c.moveTo(-L, -H); c.lineTo(L - H, -H); c.quadraticCurveTo(L + H * .6, 0, L - H, H); c.lineTo(-L, H); c.closePath(); c.fill(); c.stroke();
      c.fillStyle = color; c.fillRect(-L + 1, -H * .3, 2 * L - H - 1, H * .6);
      if (scale > 1.4) { c.fillStyle = night > .5 ? '#ffd56b' : '#2c3a44'; for (let k = -L + 3; k < L - H - 2; k += 3.2 * scale) c.fillRect(k, -H * .75, 1.8 * scale, H * .35); }
    }
    c.restore();
  }

  drawTrains(view, night, t) {
    const c = this.ctx, minute = view.minute, trips = view.trips || [];
    const scale = this.zoom < 2 ? .75 : this.zoom < 6 ? 1 : this.zoom < 20 ? 1.35 : this.zoom < 60 ? 1.8 : 2.4;
    this.trainPoints = [];
    let follow = null;
    for (const trip of trips) {
      if (minute < trip.dep || minute > trip.arrival) continue;
      let pos;
      if (trip.trip) pos = S.position(trip.trip, minute, trip.delay || 0);
      else if (trip.coords?.length) {
        const pts = trip.coords, f = Math.max(0, Math.min(1, (minute - trip.dep) / ((trip.arrival - trip.dep) || 1)));
        const idx = Math.min(pts.length - 2, Math.floor(f * (pts.length - 1))), g = f * (pts.length - 1) - idx, a = pts[idx], b = pts[idx + 1] || a;
        pos = {lon: mix(a[0], b[0], g), lat: mix(a[1], b[1], g), angle: Math.atan2(-(b[1] - a[1]), (b[0] - a[0]) * .77)};
      }
      if (!pos) continue;
      const p = this.project(pos.lon, pos.lat);
      if (trip.id === this.selectedTrain) follow = p;
      if (!this.visible(p, 20)) continue;
      const color = trip.line !== undefined && trip.line !== null ? this.lineColor(trip.line) : '#8a3550';
      this.trainSprite(c, p[0], p[1], this.zoom < 2.2 ? null : pos.angle, color, scale, night, trip.delay > 5, trip.bus, trip.id === this.selectedTrain);
      this.trainPoints.push({id: trip.id, x: p[0], y: p[1]});
      if (this.zoom > 28 && trip.label) {
        c.font = '600 11px "IBM Plex Mono", monospace'; const wd = c.measureText(trip.label).width;
        c.fillStyle = night > .5 ? 'rgba(18,22,36,.85)' : 'rgba(255,250,240,.9)'; c.beginPath(); c.roundRect(p[0] + 10, p[1] + 6, wd + 10, 17, 8); c.fill();
        c.fillStyle = trip.delay > 5 ? '#c43b2f' : night > .5 ? '#ffe7b0' : '#2c2620'; c.fillText(trip.label, p[0] + 15, p[1] + 18);
      }
    }
    if (this.follow && follow && !this.drag) { const dx = this.w * .46 - follow[0], dy = this.h * .5 - follow[1]; this.pan.x += dx * .12; this.pan.y += dy * .12; if (Math.abs(dx) + Math.abs(dy) > .5) this.touch(); }
  }

  drawHover(view, night) {
    if (!this.hover || this.drag) return;
    const c = this.ctx, state = this.opts.getState();
    let text = '', sub = '', at = null;
    if (this.hover.type === 'train') {
      const trip = (view.trips || []).find(t => t.id === this.hover.id);
      const p = this.trainPoints.find(p => p.id === this.hover.id);
      if (!trip || !p) return;
      text = trip.label || trip.name; sub = trip.name + (trip.delay > 5 ? ` · +${trip.delay} min` : ' · en hora'); at = [p.x, p.y];
    } else if (this.hover.type === 'station') {
      const st = S.STATIONS[this.hover.id], p = this.stationPoints.find(p => p.id === this.hover.id);
      if (!p) return;
      text = st.name; sub = st.traffic + ' circulaciones en laborable'; at = [p.x, p.y];
    } else if (this.hover.type === 'route') {
      const r = state.routes.find(r => r.id === this.hover.id); if (!r) return;
      text = r.name || r.id; sub = r.active ? 'En servicio · ' + r.frequency + ' salidas por sentido' : 'Sin servicio · pulsa para gestionar';
      at = this.lastPointer;
    } else if (this.hover.type === 'work') {
      const def = PROJECTS.find(p => p.id === this.hover.id), w = this.workPoints.find(p => p.id === this.hover.id);
      text = def?.name || 'Obra'; sub = 'Pulsa para visitar la obra'; at = w ? [w.x, w.y] : null;
    }
    if (!at) return;
    c.font = '700 13px Figtree'; const w1 = c.measureText(text).width; c.font = '500 12px Figtree'; const w2 = c.measureText(sub).width;
    const wd = Math.max(w1, w2) + 22, x = Math.min(this.w - wd - 8, at[0] + 14), y = Math.max(8, at[1] - 52);
    c.fillStyle = night > .5 ? 'rgba(22,26,42,.94)' : 'rgba(255,250,240,.97)'; c.strokeStyle = 'rgba(80,60,40,.25)'; c.lineWidth = 1;
    c.beginPath(); c.roundRect(x, y, wd, 44, 10); c.fill(); c.stroke();
    c.fillStyle = night > .5 ? '#ffe7b0' : '#2a221c'; c.font = '700 13px Figtree'; c.fillText(text, x + 11, y + 18);
    c.fillStyle = night > .5 ? '#c9bfa8' : '#6b5d4c'; c.font = '500 12px Figtree'; c.fillText(sub, x + 11, y + 35);
  }

  drawScale(night) {
    const c = this.ctx, kmPx = this.pxPerKm(), choices = [1, 2, 5, 10, 20, 50, 100, 200];
    const km = choices.find(k => k * kmPx > 70) || 200, len = km * kmPx, x = 18, y = this.h - 22;
    c.strokeStyle = night > .5 ? '#e8dcc0' : '#4a3e30'; c.lineWidth = 2;
    c.beginPath(); c.moveTo(x, y - 5); c.lineTo(x, y); c.lineTo(x + len, y); c.lineTo(x + len, y - 5); c.stroke();
    c.font = '600 11px Figtree'; c.fillStyle = c.strokeStyle; c.fillText(km + ' km', x + len + 6, y + 1);
  }
}
