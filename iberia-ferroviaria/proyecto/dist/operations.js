// Jornadas por turnos: cada día empieza con la primera salida y termina con la última llegada.
// Las relaciones con horario oficial usan las circulaciones AVE y Alvia publicadas por Renfe para el tipo de día;
// las demás, un plan con salidas repartidas y el recorrido que permite la red.
import * as E from './engine.js';
import {MODEL, CITY, CITIES} from './data.js';
import * as S from './schedule.js';
import * as I from './infra.js';

export const opDays = m => new Date(Date.UTC(2022 + Math.floor(m / 12), m % 12 + 1, 0)).getUTCDate();
export const clockText = m => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(Math.floor(m) % 60).padStart(2, '0')}${m >= 1440 ? ' +' + Math.floor(m / 1440) : ''}`;
export function dayDate(s) { return new Date(Date.UTC(2022 + Math.floor(Math.min(s.month, 347) / 12), Math.min(s.month, 347) % 12, s.ops?.day || 1)); }
export function dayLabel(s) { return dayDate(s).toLocaleDateString('es-ES', {weekday: 'short', day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC'}); }
export function dayKind(s) { return S.dayType(dayDate(s)); }
export function ensureOps(s) {
  if (!s.ops) s.ops = {day: 1, minute: 0, phase: 'planning', incidents: [], resolved: [], last: null, priority: 'balanced', completed: 0};
  s.ops.choices ||= {};
  return s.ops;
}

const SURGES = ['Partido de fútbol', 'Congreso internacional', 'Puente festivo', 'Concierto multitudinario', 'Feria regional', 'Huelga de autobuses', 'Oposiciones en la capital', 'Final de temporada turística'];
/** Comprueba los momentos del día: refuerzo a tiempo → bonificación. Devuelve los recién cumplidos. */
export function checkSurges(s) {
  const op = ensureOps(s), done = [];
  for (const x of op.surges || []) {
    if (x.done || x.failed || op.phase !== 'running') continue;
    const r = s.routes.find(r => r.id === x.route);
    if (op.minute >= x.at && r?.active && r.frequency >= x.need) { x.done = true; s.cash += x.bonus; s.satisfaction = E.clamp(s.satisfaction + .3, 0, 100); done.push(x); }
    else if (op.minute > x.until) { x.failed = true; s.satisfaction = E.clamp(s.satisfaction - .3, 0, 100); }
  }
  return done;
}
/** Fuerza una incidencia cercana (tutorial). */
export function injectIncident(s, minute) {
  const op = ensureOps(s), t = servicePlan(s).find(t => t.dep <= minute + 20 && t.arrival > minute + 40 && !t.bus);
  if (!t) return null;
  const x = {trip: 'inc-tut-' + s.month + '-' + op.day, id: 'inc-tut', type: 'breakdown', route: t.route, target: t.id, label: t.label, place: '', at: Math.round(minute + 10), delay: 28, span: 60, reason: 'Fallo de tracción'};
  op.incidents.push(x);
  return x;
}
const INCIDENTS = {
  breakdown: {title: 'Avería de material', icon: '⚙', reasons: ['Fallo de tracción', 'Avería de puertas', 'Pantógrafo dañado', 'Fallo de freno detectado en ruta']},
  signal: {title: 'Incidencia de infraestructura', icon: '⚠', reasons: ['Fallo de señalización', 'Avería de un desvío', 'Corte de tensión en catenaria', 'Robo de cable']},
  trespass: {title: 'Arrollamiento o intrusión en la vía', icon: '⛔', reasons: ['Persona en la vía', 'Arrollamiento de animal', 'Objeto sobre la vía']},
  weather: {title: 'Meteorología adversa', icon: '☂', reasons: ['Viento fuerte: limitación de velocidad', 'Lluvias intensas', 'Nevada en la línea', 'Ola de calor: limitación temporal']},
  changer: {title: 'Avería en un cambiador de ancho', icon: '⇄', reasons: ['Atasco en el cambiador de ancho', 'Un bogie no quiere cambiar de ancho', 'Cambiador fuera de servicio por mantenimiento']},
};
export const INCIDENT_TYPES = INCIDENTS;
export const RESPONSES = {
  team: {label: 'Movilizar equipo de intervención', cost: .018, factor: .3, note: 'Reduce la demora al 30 %.'},
  bus: {label: 'Plan alternativo por carretera', cost: .009, factor: .85, note: 'Mantiene la demora, pero protege la satisfacción del viajero.'},
  wait: {label: 'Esperar a la resolución ordinaria', cost: 0, factor: 1, note: 'Sin coste inmediato.'},
};

const planCache = {key: null, trips: null};
const hashCode = x => [...String(x)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);
function planKey(s) {
  const op = ensureOps(s);
  return [s.month, op.day, op.priority, JSON.stringify(op.incidents), JSON.stringify(op.choices), op.resolved.join(','),
    s.routes.filter(r => r.active).map(r => r.id + ':' + r.frequency + ':' + r.fleet + ':' + (r.first ?? '') + ':' + (r.last ?? '')).join('|'),
    s.projects.filter(p => !p.done).map(p => p.id).join(','), s.infra.ver].join('#');
}

/** Obra en curso sobre el recorrido de una relación (con su tren actual). */
export function workOn(s, r) {
  if (s.projects.some(p => !p.done && p.type === 'upgrade' && p.route === r.id)) return s.projects.find(p => !p.done && p.type === 'upgrade' && p.route === r.id);
  const f = s.fleet.find(f => f.id === r.fleet), m = f && MODEL[f.model];
  const tramos = new Set((m ? E.routeCheck(s, r, m) : E.routeOptions(s, r).hybrid).tramos.map(t => t.id));
  return s.projects.find(p => !p.done && p.type === 'tramo' && tramos.has(p.target)) || null;
}
const isCity = id => CITIES.some(c => c.id === id);

/** Circulaciones del día de campaña, con retrasos derivados de incidencias. */
export function servicePlan(s) {
  const key = planKey(s);
  if (planCache.key === key) return planCache.trips;
  const op = ensureOps(s), type = dayKind(s), trips = [];
  for (const r of s.routes.filter(r => r.active)) {
    const f = s.fleet.find(f => f.id === r.fleet), m = MODEL[f?.model];
    if (!m) continue;
    const work = workOn(s, r), path = E.routeCheck(s, r, m);
    const real = r.real ? S.thin(S.routeTrips(type, r.id), Math.min(1, r.frequency / r.baseFrequency)) : null;
    if (real && real.length) {
      for (const t of real) {
        const name = S.STATIONS[t.stations[0]].name + ' → ' + S.STATIONS[t.stations.at(-1)].name;
        trips.push({id: t.key, route: r.id, name, label: (t.bus ? 'Bus ' : '') + (r.code || S.LINES[t.line].code) + (t.number ? ' ' + t.number : ''),
          line: t.line, number: t.number, model: t.bus ? 'Autobús de sustitución' : m.name, seats: t.bus ? 55 : m.seats, dep: t.start,
          scheduled: t.end, duration: t.end - t.start, delay: work ? 3 : 0, real: true, bus: t.bus, trip: t, ends: [t.stations[0], t.stations.at(-1)], family: m.family, changes: path.changes});
      }
      continue;
    }
    // Plan propio: salidas repartidas entre las 6:30 y las 21:30 por el recorrido que permite la red.
    if (!path.ok) continue;
    const coords = I.pathCoords(s, path), cum = [0];
    for (let k = 1; k < coords.length; k++) cum.push(cum[k - 1] + Math.hypot((coords[k][0] - coords[k - 1][0]) * 85, (coords[k][1] - coords[k - 1][1]) * 111));
    const stops = I.pathNodes(s, path, r.via[0]).filter((n, k, all) => k === 0 || k === all.length - 1 || isCity(n)).length;
    const duration = Math.round(path.minutes + Math.max(0, stops - 2) * 2), first = 390, last = 1290;
    for (let direction = 0; direction < 2; direction++) for (let i = 0; i < r.frequency; i++) {
      const dep = Math.round(first + (last - first) * (r.frequency === 1 ? .35 : i / (r.frequency - 1))) + direction * 7;
      const ends = direction ? [...r.ends].reverse() : r.ends;
      trips.push({id: `${r.id}-${direction}-${i}`, route: r.id, name: ends.map(id => CITY[id]?.name || id).join(' → '), label: m.family + ' ' + (9000 + (hashCode(r.id) % 900) + i * 2 + direction),
        model: m.name, seats: m.seats, dep, scheduled: dep + duration, duration, delay: work ? 6 : 0, direction, real: false, family: m.family, changes: path.changes,
        coords: direction ? [...coords].reverse() : coords, cum: direction ? cum.map(x => cum.at(-1) - x).reverse() : cum});
    }
  }
  // Retrasos por incidencias del día.
  for (const x of op.incidents) {
    const choice = op.choices[x.trip] || (op.resolved.includes(x.trip) ? 'team' : null);
    const factor = choice ? RESPONSES[choice].factor : 1;
    for (const t of trips) {
      if (t.route !== x.route) continue;
      let d = 0;
      if (x.type === 'breakdown' || !x.type) {
        if (t.id === x.target) d = x.delay;
        else if (t.dep > x.at && t.dep < x.at + 70) d = Math.round(x.delay * .3);
      } else if (x.type === 'weather') {
        if (t.dep + t.duration > x.at && t.dep < x.at + x.span) d = x.delay;
      } else if (t.dep + t.duration > x.at && t.dep < x.at + x.span) {
        d = Math.max(4, Math.round(x.delay * (1 - Math.max(0, t.dep - x.at) / x.span)));
      }
      t.delay += Math.round(d * factor);
    }
  }
  for (const t of trips) {
    if (op.priority === 'punctual' && t.delay) t.delay = Math.max(0, t.delay - 4);
    t.arrival = t.scheduled + t.delay;
  }
  trips.sort((a, b) => a.dep - b.dep || a.id.localeCompare(b.id));
  planCache.key = key;
  planCache.trips = trips;
  return trips;
}

export function dayBounds(trips) {
  return trips.reduce((v, t) => ({first: Math.min(v.first, t.dep), last: Math.max(v.last, t.arrival)}), trips.length ? {first: Infinity, last: 0} : {first: 360, last: 360});
}

function pick(s, list) { return list[Math.floor(E.random(s) * list.length)]; }

/** Prepara la jornada: incidencias del día (sembradas), reloj en la primera salida. */
export function startDay(s) {
  E.ensurePlaying(s);
  if (!s.started || E.pendingDecision(s)) throw Error('Resuelve primero el consejo de dirección.');
  const op = ensureOps(s);
  if (op.phase === 'running') return;
  op.incidents = []; op.resolved = []; op.choices = {};
  const trips = servicePlan(s);
  if (trips.length) {
    const reliability = s.fleet.reduce((v, f) => v + f.condition * f.qty, 0) / Math.max(1, s.fleet.reduce((v, f) => v + f.qty, 0));
    const count = Math.min(4, Math.floor(E.random(s) * 2.2 + trips.length / 300 + (80 - reliability) / 40 + (s.maintenance < 1 ? .6 : 0)));
    const month = s.month % 12;
    for (let i = 0; i < Math.max(0, count); i++) {
      const trip = pick(s, trips.filter(t => !t.bus));
      if (!trip) break;
      const roll = E.random(s);
      let type = roll < .45 ? 'breakdown' : roll < .75 ? 'signal' : roll < .9 ? 'trespass' : 'weather';
      if (trip.changes?.length && E.random(s) < .35) type = 'changer';
      if (op.incidents.some(x => x.route === trip.route)) continue;
      let reason = pick(s, INCIDENTS[type].reasons);
      if (type === 'weather') reason = month <= 1 || month === 11 ? pick(s, ['Nevada en la línea', 'Viento fuerte: limitación de velocidad']) : month >= 5 && month <= 8 ? 'Ola de calor: limitación temporal' : pick(s, ['Lluvias intensas', 'Viento fuerte: limitación de velocidad']);
      if (type === 'changer') reason += ' de ' + (I.NODES[pick(s, trip.changes)]?.changer || I.NODES[pick(s, trip.changes)]?.name || '');
      const delay = type === 'breakdown' ? 15 + Math.floor(E.random(s) * 40) : type === 'weather' ? 6 + Math.floor(E.random(s) * 10) : 12 + Math.floor(E.random(s) * 30);
      const id = 'inc-' + s.month + '-' + op.day + '-' + i;
      const at = trip.dep + Math.floor(trip.duration * (.2 + E.random(s) * .5));
      const place = trip.real ? S.STATIONS[trip.trip.stations[Math.min(trip.trip.stations.length - 1, Math.floor(trip.trip.stations.length * .4))]].name : trip.name.split(' → ')[0];
      op.incidents.push({trip: id, id, type, route: trip.route, target: trip.id, label: trip.label, place, at, delay, span: type === 'weather' ? 240 : 60 + Math.floor(E.random(s) * 60), reason});
    }
  }
  // Momentos del día: picos de demanda que premian reforzar una relación a tiempo.
  op.surges = [];
  const open = s.routes.filter(r => r.active && r.frequency < E.maxFrequency(r));
  for (let i = 0; i < Math.min(2, open.length) && E.random(s) < .85; i++) {
    const r = open[Math.floor(E.random(s) * open.length)];
    if (op.surges.some(x => x.route === r.id)) continue;
    const ev = SURGES[Math.floor(E.random(s) * SURGES.length)], start = dayBounds(servicePlan(s)).first;
    const at = start + 90 + Math.floor(E.random(s) * 420);
    op.surges.push({id: 'sg-' + s.month + '-' + op.day + '-' + i, route: r.id, city: r.ends[Math.floor(E.random(s) * 2)], reason: ev, at, until: at + 180,
      need: Math.min(E.maxFrequency(r), r.frequency + Math.max(1, Math.ceil(E.maxFrequency(r) * .15))), bonus: Math.round((0.15 + E.random(s) * .35) * 100) / 100, done: false, failed: false});
  }
  op.minute = dayBounds(servicePlan(s)).first;
  op.phase = 'running';
}

export function moveClock(s, minutes = 10) {
  const op = ensureOps(s);
  if (op.phase !== 'running') return false;
  const last = dayBounds(servicePlan(s)).last;
  op.minute = Math.min(last, op.minute + minutes);
  return op.minute >= last;
}

export function resolveIncident(s, id, option = 'team') {
  const op = ensureOps(s), incident = op.incidents.find(x => x.trip === id);
  const response = RESPONSES[option];
  if (!response || !incident || op.phase !== 'running' || op.minute < incident.at || op.resolved.includes(id)) throw Error('No hay una incidencia pendiente que atender.');
  if (response.cost) E.spend(s, response.cost);
  op.resolved.push(id);
  op.choices[id] = option;
}

/** Cierra la jornada tras la última llegada y devuelve el parte del día. */
export function endDay(s) {
  const op = ensureOps(s);
  if (op.phase !== 'running' || op.minute < dayBounds(servicePlan(s)).last) throw Error('La jornada termina cuando llega el último tren.');
  const trips = servicePlan(s), late = trips.filter(t => t.delay > 5).length, b = E.balance(s), kind = dayKind(s);
  const unattended = op.incidents.filter(x => !op.resolved.includes(x.trip)).length;
  const protectedByBus = op.incidents.filter(x => op.choices[x.trip] === 'bus').length;
  const penalties = trips.reduce((v, t) => v + t.delay * .0004, 0) + (op.priority === 'punctual' ? .009 : 0);
  s.cash -= penalties;
  s.satisfaction = E.clamp(s.satisfaction - (late / Math.max(1, trips.length)) * .5 - unattended * .15 + protectedByBus * .05, 0, 100);
  const factor = {L: 1.08, S: .78, D: .7}[kind];
  const byRoute = {};
  for (const t of trips) byRoute[t.route] = (byRoute[t.route] || 0) + 1;
  const busiest = Object.entries(byRoute).sort((a, b) => b[1] - a[1])[0];
  const worst = trips.reduce((w, t) => t.delay > (w?.delay || 0) ? t : w, null);
  const km = trips.reduce((v, t) => v + (t.real ? S.tripKm(t.trip) : (t.cum?.at(-1) || s.routes.find(r => r.id === t.route)?.km || 0)), 0);
  op.last = {date: dayLabel(s), kind, trains: trips.length, late, punctuality: Math.round((1 - late / Math.max(1, trips.length)) * 100),
    passengers: Math.round(b.passengers / opDays(s.month) * factor), net: b.net / opDays(s.month) - penalties, first: dayBounds(trips).first, last: op.minute,
    incidents: op.incidents.length, attended: op.resolved.length, km: Math.round(km), buses: trips.filter(t => t.bus).length,
    busiest: busiest ? busiest[0] : null, busiestTrains: busiest ? busiest[1] : 0, worst: worst ? {label: worst.label, name: worst.name, delay: worst.delay} : null};
  op.completed++;
  op.phase = 'review';
  return op.last;
}

export function nextDay(s) {
  const op = ensureOps(s);
  if (op.phase !== 'review') throw Error('Cierra primero la jornada.');
  const {last, completed, priority} = op;
  if (op.day >= opDays(s.month)) { if (!E.step(s)) throw Error('No se puede cerrar el mes.'); op.day = 1; } else op.day++;
  E.advanceInfra(s);
  Object.assign(op, {phase: 'planning', minute: 0, incidents: [], resolved: [], choices: {}, surges: [], last, completed, priority});
}

export function skipMonth(s) {
  const op = ensureOps(s);
  if (op.phase === 'running') throw Error('Termina la jornada antes de delegar el mes.');
  if (!E.step(s)) return false;
  Object.assign(op, {day: 1, phase: 'planning', minute: 0, incidents: [], resolved: [], choices: {}, surges: []});
  return true;
}

// ---- Sol: posición aproximada (NOAA) con hora oficial peninsular (CET/CEST).
function dstOffset(date) {
  const y = date.getUTCFullYear(), lastSunday = m => { const d = new Date(Date.UTC(y, m + 1, 0)); return d.getUTCDate() - d.getUTCDay(); };
  const start = Date.UTC(y, 2, lastSunday(2), 1), end = Date.UTC(y, 9, lastSunday(9), 1), t = date.getTime() + 12 * 3600e3;
  return t >= start && t < end ? 2 : 1;
}
/** Altura del sol en grados para una hora oficial (minutos) y un punto. */
export function sunAltitude(date, minute, lon = -3.7, lat = 40.4) {
  const offset = dstOffset(date), utcMin = minute - offset * 60;
  const doy = (Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()) - Date.UTC(date.getUTCFullYear(), 0, 0)) / 864e5;
  const g = 2 * Math.PI / 365 * (doy - 1 + (utcMin / 60 - 12) / 24);
  const eq = 229.18 * (0.000075 + 0.001868 * Math.cos(g) - 0.032077 * Math.sin(g) - 0.014615 * Math.cos(2 * g) - 0.040849 * Math.sin(2 * g));
  const decl = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g) - 0.006758 * Math.cos(2 * g) + 0.000907 * Math.sin(2 * g) - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g);
  const solar = utcMin + eq + 4 * lon, ha = (solar / 4 - 180) * Math.PI / 180, phi = lat * Math.PI / 180;
  const cosZ = Math.sin(phi) * Math.sin(decl) + Math.cos(phi) * Math.cos(decl) * Math.cos(ha);
  return 90 - Math.acos(Math.max(-1, Math.min(1, cosZ))) * 180 / Math.PI;
}
const lightOf = alt => Math.max(0, Math.min(1, (alt + 7) / 13));
const timesCache = new Map();
/** Orto y ocaso (hora oficial) para la fecha y el punto indicados; se calcula una vez por día. */
export function sunTimes(date, lon = -3.7, lat = 40.4) {
  const key = date.toISOString().slice(0, 10) + lon + lat;
  if (timesCache.has(key)) return timesCache.get(key);
  let rise = null, set = null;
  for (let m = 240; m < 1440; m += 2) {
    const up = sunAltitude(date, m, lon, lat) > -0.83;
    if (up && rise === null) rise = m;
    if (!up && rise !== null && set === null) set = m;
  }
  const out = {rise, set};
  timesCache.set(key, out);
  return out;
}
export function daylight(s, minute, lon = -3.7, lat = 40.4) {
  const altitude = sunAltitude(dayDate(s), minute % 1440, lon, lat), light = lightOf(altitude);
  return {light, night: 1 - light, altitude, ...sunTimes(dayDate(s), lon, lat)};
}

/** Avance de una obra y su fase constructiva. */
export const STAGES = ['Estudio y permisos', 'Plataforma y estructuras', 'Montaje de vía', 'Electrificación y señalización', 'Pruebas y autorización'];
export function constructionStatus(s, p) {
  const progress = p.done ? 1 : E.clamp((s.month + (ensureOps(s).day - 1) / opDays(s.month) - p.started) / (p.due - p.started || 1), 0, .99);
  return {progress, stage: p.done ? 'En servicio' : STAGES[Math.min(4, Math.floor(progress * 5))], stageIndex: p.done ? 5 : Math.min(4, Math.floor(progress * 5))};
}
