// Horario oficial Renfe (GTFS) en tiempo de ejecución: estaciones, tramos con geometría,
// circulaciones de un día tipo y posición interpolada de cada tren sobre su trazado.
import {TT} from './assets/timetable.js';

export const DAY_TYPES = {L: 'Laborable', S: 'Sábado', D: 'Domingo y festivo'};
const SMALL = new Set(['de', 'del', 'la', 'las', 'los', 'el', 'y', 'i', 'en', 'a']);
const tidy = name => name === name.toUpperCase() ? name.toLowerCase().replace(/(^|[\s\-\/(.'])(\p{L})/gu, (m, sep, ch) => sep + ch.toUpperCase()).replace(/\s(\p{L}+)/gu, (m, w) => SMALL.has(w.toLowerCase()) ? ' ' + w.toLowerCase() : m) : name;
export const STATIONS = TT.stations.map(([id, name, lon, lat, traffic], i) => ({i, id, name: tidy(name), lon, lat, traffic}));
export const STATION = Object.fromEntries(STATIONS.map(s => [s.id, s]));
export const LINES = TT.lines;
export const NETWORKS = TT.networks;
export const META = TT.meta;
export const ROUTE_INFO = Object.fromEntries(TT.routes.map(r => [r.id, r]));
const routeIds = TT.routes.map(r => r.id);

// Festivos nacionales fijos (se tratan como domingo). Las fiestas autonómicas y locales no se modelan.
const HOLIDAYS = ['01-01', '01-06', '05-01', '08-15', '10-12', '11-01', '12-06', '12-08', '12-25'];
export function dayType(date) {
  const md = date.toISOString().slice(5, 10), wd = date.getUTCDay();
  if (wd === 0 || HOLIDAYS.includes(md)) return 'D';
  return wd === 6 ? 'S' : 'L';
}

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

const edgeCache = new Map();
/** Geometría de un tramo: puntos [lon,lat], longitudes acumuladas en km y tipo (0 vía, 1 aproximado, 2 carretera). */
export function edge(i) {
  let e = edgeCache.get(i);
  if (!e) {
    const [a, b, g, km, approx] = TT.edges[i];
    const pts = decode(g), cum = [0];
    for (let k = 1; k < pts.length; k++) {
      const [x1, y1] = pts[k - 1], [x2, y2] = pts[k];
      const dx = (x2 - x1) * 111.32 * Math.cos((y1 + y2) / 2 * Math.PI / 180), dy = (y2 - y1) * 110.57;
      cum.push(cum[k - 1] + Math.hypot(dx, dy));
    }
    e = {i, a, b, pts, cum, km, approx};
    edgeCache.set(i, e);
  }
  return e;
}
export const EDGE_COUNT = TT.edges.length;

const dayCache = {};
/** Todas las circulaciones publicadas de un día tipo, ordenadas por salida. */
export function dayTrips(type) {
  if (dayCache[type]) return dayCache[type];
  const list = TT.trips[type].map(([line, pattern, timing, start, number, route, bus], k) => {
    const [stations, edges] = TT.patterns[pattern], offs = TT.timings[timing];
    const times = new Array(stations.length * 2);
    times[0] = start;
    for (let j = 0; j < offs.length; j++) times[j + 1] = start + offs[j];
    times[times.length - 1] = times[times.length - 2];
    // Las salidas entre las 00:00 y las 03:00 son servicios nocturnos: se cierran al final de la jornada operativa.
    if (start < 180) for (let j = 0; j < times.length; j++) times[j] += 1440;
    return {key: type + k, k, line, pattern, stations, edges, times, start, end: times[times.length - 1], number, route: routeIds[route], bus: !!bus};
  }).map(t => ({...t, start: t.times[0], end: t.times[t.times.length - 1]})).sort((a, b) => a.start - b.start);
  return dayCache[type] = list;
}

/** Circulaciones de una relación jugable en un día tipo. */
export function routeTrips(type, routeId) {
  const cache = dayTrips(type);
  cache.byRoute ||= cache.reduce((m, t) => ((m[t.route] ||= []).push(t), m), {});
  return cache.byRoute[routeId] || [];
}

/** Conserva una fracción de las circulaciones, repartidas por sentido y a lo largo del día. */
export function thin(trips, fraction) {
  if (fraction >= 0.999) return trips;
  const target = Math.max(1, Math.round(trips.length * fraction));
  const groups = {};
  for (const t of trips) (groups[t.stations[0] + '>' + t.stations.at(-1)] ||= []).push(t);
  const list = Object.values(groups).map(g => ({g, q: g.length * target / trips.length}));
  for (const x of list) x.k = Math.floor(x.q);
  let left = target - list.reduce((v, x) => v + x.k, 0);
  for (const x of [...list].sort((a, b) => (b.q - b.k) - (a.q - a.k) || b.g.length - a.g.length)) { if (left <= 0) break; x.k++; left--; }
  const out = [];
  for (const {g, k} of list) for (let i = 0; i < k; i++) out.push(g[Math.min(g.length - 1, Math.floor((i + .5) * g.length / k))]);
  return out.sort((a, b) => a.start - b.start);
}

/** Estadísticas de una relación: pico simultáneo, duración mediana, salidas por sentido. */
const statCache = {};
export function routeStats(routeId, type = 'L') {
  const key = type + routeId;
  if (statCache[key]) return statCache[key];
  const trips = routeTrips(type, routeId);
  if (!trips.length) return statCache[key] = null;
  const ev = [];
  for (const t of trips) ev.push([t.start, 1], [t.end + 10, -1]);
  ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  let cur = 0, peak = 0;
  for (const [, d] of ev) { cur += d; peak = Math.max(peak, cur); }
  const durations = trips.map(t => t.end - t.start).sort((a, b) => a - b);
  const directions = new Set(trips.map(t => t.stations[0] + '>' + t.stations.at(-1)));
  return statCache[key] = {trips: trips.length, peak, minutes: durations[durations.length >> 1], first: trips[0].start,
    last: Math.max(...trips.map(t => t.end)), perDirection: Math.ceil(trips.length / Math.min(2, directions.size || 1))};
}

function along(e, km, reverse) {
  const total = e.cum[e.cum.length - 1];
  let d = reverse ? total - km : km;
  d = Math.max(0, Math.min(total, d));
  let lo = 0, hi = e.cum.length - 1;
  while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (e.cum[mid] <= d) lo = mid; else hi = mid; }
  const a = e.pts[lo], b = e.pts[hi] || a, seg = (e.cum[hi] - e.cum[lo]) || 1, f = (d - e.cum[lo]) / seg;
  let angle = Math.atan2(-(b[1] - a[1]), (b[0] - a[0]) * Math.cos(a[1] * Math.PI / 180));
  if (reverse) angle += Math.PI;
  return {lon: a[0] + (b[0] - a[0]) * f, lat: a[1] + (b[1] - a[1]) * f, angle};
}

/** Posición en `minute` (minutos desde las 00:00 del día de servicio). `delay` desplaza el horario. */
export function position(trip, minute, delay = 0) {
  const m = minute - delay, T = trip.times, n = trip.stations.length;
  if (m < T[0] || m > T[T.length - 1]) return null;
  for (let j = 0; j < n; j++) {
    const arr = T[j * 2], dep = T[j * 2 + 1];
    if (m >= arr && m <= dep) {
      const s = STATIONS[trip.stations[j]];
      return {lon: s.lon, lat: s.lat, angle: null, stopped: true, at: j, next: j + 1 < n ? j + 1 : j};
    }
    if (j + 1 < n && m > dep && m < T[j * 2 + 2]) {
      const span = T[j * 2 + 2] - dep;
      // Aceleración y frenado suaves: el tren no salta de 0 a velocidad de línea.
      let f = (m - dep) / span;
      f = f < 0.12 ? f * f / 0.24 : f > 0.88 ? 1 - (1 - f) * (1 - f) / 0.24 : 0.06 + (f - 0.12) * (0.88 / 0.76);
      const ref = trip.edges[j];
      if (ref === 'n' || ref === null || ref === undefined) {
        const s = STATIONS[trip.stations[j]];
        return {lon: s.lon, lat: s.lat, angle: null, stopped: true, at: j, next: j + 1};
      }
      const reverse = ref < 0, e = edge(reverse ? -1 - ref : ref);
      const p = along(e, f * e.cum[e.cum.length - 1], reverse);
      return {...p, stopped: false, at: j, next: j + 1, approx: e.approx};
    }
  }
  return null;
}

/** Longitud del recorrido de una circulación. */
export function tripKm(trip) {
  let km = 0;
  for (const ref of trip.edges) if (ref !== 'n' && ref !== null) km += TT.edges[ref < 0 ? -1 - ref : ref][3];
  return km;
}

/** Uso de cada tramo en un día tipo: circulaciones totales, por relación y por línea. */
const usageCache = {};
export function edgeUsage(type = 'L') {
  if (usageCache[type]) return usageCache[type];
  const use = new Map();
  for (const t of dayTrips(type)) for (const ref of t.edges) {
    if (ref === 'n' || ref === null) continue;
    const i = ref < 0 ? -1 - ref : ref;
    let u = use.get(i);
    if (!u) use.set(i, u = {count: 0, routes: new Map(), lines: new Map(), bus: 0});
    u.count++; u.routes.set(t.route, (u.routes.get(t.route) || 0) + 1); u.lines.set(t.line, (u.lines.get(t.line) || 0) + 1); if (t.bus) u.bus++;
  }
  return usageCache[type] = use;
}

/** Tramos de una relación (para resaltar, obras y zoom). */
export function routeEdges(routeId) {
  const set = new Set();
  for (const type of ['L', 'S', 'D']) for (const t of routeTrips(type, routeId)) for (const ref of t.edges) if (ref !== 'n' && ref !== null) set.add(ref < 0 ? -1 - ref : ref);
  return [...set];
}

/** Paradas con horario legible de una circulación. */
export function tripStops(trip, delay = 0) {
  return trip.stations.map((s, j) => ({station: STATIONS[s], arr: trip.times[j * 2] + (j ? delay : 0), dep: trip.times[j * 2 + 1] + delay}));
}

const SHORT = {'Media Distancia': 'MD', 'Regional': 'R', 'Regional Exprés': 'RE', 'Proximidad': 'PX', 'AVE Internacional': 'AVE', 'Avant Exprés': 'Avant',
  'Euromed': 'EM', 'Intercity': 'IC', 'Trencelta': 'TC'};
/** Código corto de una línea o producto para chips y paneles. */
export const lineCode = i => SHORT[LINES[i]?.code] || LINES[i]?.code || 'R';
