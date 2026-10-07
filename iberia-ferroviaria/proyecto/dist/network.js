// Relaciones jugables: los corredores de la campaña (data.js) y las relaciones AVE y Alvia del horario oficial.
// Cada relación tiene sus nodos de paso (via): por dónde puede ir cada tren lo decide la red (infra.js).
import {ROUTES, CITY, POP} from './data.js';
import {ROUTE_INFO, STATIONS, routeStats} from './schedule.js';
import {TRAMOS} from './infra.js';

for (const st of STATIONS) if (!CITY['st' + st.id]) CITY['st' + st.id] = {id: 'st' + st.id, name: st.name, lon: st.lon, lat: st.lat};

export const KIND_LABEL = {av: 'Alta velocidad', alvia: 'Alvia', new: 'Sin tren'};
const cityName = id => CITY[id]?.name || id;

/** Kilómetros del camino más corto por la red (existente o proyectada) entre los nodos de paso. */
const adj = {};
for (const t of TRAMOS) { (adj[t.a] ||= []).push([t.b, t.km]); (adj[t.b] ||= []).push([t.a, t.km]); }
export function wayKm(way) {
  let total = 0;
  for (let k = 0; k + 1 < way.length; k++) {
    const dist = {[way[k]]: 0}, done = new Set();
    for (;;) {
      let n = null;
      for (const id in dist) if (!done.has(id) && (n === null || dist[id] < dist[n])) n = id;
      if (n === null || n === way[k + 1]) break;
      done.add(n);
      for (const [m, km] of adj[n] || []) if (dist[n] + km < (dist[m] ?? Infinity)) dist[m] = dist[n] + km;
    }
    total += dist[way[k + 1]] ?? 0;
  }
  return Math.round(total);
}

/** Demanda mensual potencial de una relación sin horario publicado, según la población de sus extremos. */
export function potentialDemand(a, b) { return Math.round(110 * Math.sqrt((POP[a] || 30) * (POP[b] || 30))); }
export const defaultFare = (km, kind) => Math.max(8, Math.round(km * (kind === 'av' ? .095 : .082)));

function realFields(info) {
  const st = routeStats(info.id, 'L') || routeStats(info.id, 'S') || routeStats(info.id, 'D');
  if (!st) return {real: false};
  const ave = (info.products || [])[0] === 'AVE';
  return {real: true, baseFrequency: Math.max(1, st.perDirection), peak: st.peak, minutes: st.minutes, km: Math.max(10, Math.round(info.km || 10)),
    products: info.products || [], stations: info.stations || 2, kind: ave ? 'av' : 'alvia', demand: Math.round(st.trips * (ave ? 290 : 210) * 30 * 1.25)};
}

/** Relación nueva (corredor sin horario o servicio creado por el jugador). */
export function makeRoute(id, ends, via, kind = 'new', extra = {}) {
  const km = wayKm(via) || 50;
  return {id, name: ends.map(cityName).join(' — '), ends, via, km, kind, demand: potentialDemand(...ends), fare: defaultFare(km, kind === 'av' ? 'av' : 'alvia'),
    active: false, level: 0, frequency: 2, fleet: null, units: 0, real: false, ...extra};
}

const base = ROUTES.map(r => {
  const info = ROUTE_INFO[r.id] || {id: r.id};
  const x = makeRoute(r.id, r.ends, r.via, r.kind), real = realFields(info);
  if (real.real) Object.assign(x, real, {fare: defaultFare(real.km, real.kind)});
  if (x.real) x.frequency = Math.max(1, Math.round(x.baseFrequency / 2));
  return x;
});
const generated = Object.values(ROUTE_INFO).filter(info => !info.base && info.way?.length >= 2).map(info => {
  const ends = info.ends || ['st' + info.endStations[0], 'st' + info.endStations[1]], real = realFields(info);
  const x = makeRoute(info.id, ends, info.way, real.kind || 'alvia');
  Object.assign(x, real, {fare: defaultFare(real.km || x.km, real.kind)});
  if (x.real) x.frequency = Math.max(1, Math.round(x.baseFrequency / 2));
  return x;
}).filter(r => r.real);

export const ALL_ROUTES = [...base, ...generated];
export const ROUTE_DEF = Object.fromEntries(ALL_ROUTES.map(r => [r.id, r]));
