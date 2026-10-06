// Modelos 3D de material rodante (three.js). Cada serie se construye con secciones transversales
// interpoladas a lo largo del vehículo (morro incluido), librea pintada en textura, pintura con
// barniz y reflejos de cielo, rodadura (bogies o rodales Talgo), pantógrafo o equipos diésel,
// fuelles, vía con balasto y catenaria. Modelos propios aproximados a las series reales.
import {artKey, trainArt} from './train-art.js';

const T = () => window.THREE;
const LIVERY = {
  ave: {band: '#5d2477', line: '#c8102e', base: '#f3f3f0', low: '#3a3d42'},
  avlo: {band: '#7b3fb1', line: '#d9b8f2', base: '#f3f3f0', low: '#3a3d42', nose: '#7b3fb1'},
  avant: {band: '#5d2477', line: '#e2672a', base: '#f3f3f0', low: '#3a3d42'},
  alvia: {band: '#8f959b', line: '#5d2477', base: '#f1f1ee', low: '#3a3d42'},
  md: {band: '#c8102e', line: '#5d2477', base: '#f3f3f0', low: '#3a3d42'},
  metric: {band: '#6a2c83', line: '#d6001c', base: '#f3f3f0', low: '#3a3d42'},
  historic: {band: '#c8102e', line: '#f2a900', base: '#efeee6', low: '#454240'},
  future: {band: '#2d1b4e', line: '#c8102e', base: '#f5f5f7', low: '#26262c', nose: '#2d1b4e'},
  loco: {band: '#5d2477', line: '#c8102e', base: '#eeeeea', low: '#3a3d42'},
};
// Perfil del morro: [distancia desde el inicio del morro (m), y superior, y inferior, semiancho, exponente de sección]
const NOSES = {
  duck: {len: 12, keys: [[0, 4.0, 1.0, 1.47, 5], [2.5, 3.95, 1.0, 1.46, 5], [4.6, 3.45, 1.0, 1.42, 4.2], [6.2, 2.55, 1.0, 1.36, 3.6], [8.6, 2.15, 1.02, 1.22, 3.2], [10.6, 1.85, 1.05, .95, 2.8], [11.6, 1.6, 1.1, .6, 2.4], [12, 1.36, 1.2, .15, 2]],
    glass: [[2.6, 3.9], [4.5, 3.45], [5.6, 2.85], [5.4, 2.6], [3.9, 3.05], [2.8, 3.45]], light: [11.2, 1.45]},
  avril: {len: 9, keys: [[0, 3.4, 1.0, 1.47, 5], [2, 3.35, 1.0, 1.46, 4.6], [4.2, 2.9, 1.0, 1.4, 4], [6.2, 2.25, 1.02, 1.22, 3.2], [7.8, 1.7, 1.06, .9, 2.7], [8.7, 1.35, 1.15, .45, 2.3], [9, 1.2, 1.18, .1, 2]],
    glass: [[1.8, 3.33], [4.6, 2.82], [5.5, 2.48], [3.8, 2.6], [1.6, 3.0]], light: [8.4, 1.32]},
  velaro: {len: 6.5, keys: [[0, 3.9, 1.0, 1.47, 5], [1.8, 3.82, 1.0, 1.45, 4.4], [3.6, 3.35, 1.0, 1.36, 3.6], [5.2, 2.55, 1.02, 1.12, 3], [6.2, 1.8, 1.08, .7, 2.6], [6.5, 1.35, 1.2, .2, 2]],
    glass: [[1.7, 3.78], [3.9, 3.25], [4.6, 2.85], [3.2, 2.95], [1.5, 3.35]], light: [6, 1.6]},
  tgv: {len: 6, keys: [[0, 4.05, 1.0, 1.45, 5.5], [1.2, 4.0, 1.0, 1.44, 5], [2.6, 3.35, 1.0, 1.4, 4], [4.4, 2.45, 1.0, 1.25, 3.2], [5.6, 1.75, 1.05, .9, 2.8], [6, 1.4, 1.18, .3, 2]],
    glass: [[1.15, 3.95], [2.7, 3.3], [3.1, 3.0], [1.8, 3.15], [1.0, 3.55]], light: [5.5, 1.55]},
  round: {len: 4.2, keys: [[0, 3.7, 1.0, 1.42, 5], [1.4, 3.62, 1.0, 1.41, 4.6], [2.8, 3.2, 1.0, 1.32, 3.8], [3.8, 2.4, 1.05, 1.1, 3.2], [4.2, 1.6, 1.15, .6, 2.6]],
    glass: [[1.2, 3.6], [3.0, 3.05], [3.6, 2.45], [2.4, 2.45], [1.0, 3.0]], light: [3.95, 1.55]},
  emu: {len: 2.9, keys: [[0, 3.85, 1.0, 1.42, 5.5], [.9, 3.8, 1.0, 1.42, 5], [2.1, 3.2, 1.0, 1.38, 4.4], [2.7, 2.2, 1.0, 1.3, 4], [2.9, 1.3, 1.02, 1.15, 3.6]],
    glass: [[.85, 3.75], [2.1, 3.15], [2.55, 2.35], [1.9, 2.35], [.7, 3.2]], light: [2.82, 1.55]},
  boxy: {len: .7, keys: [[0, 3.85, 1.0, 1.42, 6], [.5, 3.78, 1.0, 1.41, 6], [.7, 3.55, 1.0, 1.38, 5.5]],
    glass: [[.55, 3.6], [.7, 3.5], [.7, 2.5], [.4, 2.5]], light: [.68, 1.45]},
  loco: {len: 1.2, keys: [[0, 4.2, 1.0, 1.45, 6], [.6, 4.1, 1.0, 1.44, 5.5], [1.2, 3.6, 1.0, 1.38, 5]],
    glass: [[.6, 4.0], [1.15, 3.6], [1.2, 2.9], [.5, 2.9]], light: [1.15, 1.6]},
};
// Familias: forma, longitudes (m), rodadura, tracción, ventanas, puertas y librea.
const FAMILY = {
  duck: {nose: 'duck', head: 20, coach: 13.1, coachTop: 3.36, talgo: true, power: 'e', windows: 'ribbon', doors: 1, livery: 'ave', powerCar: true},
  avril: {nose: 'avril', head: 16, coach: 13.1, coachTop: 3.36, talgo: true, power: 'e', windows: 'ribbon', doors: 1, livery: 'ave', top: 3.4},
  velaro: {nose: 'velaro', head: 25.5, coach: 24.2, coachTop: 3.9, power: 'e', windows: 'ribbon', doors: 1, livery: 'ave'},
  tgv: {nose: 'tgv', head: 22, coach: 18.7, coachTop: 3.42, power: 'e', windows: 'ribbon', doors: 1, livery: 'ave', powerCar: true, articulated: true},
  pendolino: {nose: 'round', head: 25.9, coach: 25, coachTop: 3.7, power: 'e', windows: 'ribbon', doors: 1, livery: 'avant', top: 3.7},
  alvia120: {nose: 'emu', head: 25.6, coach: 25, coachTop: 3.85, power: 'e', windows: 'ribbon', doors: 1, livery: 'alvia'},
  md: {nose: 'emu', head: 26.6, coach: 25.5, coachTop: 3.85, power: 'e', windows: 'large', doors: 2, livery: 'md'},
  mdDiesel: {nose: 'emu', head: 26.6, coach: 25.5, coachTop: 3.85, power: 'd', windows: 'large', doors: 2, livery: 'md'},
  trd: {nose: 'round', head: 25.5, coach: 25.5, coachTop: 3.7, power: 'd', windows: 'large', doors: 2, livery: 'md', top: 3.7},
  camello: {nose: 'boxy', head: 24, coach: 24, coachTop: 3.85, power: 'd', windows: 'large', doors: 2, livery: 'historic'},
  metric: {nose: 'emu', head: 18, coach: 17, coachTop: 3.45, power: 'e', windows: 'large', doors: 2, livery: 'metric', width: 2.55, top: 3.45},
  metricDiesel: {nose: 'boxy', head: 18, coach: 17, coachTop: 3.45, power: 'd', windows: 'large', doors: 2, livery: 'metric', width: 2.55, top: 3.45},
  alpine: {nose: 'boxy', head: 16, coach: 16, coachTop: 3.4, power: 'e', windows: 'panorama', doors: 1, livery: 'historic', width: 2.5, top: 3.4},
  future: {nose: 'avril', head: 19, coach: 19, coachTop: 3.6, power: 'e', windows: 'ribbon', doors: 1, livery: 'future', top: 3.6},
  loco: {nose: 'loco', head: 20.5, coach: 26.1, coachTop: 3.8, power: 'd', windows: 'coach', doors: 1, livery: 'loco', powerCar: true, top: 4.2},
};
const SERIES = {100: 'tgv', 102: 'duck', 112: 'duck', '112M': 'duck', 103: 'velaro', 106: 'avril', 107: 'duck', 130: 'duck', 730: 'duck', 104: 'pendolino', 114: 'pendolino',
  120: 'alvia120', 121: 'alvia120', 448: 'md', 449: 'md', 470: 'camello', 480: 'md', 490: 'md', 592: 'camello', 594: 'trd', 596: 'trd', 598: 'mdDiesel', 599: 'mdDiesel',
  2400: 'metricDiesel', 2600: 'metricDiesel', 2700: 'metricDiesel', 2900: 'metric', 3300: 'metric', 3500: 'metric', 3600: 'metric', 3800: 'metric', 401: 'metric', 402: 'alpine', 334: 'loco'};

