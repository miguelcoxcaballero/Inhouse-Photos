// Relaciones jugables: los 56 corredores de la campaña más las líneas de Cercanías y
// relaciones AV/LD/MD que aparecen en el horario oficial. Los parámetros económicos
// (demanda potencial, tarifa media) son de juego; las circulaciones son las publicadas.
import {ROUTES, CITY} from './data.js';
import {STATIONS, STATION, LINES, NETWORKS, ROUTE_INFO, routeStats} from './schedule.js';

for (const s of STATIONS) if (!CITY['st' + s.id]) CITY['st' + s.id] = {id: 'st' + s.id, name: s.name, lon: s.lon, lat: s.lat};

const PER_TRAIN = {madrid: 360, rodalies: 300, valencia: 200, bilbao: 180, sevilla: 150, malaga: 200, asturias: 80, cantabria: 85,
  murciaAlicante: 140, cadiz: 150, sanSebastian: 190, zaragoza: 110, cartagena: 60, ferrol: 40, leon: 35};
const KIND_LABEL = {av: 'Alta velocidad', ld: 'Larga distancia', intercity: 'Larga distancia', md: 'Media distancia', regional: 'Media distancia', commuter: 'Cercanías'};
export const kindLabel = r => r.net ? 'Cercanías · ' + (NETWORKS.find(n => n.id === r.net)?.name || r.net) : KIND_LABEL[r.kind] || 'Servicio';
export const networkName = id => NETWORKS.find(n => n.id === id)?.name || id;

function cityName(id) { return CITY[id]?.name || id; }

function realFields(info, base = {}) {
  const st = routeStats(info.id, 'L') || routeStats(info.id, 'S') || routeStats(info.id, 'D');
  if (!st) return {real: false};
  const line = info.line !== null && info.line !== undefined ? LINES[info.line] : null;
  const prod = info.products || [];
  const commuter = info.kind === 'commuter' || !!info.net;
  const km = Math.max(2, Math.round(info.km || base.km || 10));
  const av = prod.some(p => /^(AVE|AVLO|Avant)/.test(p));
  const perTrain = commuter ? PER_TRAIN[info.net] || 150 : av ? 290 : /Alvia|Intercity|Euromed/.test(prod[0] || '') ? 210 : 75;
  return {
    real: true,
    baseFrequency: Math.max(1, st.perDirection),
    peak: st.peak,
    minutes: st.minutes,
    km: base.km || km,
    net: info.net || null,
    code: line?.code || null,
    color: line?.color || null,
    products: prod,
    stations: info.stations || 2,
    demand: base.demand ? Math.max(base.demand, Math.round(st.trips * perTrain * 30 * 1.25)) : Math.round(st.trips * perTrain * 30 * 1.25),
  };
}

function generated(info) {
  const commuter = info.kind === 'commuter';
  const ends = info.ends || ['st' + info.endStations[0], 'st' + info.endStations[1]];
  const prod = info.products || [];
  const av = prod.some(p => /^(AVE|AVLO|Avant)/.test(p));
  const alvia = /Alvia|Euromed|Intercity/.test(prod[0] || '');
  const extra = realFields(info);
  const km = extra.km;
  const name = commuter ? networkName(info.net) + ' ' + info.code : ends.map(cityName).join(' — ');
  return {
    id: info.id, name, ends, via: ends, km,
    gauge: info.metric ? 'metric' : av ? 'uic' : alvia ? 'mixed' : 'iberian',
    power: 'electric', speed: av ? 300 : alvia ? 220 : commuter ? 120 : 160,
    demand: extra.demand, fare: commuter ? (info.metric ? 1.5 : 1.7) : Math.max(4, Math.round(km * (av ? 0.095 : alvia ? 0.08 : 0.075))),
    active: false, kind: commuter ? 'commuter' : av ? 'av' : alvia ? 'intercity' : 'regional', unlock: 0, project: null, level: 0,
    frequency: Math.max(1, Math.round(extra.baseFrequency / 2)), fleet: null, units: 0, generated: true, ...extra,
  };
}

const extra = [];
for (const info of Object.values(ROUTE_INFO)) if (!info.base) extra.push(generated(info));
// Las relaciones diésel conocidas del horario se marcan a mano: el GTFS no publica la tracción.
const DIESEL = /zafra|jabugo|valencia-de-alcantara|caceres|badajoz|teruel|encinacorba|ferreruela|soria|baides|ribadeo|llanes|bilbao--leon|almeria|linares|ronda|algeciras|cabeza-del-buey|villanueva-de-la-serena|vilagarcia|carballino|puebla-de-sanabria|segovia--cercedilla|talavera|ciudad-real|huelva|osuna|navarrete/;
for (const r of extra) if (!r.net && DIESEL.test(r.id)) r.power = 'diesel';

export const ALL_ROUTES = [...ROUTES.map(r => {
  const x = {...r, ...realFields(ROUTE_INFO[r.id] || {id: r.id}, r)};
  if (x.net) { x.fare = 1.7; x.speed = 120; x.name = networkName(x.net) + ' ' + x.code; }
  if (x.real) x.frequency = Math.min(x.frequency, x.baseFrequency);
  return x;
}), ...extra];
export const ROUTE_DEF = Object.fromEntries(ALL_ROUTES.map(r => [r.id, r]));
export {STATION};
