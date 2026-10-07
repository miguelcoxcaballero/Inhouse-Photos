// Red de vías del juego: estado de cada tramo (ancho, catenaria, velocidad, construido), cambiadores de ancho,
// obras históricas y enrutado de AVE (ancho estándar fijo) y Alvia (ancho variable, eléctrico o híbrido).
import {INFRA} from './assets/infra.js';

export const NODES = Object.fromEntries(INFRA.nodes.map(n => [n.id, n]));
export const TRAMOS = INFRA.tramos;
export const TRAMO = Object.fromEntries(TRAMOS.map(t => [t.id, t]));
export const GAUGE_LABEL = {ib: 'Ibérico', std: 'Estándar', mixto: 'Mixto'};
export const GAUGE_LONG = {ib: 'Ancho ibérico · 1.668 mm', std: 'Ancho estándar · 1.435 mm', mixto: 'Ancho mixto · tercer carril'};
export const ELEC_LABEL = {'25kv': '25 kV', '3kv': '3 kV', no: 'Sin catenaria'};
export const ELEC_LONG = {'25kv': 'Electrificada a 25 kV', '3kv': 'Electrificada a 3 kV', no: 'Sin electrificar'};
export const CHANGE_MINUTES = 12;

// Obras históricas (fecha real): título y texto del diario.
export const HISTORY = {
  '2022-07-19': ['Extremadura estrena vía', 'Nuevo trazado Plasencia — Cáceres — Mérida — Badajoz, a 180 km/h. Catenaria, otro día.'],
  '2022-07-21': ['El AVE llega a Burgos', 'Abre la LAV Venta de Baños — Burgos, con su cambiador de ancho.'],
  '2022-12-20': ['El AVE llega a Murcia', 'Abre la LAV Elche — Murcia. Veinte años después, pero abre.'],
  '2023-11-29': ['Variante de Pajares', 'León — Pola de Lena en ancho mixto, a 220 km/h, con cambiador en Pola de Lena.'],
  '2023-12-14': ['Extremadura, electrificada', 'Plasencia — Badajoz ya tiene catenaria de 25 kV.'],
};