function familyFor(key) {
  if (key === 'future') return {...FAMILY.future};
  if (key === '106avlo') return {...FAMILY.avril, livery: 'avlo'};
  const f = {...(FAMILY[SERIES[key]] || FAMILY.md)};
  if (['130', '730', '107'].includes(key)) f.livery = 'alvia';
  if (['104', '114', '121'].includes(key)) f.livery = 'avant';
  if (key === '730') f.power = 'hybrid';
  return f;
}

// ------------------------------------------------------------ geometría
const lerp = (a, b, t) => a + (b - a) * t;
function interpKeys(keys, steps) {
  const out = [];
  for (let k = 0; k < keys.length - 1; k++) {
    const a = keys[k], b = keys[k + 1];
    for (let s = 0; s < steps; s++) { const t = s / steps, e = t * t * (3 - 2 * t); out.push(a.map((v, i) => i === 0 ? lerp(a[0], b[0], t) : lerp(v, b[i], e))); }
  }
  out.push(keys[keys.length - 1]);
  return out;
}
/** Malla por secciones superelípticas. stations: [x, top, bottom, halfWidth, n]. UV = proyección lateral. */
function loft(THREE, stations, uvLen, uvH, seg = 40, capStart = true) {
  const pos = [], uv = [], idx = [];
  stations.forEach(([x, top, bot, hw, n]) => {
    const cy = (top + bot) / 2, hh = (top - bot) / 2;
    for (let j = 0; j <= seg; j++) {
      const th = j / seg * Math.PI * 2, c = Math.cos(th), s = Math.sin(th);
      const z = hw * Math.sign(c) * Math.abs(c) ** (2 / n), y = cy + hh * Math.sign(s) * Math.abs(s) ** (2 / n);
      pos.push(x, y, z); uv.push(x / uvLen, y / uvH);
    }
  });
  const row = seg + 1;
  for (let i = 0; i < stations.length - 1; i++) for (let j = 0; j < seg; j++) { const a = i * row + j, b = a + row; idx.push(a, b, a + 1, b, b + 1, a + 1); }
  const cap = (i, flip) => {
    const [x, top, bot] = stations[i], c = pos.length / 3; pos.push(x, (top + bot) / 2, 0); uv.push(x / uvLen, (top + bot) / 2 / uvH);
    for (let j = 0; j < seg; j++) { const a = i * row + j; flip ? idx.push(c, a + 1, a) : idx.push(c, a, a + 1); }
  };
  if (capStart) cap(0, false);
  cap(stations.length - 1, true);
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); g.setIndex(idx); g.computeVertexNormals();
  return g;
}

// ------------------------------------------------------------ libreas (texturas)
const UVH = 4.6;
function liveryTexture(THREE, f, len, top, opts) {
  const W = 2048, H = 512, cv = document.createElement('canvas'); cv.width = W; cv.height = H;
  const c = cv.getContext('2d'), L = LIVERY[f.livery], X = x => x / len * W, Y = y => H - y / UVH * H;
  const grad = c.createLinearGradient(0, Y(top), 0, Y(1)); grad.addColorStop(0, '#ffffff'); grad.addColorStop(1, L.base);
  c.fillStyle = grad; c.fillRect(0, 0, W, H);
  c.fillStyle = '#c4c6c8'; c.fillRect(0, 0, W, Y(top - .32));                      // techo
  c.fillStyle = L.low; c.fillRect(0, Y(1.28), W, H);                               // faldón
  c.fillStyle = L.band; c.fillRect(0, Y(1.62), W, Y(1.28) - Y(1.62));             // banda de librea
  c.fillStyle = L.line; c.fillRect(0, Y(1.74), W, Y(1.66) - Y(1.74));
  if (f.livery === 'avlo' || f.livery === 'future') { c.fillStyle = L.band; c.beginPath(); c.moveTo(0, Y(1.62)); c.bezierCurveTo(W * .3, Y(1.62), W * .55, Y(3.2), W, Y(top - .2)); c.lineTo(W, Y(1.62)); c.closePath(); c.globalAlpha = .9; c.fill(); c.globalAlpha = 1; }
  const body0 = opts.noseStart ?? len, doors = [], wins = [];
  const wy0 = f.windows === 'large' ? 2.0 : f.windows === 'panorama' ? 1.9 : 2.15, wy1 = f.windows === 'large' ? 3.0 : f.windows === 'panorama' ? 3.3 : 2.85;
  const doorW = f.windows === 'large' ? 1.3 : .9;
  if (!opts.power) {
    if (f.doors >= 1) doors.push(opts.head ? 1.2 : 1.0);
    if (f.doors >= 2) doors.push(body0 - (opts.head ? 4.5 : 2.3));
    if (!opts.head && f.doors === 1) doors.push(body0 - 1.9);
    const step = f.windows === 'large' ? 2.2 : f.windows === 'coach' ? 1.9 : 1.45, ww = f.windows === 'large' ? 1.75 : f.windows === 'coach' ? 1.3 : .95;
    if (f.windows === 'panorama') wins.push([1.6, body0 - 1.6]);
    else for (let x = 2.1; x < body0 - 2.2; x += step) if (!doors.some(d => x + ww > d - .3 && x < d + doorW + .3)) wins.push([x, x + ww]);
  } else {
    // coche motor: rejillas y pequeña ventana de servicio
    c.fillStyle = '#9aa0a5'; for (let x = 3; x < body0 - 4; x += .7) c.fillRect(X(x), Y(3.1), X(.45), Y(2.1) - Y(3.1));
  }
  for (const [a, b] of wins) {
    const g = c.createLinearGradient(0, Y(wy1), 0, Y(wy0)); g.addColorStop(0, '#41505c'); g.addColorStop(.5, '#1f2a33'); g.addColorStop(1, '#2b3640');
    c.fillStyle = g; roundRect(c, X(a), Y(wy1), X(b) - X(a), Y(wy0) - Y(wy1), 10); c.fill();
    c.fillStyle = 'rgba(255,255,255,.18)'; c.fillRect(X(a) + 4, Y(wy1) + 4, (X(b) - X(a)) * .35, (Y(wy0) - Y(wy1)) * .3);
  }
  for (const d of doors) {
    c.strokeStyle = '#4b5056'; c.lineWidth = 4; roundRect(c, X(d), Y(3.3), X(doorW), Y(1.12) - Y(3.3), 8); c.stroke();
    c.fillStyle = '#26323b'; roundRect(c, X(d + .18), Y(3.0), X(doorW - .36), Y(2.15) - Y(3.0), 6); c.fill();
  }
  if (opts.head) {
    const N = NOSES[f.nose], o = body0;
    c.fillStyle = '#141b22'; c.beginPath(); N.glass.forEach(([dx, y], i) => (i ? c.lineTo : c.moveTo).call(c, X(o + dx), Y(y))); c.closePath(); c.fill();
    const gg = c.createLinearGradient(X(o), Y(4), X(o + N.len), Y(2.4)); gg.addColorStop(0, 'rgba(160,200,225,.45)'); gg.addColorStop(.6, 'rgba(40,60,80,0)');
    c.fillStyle = gg; c.fill();
    if (L.nose) { c.fillStyle = L.nose; c.globalAlpha = .9; c.fillRect(X(o + N.len * .55), Y(2.2), X(N.len), Y(1.28) - Y(2.2)); c.globalAlpha = 1; }
    c.fillStyle = '#fff8d8'; const [lx, ly] = N.light; c.beginPath(); c.ellipse(X(o + lx), Y(ly), 14, 9, 0, 0, Math.PI * 2); c.fill();
    c.fillStyle = '#5a5f66'; c.font = 'bold 22px sans-serif'; c.fillText(opts.series || '', X(Math.max(2, o - 3.2)), Y(3.4));
  }
  const tex = new THREE.CanvasTexture(cv); tex.colorSpace = THREE.SRGBColorSpace; tex.anisotropy = 8;
  return tex;
}
function roundRect(c, x, y, w, h, r) { c.beginPath(); c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r); c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath(); }