function decode(str) {
  const out = [];
  let i = 0, lon = 0, lat = 0;
  while (i < str.length) {
    for (let k = 0; k < 2; k++) {
      let shift = 0, result = 0, b;
      do { b = str.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      const v = result & 1 ? ~(result >> 1) : result >> 1;
      if (k === 0) lon += v; else lat += v;
    }
    out.push([lon / 1e5, lat / 1e5]);
  }
  return out;
}
const kmBetween = ([x1, y1], [x2, y2]) => Math.hypot((x2 - x1) * 111.32 * Math.cos((y1 + y2) / 2 * Math.PI / 180), (y2 - y1) * 110.57);

const geomCache = new Map();
/** Geometría de un tramo (base o propio): puntos [lon,lat] y kilómetros acumulados. */
export function tramoGeom(t) {
  let g = geomCache.get(t.id);
  if (!g) {
    const pts = t.pts || decode(t.g), cum = [0];
    for (let k = 1; k < pts.length; k++) cum.push(cum[k - 1] + kmBetween(pts[k - 1], pts[k]));
    g = {pts, cum, km: cum.at(-1)};
    geomCache.set(t.id, g);
  }
  return g;
}

/** Estado de la red al empezar la campaña (enero de 2022). */
export function initialInfra() {
  const t = {};
  for (const d of TRAMOS) {
    const st = {g: d.gauge, e: d.elec, v: d.speed, b: !d.plan};
    if (d.start) {
      if ('built' in d.start) st.b = d.start.built;
      if (d.start.gauge) st.g = d.start.gauge;
      if (d.start.elec) st.e = d.start.elec;
      if (d.start.speed) st.v = d.start.speed;
    }
    t[d.id] = st;
  }
  return {ver: 1, t, c: INFRA.nodes.filter(n => n.changer).map(n => n.id), h: [], custom: [], done: {elec: 0, conv: 0, changers: 0, lav: 0}};
}

/** Tramos propios del jugador (líneas nuevas de alta velocidad), con geometría recta entre sus nodos. */
export function customTramos(s) {
  return (s.infra?.custom || []).map(c => ({id: c.id, a: c.a, b: c.b, kind: 'lav', name: 'LAV ' + NODES[c.a].name + ' — ' + NODES[c.b].name, km: c.km,
    gauge: 'std', elec: '25kv', speed: 300, custom: true, pts: [[NODES[c.a].lon, NODES[c.a].lat], [NODES[c.b].lon, NODES[c.b].lat]]}));
}
export function allTramos(s) { return [...TRAMOS, ...customTramos(s)]; }
export function tramoDef(s, id) { return TRAMO[id] || customTramos(s).find(t => t.id === id) || null; }
export function tramoState(s, id) { return s.infra.t[id]; }
export const hasChanger = (s, node) => s.infra.c.includes(node);

/** Aplica las obras históricas cuya fecha ya ha llegado. Devuelve los titulares nuevos. */
export function applyHistoric(s, date) {
  const news = new Set();
  for (const d of TRAMOS) for (const [when, ch] of d.hist || []) {
    const key = d.id + '@' + when;
    if (when > date || s.infra.h.includes(key)) continue;
    s.infra.h.push(key);
    const st = s.infra.t[d.id];
    if ('built' in ch) st.b = ch.built;
    if (ch.gauge) st.g = ch.gauge;
    if (ch.elec) st.e = ch.elec;
    if (ch.speed) st.v = ch.speed;
    if (ch.changer) for (const n of [d.a, d.b]) if (NODES[n].changerName && !s.infra.c.includes(n)) s.infra.c.push(n);
    news.add(when);
  }
  if (news.size) s.infra.ver++;
  return [...news].sort().map(w => HISTORY[w] || ['Nueva infraestructura', '']);
}

/** Tramos cortados por una obra de cambio de ancho en curso. */
export function closedTramos(s) {
  return new Set(s.projects.filter(p => !p.done && p.type === 'tramo' && p.work === 'standard').map(p => p.target));
}

// ---------------------------------------------------------------- enrutado
/** Perfil de circulación de un modelo de tren. */
export function profileOf(m) { return {fixed: m.gauge === 'uic', electric: m.power === 'electric', speed: m.speed}; }
export const PROFILES = {ave: {fixed: true, electric: true, speed: 300}, alvia: {fixed: false, electric: true, speed: 250}, hybrid: {fixed: false, electric: false, speed: 250}};
const MODES = ['std', 'ib'];

function graph(s) {
  if (s.__graph?.ver === s.infra.ver && s.__graph.closed === closedKey(s)) return s.__graph;
  const adj = {};
  for (const id in NODES) adj[id] = [];
  for (const d of allTramos(s)) {
    if (!adj[d.a] || !adj[d.b]) continue;
    adj[d.a].push({d, to: d.b, rev: false});
    adj[d.b].push({d, to: d.a, rev: true});
  }
  const g = {ver: s.infra.ver, closed: closedKey(s), adj, closedSet: closedTramos(s), cache: new Map()};
  Object.defineProperty(s, '__graph', {value: g, enumerable: false, configurable: true, writable: true});
  return g;
}
function closedKey(s) { return s.projects.filter(p => !p.done && p.type === 'tramo' && p.work === 'standard').map(p => p.target).join(','); }

/** Coste (minutos) y faltas de recorrer un tramo en un modo; null si no se puede ni con faltas. */
function traverse(s, g, e, mode, prof, relaxed) {
  const st = s.infra.t[e.d.id], faults = [];
  if (!st) return null;
  if (!st.b) { if (!relaxed) return null; faults.push({type: 'build', tramo: e.d.id}); }
  if (g.closedSet.has(e.d.id)) { if (!relaxed) return null; faults.push({type: 'closed', tramo: e.d.id}); }
  if (prof.electric && st.e === 'no') { if (!relaxed) return null; faults.push({type: 'elec', tramo: e.d.id}); }
  const ok = st.g === 'mixto' || (mode === 'std' ? st.g === 'std' : st.g === 'ib');
  if (!ok) { if (!relaxed || !prof.fixed) return null; faults.push({type: 'gauge', tramo: e.d.id}); }
  const top = Math.min(st.v, prof.speed, st.e === 'no' ? 160 : 999);
  const minutes = e.d.km / Math.max(40, top * .84) * 60;
  return {minutes, faults};
}

/** Recorrido por los nodos de paso con el perfil dado. relaxed: admite faltas (para explicar qué falta). */
function search(s, way, prof, relaxed) {
  const g = graph(s), W = way.length, PEN = 60;
  const modes = prof.fixed ? ['std'] : MODES;
  const key = (k, n, m) => k + '|' + n + '|' + m;
  const dist = new Map(), prev = new Map(), heap = [];
  const push = (c, k, n, m) => { heap.push([c, k, n, m]); let i = heap.length - 1; while (i > 0) { const p = (i - 1) >> 1; if (heap[p][0] <= heap[i][0]) break; [heap[p], heap[i]] = [heap[i], heap[p]]; i = p; } };
  const pop = () => { const top = heap[0], last = heap.pop(); if (heap.length) { heap[0] = last; let i = 0; for (;;) { const l = 2 * i + 1, r = l + 1; let m = i; if (l < heap.length && heap[l][0] < heap[m][0]) m = l; if (r < heap.length && heap[r][0] < heap[m][0]) m = r; if (m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m; } } return top; };
  for (const m of modes) { dist.set(key(0, way[0], m), 0); push(0, 0, way[0], m); }
  let goal = null;
  while (heap.length) {
    const [c, k, n, m] = pop();
    if (c > (dist.get(key(k, n, m)) ?? Infinity)) continue;
    if (k === W - 1 && n === way[W - 1]) { goal = key(k, n, m); break; }
    const relax = (nc, nk, nn, nm, step) => { const kk = key(nk, nn, nm); if (nc < (dist.get(kk) ?? Infinity)) { dist.set(kk, nc); prev.set(kk, [key(k, n, m), step]); push(nc, nk, nn, nm); } };
    // llegar a un nodo de paso avanza de capa sin coste
    if (k < W - 1 && n === way[k + 1]) relax(c, k + 1, n, m, null);
    // cambio de ancho en el nodo
    if (!prof.fixed) {
      const other = m === 'std' ? 'ib' : 'std';
      if (hasChanger(s, n)) relax(c + CHANGE_MINUTES, k, n, other, {change: n});
      else if (relaxed) relax(c + CHANGE_MINUTES + PEN, k, n, other, {change: n, fault: {type: 'changer', node: n}});
    }
    for (const e of g.adj[n] || []) {
      const t = traverse(s, g, e, m, prof, relaxed);
      if (!t) continue;
      relax(c + t.minutes + t.faults.length * PEN, k, e.to, m, {tramo: e.d.id, rev: e.rev, minutes: t.minutes, faults: t.faults});
    }
  }
  if (!goal) return null;
  const steps = [];
  for (let at = goal; prev.has(at);) { const [p, step] = prev.get(at); if (step) steps.push(step); at = p; }
  steps.reverse();
  const tramos = [], changes = [], faults = [];
  let km = 0, minutes = 0;
  for (const st of steps) {
    if (st.change) { changes.push(st.change); minutes += CHANGE_MINUTES; if (st.fault) faults.push(st.fault); continue; }
    const d = tramoDef(s, st.tramo);
    tramos.push({id: st.tramo, rev: st.rev});
    km += d.km; minutes += st.minutes;
    faults.push(...st.faults);
  }
  return {tramos, changes, faults, km: Math.round(km), minutes: Math.round(minutes)};
}

/** ¿Puede circular este perfil por los nodos de paso? Devuelve recorrido, tiempo y, si no, qué falta. */
export function plan(s, way, prof) {
  const g = graph(s), ck = way.join(',') + '#' + (prof.fixed ? 'f' : 'v') + (prof.electric ? 'e' : 'h') + prof.speed;
  if (g.cache.has(ck)) return g.cache.get(ck);
  let out = search(s, way, prof, false);
  // Un rodeo enorme para esquivar un tramo (catenaria, ancho) no es un servicio: cuenta como bloqueado.
  if (out && out.km > physicalKm(s, way) * 1.3 + 40) out = null;
  if (out) out.ok = true;
  else {
    out = search(s, way, prof, true) || {tramos: [], changes: [], faults: [{type: 'nopath'}], km: 0, minutes: 0};
    out.ok = false;
    if (!out.faults.length) out.faults.push({type: 'detour'});
    const seen = new Set();
    out.faults = out.faults.filter(f => { const k = f.type + (f.tramo || f.node || ''); if (seen.has(k)) return false; seen.add(k); return true; });
  }
  g.cache.set(ck, out);
  return out;
}

/** Kilómetros del camino más corto por las vías existentes o proyectadas, sin mirar ancho ni catenaria. */
function physicalKm(s, way) {
  const g = graph(s), ck = 'km#' + way.join(',');
  if (g.cache.has(ck)) return g.cache.get(ck);
  let total = 0;
  for (let k = 0; k + 1 < way.length; k++) {
    const dist = {[way[k]]: 0}, done = new Set();
    for (;;) {
      let n = null;
      for (const id in dist) if (!done.has(id) && (n === null || dist[id] < dist[n])) n = id;
      if (n === null || n === way[k + 1]) break;
      done.add(n);
      for (const e of g.adj[n] || []) { const d = dist[n] + e.d.km; if (d < (dist[e.to] ?? Infinity)) dist[e.to] = d; }
    }
    total += dist[way[k + 1]] ?? 0;
  }
  g.cache.set(ck, total);
  return total;
}

/** Texto de una falta del recorrido. */
export function faultText(s, f) {
  const d = f.tramo ? tramoDef(s, f.tramo) : null, name = d ? d.name.replace(/^LAV /, '') : '';
  switch (f.type) {
    case 'build': return `Falta construir ${d?.name || 'una línea'}`;
    case 'closed': return `${name}: cortado por obras de cambio de ancho`;
    case 'elec': return `${name}: sin catenaria`;
    case 'gauge': return `${name}: ancho ${GAUGE_LABEL[s.infra.t[f.tramo]?.g]?.toLowerCase() || 'distinto'}`;
    case 'changer': return `Sin cambiador de ancho en ${NODES[f.node]?.name || f.node}`;
    case 'detour': return 'Solo podría ir dando un rodeo absurdo';
    default: return 'No hay vías que unan estas ciudades';
  }
}

/** Puntos [lon,lat] de un recorrido, en orden de marcha. */
export function pathCoords(s, p) {
  const out = [];
  for (const {id, rev} of p.tramos) {
    const pts = tramoGeom(tramoDef(s, id)).pts, seq = rev ? [...pts].reverse() : pts;
    for (const q of seq) if (!out.length || out.at(-1)[0] !== q[0] || out.at(-1)[1] !== q[1]) out.push(q);
  }
  return out;
}
/** Nodos del recorrido, en orden. */
export function pathNodes(s, p, first) {
  const out = [first];
  for (const {id, rev} of p.tramos) { const d = tramoDef(s, id); out.push(rev ? d.a : d.b); }
  return out;
}

// ---------------------------------------------------------------- obras
export const WORKS = {
  electrify: {label: 'Electrificar a 25 kV', verb: 'Electrificar', perKm: .42, base: 6, months: km => Math.round(12 + km / 10)},
  mixed: {label: 'Tercer carril: ancho mixto', verb: 'Poner ancho mixto', perKm: .5, base: 8, months: km => Math.round(14 + km / 9)},
  standard: {label: 'Cambio a ancho estándar', verb: 'Pasar a ancho estándar', perKm: .3, base: 5, months: km => Math.round(8 + km / 14), closes: true},
};
export const CHANGER_WORK = {label: 'Cambiador de ancho', cost: 18, months: 10};

/** Obras posibles en un tramo con su estado actual. */
export function tramoWorks(s, id) {
  const st = s.infra.t[id], d = tramoDef(s, id);
  if (!st || !d || !st.b || d.custom) return [];
  const busy = s.projects.some(p => !p.done && p.type === 'tramo' && p.target === id);
  const out = [];
  if (st.e === 'no') out.push('electrify');
  if (st.g === 'ib') out.push('mixed', 'standard');
  return out.map(w => ({work: w, ...WORKS[w], cost: Math.round(WORKS[w].base + WORKS[w].perKm * d.km), duration: WORKS[w].months(d.km), busy}));
}
/** ¿Se puede construir un cambiador en este nodo? Hace falta que confluyan vías de distinto ancho. */
export function changerPossible(s, node) {
  if (!NODES[node] || hasChanger(s, node) || NODES[node].kind === 'foreign') return false;
  const gs = new Set();
  for (const d of allTramos(s)) if ((d.a === node || d.b === node) && s.infra.t[d.id]?.b) gs.add(s.infra.t[d.id].g);
  return gs.has('std') && gs.has('ib');
}