// ------------------------------------------------------------ piezas
function mats(THREE) {
  return {
    metal: new THREE.MeshStandardMaterial({color: 0x3b3e43, metalness: .7, roughness: .45}),
    dark: new THREE.MeshStandardMaterial({color: 0x23262a, metalness: .3, roughness: .7}),
    steel: new THREE.MeshStandardMaterial({color: 0xb9bdc2, metalness: .95, roughness: .25}),
    rubber: new THREE.MeshStandardMaterial({color: 0x1d1f22, roughness: .9}),
    ballast: new THREE.MeshStandardMaterial({color: 0x8a8174, roughness: 1}),
    sleeper: new THREE.MeshStandardMaterial({color: 0x9e9a92, roughness: .95}),
    grey: new THREE.MeshStandardMaterial({color: 0xa7abaf, metalness: .4, roughness: .5}),
  };
}
function box(THREE, w, h, d, m, x, y, z) { const o = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m); o.position.set(x, y, z); o.castShadow = o.receiveShadow = true; return o; }
function wheelset(THREE, M, x, gauge = .74, r = .46) {
  const g = new THREE.Group(), wg = new THREE.CylinderGeometry(r, r, .14, 28);
  for (const z of [-gauge, gauge]) { const w = new THREE.Mesh(wg, M.steel); w.rotation.x = Math.PI / 2; w.position.set(x, r, z); w.castShadow = true; g.add(w); }
  const ax = new THREE.Mesh(new THREE.CylinderGeometry(.08, .08, gauge * 2, 10), M.metal); ax.rotation.x = Math.PI / 2; ax.position.set(x, r, 0); g.add(ax);
  return g;
}
function bogie(THREE, M, x) {
  const g = new THREE.Group();
  g.add(box(THREE, 3.0, .38, 2.25, M.metal, x, .78, 0));
  for (const z of [-1.0, 1.0]) g.add(box(THREE, 3.1, .28, .14, M.dark, x, .55, z));
  for (const dx of [-1.25, 1.25]) g.add(wheelset(THREE, M, x + dx));
  for (const dx of [-.6, .6]) { const s = new THREE.Mesh(new THREE.CylinderGeometry(.13, .13, .32, 12), M.grey); s.position.set(x + dx, 1.05, .85); g.add(s); const s2 = s.clone(); s2.position.z = -.85; g.add(s2); }
  return g;
}
function pantograph(THREE, M, x, top) {
  const g = new THREE.Group();
  for (const z of [-.55, .55]) { const ins = new THREE.Mesh(new THREE.CylinderGeometry(.07, .07, .3, 10), M.grey); ins.position.set(x - .6, top + .15, z); g.add(ins); const ins2 = ins.clone(); ins2.position.x = x + .6; g.add(ins2); }
  g.add(box(THREE, 1.6, .08, 1.3, M.metal, x, top + .32, 0));
  const arm = (len, ang, px, py) => { const a = box(THREE, len, .06, .08, M.metal, 0, 0, 0); a.rotation.z = ang; a.position.set(px, py, 0); return a; };
  g.add(arm(1.9, .55, x + .7, top + .9)); g.add(arm(1.9, -.62, x + .75, top + 1.95));
  const head = box(THREE, .25, .07, 1.9, M.steel, x - .05, top + 2.5, 0); g.add(head);
  return g;
}
function dieselRoof(THREE, M, x, top) {
  const g = new THREE.Group();
  g.add(box(THREE, 3.6, .4, 1.9, M.grey, x, top + .15, 0));
  for (let i = 0; i < 4; i++) g.add(box(THREE, .55, .06, 1.5, M.dark, x - 1.3 + i * .85, top + .38, 0));
  const ex = new THREE.Mesh(new THREE.CylinderGeometry(.12, .12, .55, 12), M.dark); ex.position.set(x + 2.2, top + .3, .35); g.add(ex);
  return g;
}
function gangway(THREE, M, x, top) {
  const g = new THREE.Group();
  for (let i = 0; i < 5; i++) g.add(box(THREE, .12, top - 1.25, 2.6, M.rubber, x + i * .14 - .28, (top + 1.25) / 2, 0));
  return g;
}

/** Construye el tren (coche de cabeza, segundo coche y parte del tercero) sobre la vía. */
function buildTrain(THREE, key) {
  const f = familyFor(key), M = mats(THREE), N = NOSES[f.nose], root = new THREE.Group();
  const top = f.top || (f.nose === 'duck' ? 4.0 : f.nose === 'tgv' ? 4.05 : 3.85), hw = (f.width || 2.94) / 2, n = 5.5;
  const series = key.replace(/[a-z]+/i, '') || '';
  // coche de cabeza: cuerpo + morro (morro hacia +x)
  const headLen = f.head, noseStart = headLen - N.len;
  const keys = N.keys.map(([dx, t, b, w, e]) => [noseStart + dx, f.top ? t * (top / (N.keys[0][1])) : t, b, w * hw / 1.47, e]);
  const stations = [[0, top, 1.0, hw, n], [noseStart * .5, top, 1.0, hw, n], ...interpKeys(keys, 5)];
  const paint = (tex) => new THREE.MeshPhysicalMaterial({map: tex, roughness: .38, metalness: .05, clearcoat: .9, clearcoatRoughness: .14});
  const headTex = liveryTexture(THREE, f, headLen, top, {head: true, noseStart, power: f.powerCar, series});
  const head = new THREE.Mesh(loft(THREE, stations, headLen, UVH), paint(headTex)); head.castShadow = head.receiveShadow = true;
  root.add(head);
  // coche intermedio y parte del tercero
  const ctop = f.powerCar ? f.coachTop : top, cl = f.coach, gap = .8;
  const coachTex = liveryTexture(THREE, f, cl, ctop, {head: false});
  const coachGeo = loft(THREE, [[0, ctop, 1.0, hw, n], [cl, ctop, 1.0, hw, n]], cl, UVH);
  for (const k of [1, 2]) { const m = new THREE.Mesh(coachGeo, paint(coachTex)); m.position.x = -k * (cl + gap); m.castShadow = m.receiveShadow = true; root.add(m); root.add(gangway(THREE, M, -k * (cl + gap) + cl + gap / 2, Math.min(top, ctop))); }
  // rodadura
  if (f.talgo) {
    root.add(bogie(THREE, M, 3.2)); root.add(bogie(THREE, M, noseStart - .8));
    for (const k of [1, 2]) root.add(wheelset(THREE, M, -k * (cl + gap) + cl + gap / 2, .74, .44)), root.add(box(THREE, 1.2, .5, 2.3, M.metal, -k * (cl + gap) + cl + gap / 2, .75, 0));
  } else if (f.articulated) {
    root.add(bogie(THREE, M, 3.2)); root.add(bogie(THREE, M, noseStart - .5)); for (const k of [1, 2]) root.add(bogie(THREE, M, -k * (cl + gap) + cl + gap / 2));
  } else {
    root.add(bogie(THREE, M, 3.4)); root.add(bogie(THREE, M, headLen - Math.max(3.4, N.len + 1.4)));
    for (const k of [1, 2]) { const x0 = -k * (cl + gap); root.add(bogie(THREE, M, x0 + 3.2)); root.add(bogie(THREE, M, x0 + cl - 3.2)); }
  }
  // equipos de techo
  if (f.power === 'd' || f.power === 'hybrid') root.add(dieselRoof(THREE, M, headLen * .45, top));
  if (f.power === 'e' || f.power === 'hybrid') root.add(pantograph(THREE, M, f.power === 'hybrid' ? headLen * .2 : Math.max(4, headLen * .3), top));
  root.add(box(THREE, headLen - N.len - 1, .1, hw * 1.2, M.grey, (headLen - N.len) / 2, top + .02, 0));
  // faldón inferior y equipos bajo bastidor
  root.add(box(THREE, headLen - N.len * .6, .55, hw * 1.7, M.dark, (headLen - N.len * .6) / 2, 1.05, 0));
  // vía: balasto, traviesas, carriles y catenaria
  const x0 = -2 * (cl + gap) - 4, x1 = headLen + 14, L = x1 - x0, cx = (x0 + x1) / 2;
  const sh = new THREE.Shape([new THREE.Vector2(-2.6, -.42), new THREE.Vector2(2.6, -.42), new THREE.Vector2(1.7, -.08), new THREE.Vector2(-1.7, -.08)]);
  const ballast = new THREE.Mesh(new THREE.ExtrudeGeometry(sh, {depth: L, bevelEnabled: false}), M.ballast); ballast.rotation.y = Math.PI / 2; ballast.position.set(x0, 0, 0); ballast.receiveShadow = true; root.add(ballast);
  const slGeo = new THREE.BoxGeometry(.24, .16, 2.6), sleepers = new THREE.InstancedMesh(slGeo, M.sleeper, Math.ceil(L / .6)), mtx = new THREE.Matrix4();
  for (let i = 0; i < sleepers.count; i++) { mtx.makeTranslation(x0 + i * .6, -.02, 0); sleepers.setMatrixAt(i, mtx); }
  sleepers.receiveShadow = true; root.add(sleepers);
  for (const z of [-.74, .74]) root.add(box(THREE, L, .16, .07, M.steel, cx, .08, z));
  if (f.power !== 'd') {
    for (let x = x0 + 6; x < x1; x += 22) { root.add(box(THREE, .22, 7.4, .22, M.grey, x, 3.7, -2.6)); root.add(box(THREE, .1, .1, 2.5, M.grey, x, 6.6, -1.35)); }
    const wire = new THREE.Mesh(new THREE.CylinderGeometry(.015, .015, L, 4), M.dark); wire.rotation.z = Math.PI / 2; wire.position.set(cx, top + 2.55, 0); root.add(wire);
    const msg = wire.clone(); msg.position.y = top + 3.4; root.add(msg);
  }
  return {root, f, headLen};
}

// ------------------------------------------------------------ escena y renderizado compartido
let R = null;
function setup() {
  const THREE = T();
  if (R) return R;
  if (!THREE) return null;
  let renderer;
  try { renderer = new THREE.WebGLRenderer({antialias: true, alpha: true, preserveDrawingBuffer: true}); } catch { return null; }
  renderer.setPixelRatio(Math.min(2, devicePixelRatio || 1));
  renderer.shadowMap.enabled = true; renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = .88; renderer.outputColorSpace = THREE.SRGBColorSpace;
  // entorno de reflejos: cielo degradado con sol
  const envScene = new THREE.Scene();
  const sky = new THREE.Mesh(new THREE.SphereGeometry(50, 32, 16), new THREE.ShaderMaterial({side: THREE.BackSide, uniforms: {},
    vertexShader: 'varying vec3 p; void main(){ p = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.); }',
    fragmentShader: 'varying vec3 p; void main(){ float h = normalize(p).y; vec3 top = vec3(.35,.55,.85), hor = vec3(1.,.9,.78), gr = vec3(.32,.28,.24); gl_FragColor = vec4(h > 0. ? mix(hor, top, pow(h,.6)) : mix(hor, gr, pow(-h,.4)), 1.); }'}));
  envScene.add(sky);
  const sunPanel = new THREE.Mesh(new THREE.PlaneGeometry(14, 14), new THREE.MeshBasicMaterial({color: 0xffffff})); sunPanel.position.set(25, 30, 20); sunPanel.lookAt(0, 0, 0); envScene.add(sunPanel);
  const pmrem = new THREE.PMREMGenerator(renderer), env = pmrem.fromScene(envScene, .02).texture;
  const scene = new THREE.Scene(); scene.environment = env;
  const bg = document.createElement('canvas'); bg.width = 4; bg.height = 256; const bc = bg.getContext('2d'), gr = bc.createLinearGradient(0, 0, 0, 256);
  gr.addColorStop(0, '#7fa9d6'); gr.addColorStop(.55, '#d9e4ea'); gr.addColorStop(.62, '#efe6d2'); gr.addColorStop(1, '#d8c9a6'); bc.fillStyle = gr; bc.fillRect(0, 0, 4, 256);
  const bgt = new THREE.CanvasTexture(bg); bgt.colorSpace = THREE.SRGBColorSpace; scene.background = bgt;
  scene.fog = new THREE.Fog(0xe9e3d3, 60, 170);
  const sun = new THREE.DirectionalLight(0xfff1dc, 2.6); sun.position.set(18, 26, 16); sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048); Object.assign(sun.shadow.camera, {left: -40, right: 40, top: 20, bottom: -20, near: 1, far: 90}); sun.shadow.bias = -.0005; sun.shadow.normalBias = .02;
  scene.add(sun, sun.target, new THREE.HemisphereLight(0xcfe3ff, 0x8a7a66, .9));
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(600, 600), new THREE.MeshStandardMaterial({color: 0xb9b08a, roughness: 1})); ground.rotation.x = -Math.PI / 2; ground.position.y = -.42; ground.receiveShadow = true; scene.add(ground);
  const camera = new THREE.PerspectiveCamera(30, 2.4, .5, 400);
  R = {THREE, renderer, scene, camera, models: new Map(), current: null, thumbs: new Map(), view: {az: .62, el: .2, dist: 34}};
  return R;
}
function model(key) {
  const r = setup();
  if (!r.models.has(key)) r.models.set(key, buildTrain(r.THREE, key));
  return r.models.get(key);
}
function show(key) {
  const r = setup(), m = model(key);
  if (r.current !== m) { if (r.current) r.scene.remove(r.current.root); r.scene.add(m.root); r.current = m; }
  return m;
}
function place(m, view, aspect) {
  const r = R, target = new r.THREE.Vector3(m.headLen * .66, 2.1, 0);
  r.camera.aspect = aspect; r.camera.updateProjectionMatrix();
  r.camera.position.set(target.x + Math.sin(view.az) * view.dist * Math.cos(view.el), target.y + Math.sin(view.el) * view.dist, target.z + Math.cos(view.az) * view.dist * Math.cos(view.el));
  r.camera.lookAt(target);
}

/** Miniatura PNG (dataURL) de una serie; recurre al dibujo vectorial si no hay WebGL. */
export function trainThumb(x) {
  const key = artKey(x);
  if (key === 'bus') return trainArt('bus');
  const r = setup();
  if (!r) return trainArt(x);
  if (!r.thumbs.has(key)) {
    const m = show(key), w = 520, h = 210;
    r.renderer.setSize(w, h, false); place(m, {az: 1.08, el: .09, dist: m.headLen * .5 + 7}, w / h);
    r.renderer.render(r.scene, r.camera);
    r.thumbs.set(key, r.renderer.domElement.toDataURL('image/png'));
  }
  return `<img class="train-3d-thumb" src="${r.thumbs.get(key)}" alt="Modelo 3D de la serie ${key}" loading="lazy">`;
}

/** Visor interactivo: arrastra para girar, rueda para acercar. */
let live = null;
export function mountViewer(container) {
  const key = artKey(container.dataset.train3d);
  if (key === 'bus') { container.innerHTML = trainArt('bus'); return; }
  const r = setup();
  if (!r) { container.innerHTML = trainArt(key); return; }
  const m = show(key), cv = r.renderer.domElement;
  if (!live || live.key !== key) live = {key, view: {az: 1.0, el: .12, dist: m.headLen * .8 + 10}, spin: true};
  container.innerHTML = ''; container.appendChild(cv); cv.className = 'train-3d-live';
  const resize = () => { const w = container.clientWidth || 360, h = Math.round(w * .42); r.renderer.setSize(w, h, false); cv.style.width = w + 'px'; cv.style.height = h + 'px'; return w / h; };
  let aspect = resize(), drag = null;
  cv.onpointerdown = e => { drag = {x: e.clientX, y: e.clientY, az: live.view.az, el: live.view.el}; live.spin = false; cv.setPointerCapture(e.pointerId); };
  cv.onpointermove = e => { if (!drag) return; live.view.az = drag.az - (e.clientX - drag.x) * .008; live.view.el = Math.max(.02, Math.min(1.1, drag.el + (e.clientY - drag.y) * .006)); };
  cv.onpointerup = () => { drag = null; };
  cv.onwheel = e => { e.preventDefault(); live.view.dist = Math.max(10, Math.min(90, live.view.dist * (e.deltaY > 0 ? 1.1 : .9))); };
  cancelAnimationFrame(live.raf);
  const tick = () => {
    if (!cv.isConnected) return;
    if (live.spin) live.view.az += .0025;
    show(key); place(m, live.view, aspect); r.renderer.render(r.scene, r.camera);
    live.raf = requestAnimationFrame(tick);
  };
  tick();
}
/** Activa los visores presentes en un elemento. */
export function mountViewers(root = document) { const el = root.querySelector('[data-train3d]'); if (el) mountViewer(el); }
