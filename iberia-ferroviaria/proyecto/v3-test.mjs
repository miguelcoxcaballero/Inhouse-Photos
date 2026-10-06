// Pruebas v0.3: horario oficial integrado, geometría, jornadas con circulaciones reales, sol y migración.
import assert from 'node:assert/strict';
import * as E from './dist/engine.js';
import * as O from './dist/operations.js';
import * as S from './dist/schedule.js';
import {ALL_ROUTES} from './dist/network.js';
import {MODEL, CITY} from './dist/data.js';
const ok = [];

// 1. Horario oficial: tres días tipo, Cercanías/Rodalies y AV/LD/MD.
{
  for (const k of ['L', 'S', 'D']) assert(S.dayTrips(k).length > 1000, 'faltan circulaciones ' + k);
  const L = S.dayTrips('L');
  const kinds = new Set(L.map(t => S.LINES[t.line].kind));
  for (const k of ['av', 'ld', 'md']) assert(kinds.has(k), 'falta ' + k);
  assert(!kinds.has('commuter'), 'sin Cercanías');
  for (const t of L) {
    for (let j = 1; j < t.times.length; j++) assert(t.times[j] >= t.times[j - 1], 'horas no crecientes ' + t.key);
    assert(t.start >= 180, 'los nocturnos se cierran al final del día');
    assert.equal(t.edges.length, t.stations.length - 1);
  }
  assert(L.some(t => S.LINES[t.line].code === 'AVE' && t.number), 'número de tren AVE');
  ok.push(`Horario oficial AV/LD/MD: ${L.length} circulaciones en laborable, sin Cercanías.`);
}
// 2. Geometría de tramos sobre la península y posiciones interpoladas.
{
  let approx = 0, total = 0;
  for (let i = 0; i < S.EDGE_COUNT; i++) {
    const e = S.edge(i);
    total += e.km; if (e.approx === 1) approx += e.km;
    for (const [lon, lat] of e.pts) assert(lon > -10 && lon < 6.5 && lat > 35.5 && lat < 46, 'punto fuera de rango ' + i);
  }
  assert(approx / total < .06, 'demasiado trazado aproximado');
  const t = S.dayTrips('L').find(t => S.LINES[t.line].code === 'AVE' && t.stations.length > 2);
  const mid = (t.times[1] + t.times[2]) / 2, p = S.position(t, mid);
  assert(p && !p.stopped && Number.isFinite(p.angle));
  assert.equal(S.position(t, t.start - 5), null);
  assert(S.position(t, t.times[2] + .1)?.stopped || S.position(t, t.times[2])?.stopped);
  ok.push(`Trazados: ${Math.round(total)} km de tramos, ${(approx / total * 100).toFixed(1)} % aproximado; posición sobre la vía con paradas.`);
}
// 3. Días tipo y festivos.
{
  assert.equal(S.dayType(new Date('2026-10-14T00:00:00Z')), 'L');
  assert.equal(S.dayType(new Date('2026-10-17T00:00:00Z')), 'S');
  assert.equal(S.dayType(new Date('2026-10-18T00:00:00Z')), 'D');
  assert.equal(S.dayType(new Date('2026-10-12T00:00:00Z')), 'D');
  ok.push('Laborable, sábado, domingo y festivos nacionales.');
}
// 4. Jornada con trenes reales: primera salida, última llegada, oferta parcial y unidades por pico.
{
  const s = E.initialState(); s.started = true; E.decide(s, 'inaugural', 0); O.ensureOps(s);
  s.month = 9; s.ops.day = 14; // 14 de octubre de 2022, viernes
  for (let d; (d = E.pendingDecision(s));) E.decide(s, d.id, d.choices.findIndex(c => s.cash >= -(c.effects.cash || 0)));
  const r = s.routes.find(r => r.id === 'madrid-barcelona');
  assert(r.real && r.baseFrequency > 20);
  const plan = O.servicePlan(s), mine = plan.filter(t => t.route === r.id);
  assert(Math.abs(mine.length - Math.round(S.routeTrips('L', r.id).length * r.frequency / r.baseFrequency)) <= 1, 'oferta parcial ' + mine.length);
  assert(mine.every(t => t.real && t.trip && t.number));
  const b = O.dayBounds(plan);
  assert.equal(b.first, Math.min(...plan.map(t => t.dep)));
  O.startDay(s);
  assert.equal(s.ops.minute, b.first);
  assert(b.last > 1260 && b.last === Math.max(...plan.map(t => t.arrival)), 'la jornada termina con la última llegada');
  assert.equal(E.requiredUnits(r, MODEL.s112, r.baseFrequency), Math.ceil(r.peak * 1.12));
  assert.throws(() => E.configureRoute(s, r.id, r.fleet, r.baseFrequency + 1, 40), /salidas/);
  E.configureRoute(s, r.id, r.fleet, r.frequency - 1, r.fare); // se puede ajustar durante la jornada
  while (!O.moveClock(s, 45)) {}
  const report = O.endDay(s);
  assert(report.trains === plan.length - 2 && report.km > 1000);
  O.nextDay(s);
  assert.equal(s.ops.day, 15);
  ok.push(`Jornada real (con refuerzo en directo): ${plan.length} circulaciones de ${O.clockText(b.first)} a ${O.clockText(b.last)}, parte del día y unidades por pico simultáneo.`);
}
// 5. Incidencias con respuesta y demoras propagadas.
{
  const s = E.initialState(); s.started = true; E.decide(s, 'inaugural', 0); O.ensureOps(s);
  let tries = 0;
  do { s.seed = 1000 + tries++; s.ops.phase = 'planning'; O.startDay(s); } while (!s.ops.incidents.length && tries < 50);
  const x = s.ops.incidents[0];
  assert(x, 'debe generarse alguna incidencia');
  const before = O.servicePlan(s).filter(t => t.route === x.route).reduce((v, t) => v + t.delay, 0);
  s.ops.minute = x.at;
  const cash = s.cash;
  O.resolveIncident(s, x.trip, 'team');
  assert(s.cash < cash);
  const after = O.servicePlan(s).filter(t => t.route === x.route).reduce((v, t) => v + t.delay, 0);
  assert(after < before, 'el equipo reduce la demora');
  assert.throws(() => O.resolveIncident(s, x.trip, 'bus'));
  ok.push('Incidencias: respuesta con coste, demora reducida y sin doble resolución.');
}
// 6. Sol: altura, orto y ocaso en Madrid; noche más larga en invierno.
{
  const june = new Date('2026-06-21T00:00:00Z'), dec = new Date('2026-12-21T00:00:00Z');
  assert(O.sunAltitude(june, 14 * 60 + 15) > 70);
  assert(O.sunAltitude(june, 60) < -10);
  const tj = O.sunTimes(june), td = O.sunTimes(dec);
  assert(Math.abs(tj.rise - (6 * 60 + 45)) < 12, 'orto en junio ' + O.clockText(tj.rise));
  assert(Math.abs(td.set - (17 * 60 + 52)) < 12, 'ocaso en diciembre ' + O.clockText(td.set));
  assert(O.sunAltitude(june, 21 * 60 + 30, -8.7) > O.sunAltitude(june, 21 * 60 + 30, 3.2), 'el ocaso avanza de este a oeste');
  ok.push(`Sol: orto ${O.clockText(tj.rise)} en junio, ocaso ${O.clockText(td.set)} en diciembre (Madrid); gradiente este-oeste.`);
}
// 7. Migración de una partida v0.2.
{
  const s = E.initialState(); s.started = true; E.decide(s, 'inaugural', 0);
  const legacy = JSON.parse(JSON.stringify(s));
  legacy.version = 1;
  legacy.routes = legacy.routes.filter(r => !r.generated);
  legacy.routes.push({...legacy.routes[0], id: 'c-madrid-c5', active: false}); // línea de Cercanías de una partida antigua
  for (const r of legacy.routes) { delete r.real; delete r.baseFrequency; delete r.peak; }
  const back = E.validateSave(legacy);
  assert.equal(back.version, 2);
  assert.equal(back.routes.length, ALL_ROUTES.length);
  assert(back.routes.every(r => r.ends.every(id => CITY[id])));
  ok.push(`Partidas v0.2 migradas: ${ALL_ROUTES.length} relaciones jugables.`);
}
console.log(ok.map(x => '✓ ' + x).join('\n'));

// 8. Ciudades: estaciones y peticiones.
{
  const s = E.initialState(); s.started = true; E.decide(s, 'inaugural', 0);
  assert(s.requests.length >= 1);
  const cash = s.cash, cost = E.stationCost(s, 'mad');
  E.upgradeStation(s, 'mad');
  assert.equal(s.stations.mad, 1); assert(Math.abs(s.cash - (cash - cost)) < 1e-9);
  const q = s.requests[0], r = s.routes.find(r => r.id === q.route);
  if (q.type === 'open') { const f = s.fleet.find(f => E.compatible(r, MODEL[f.model]) && E.available(s, f) >= E.requiredUnits(r, MODEL[f.model], 1)); E.configureRoute(s, r.id, f.id, 1, r.fare); }
  else if (q.type === 'station') { while ((s.stations[q.city] || 0) < q.target) E.upgradeStation(s, q.city); }
  else if (q.type === 'fare') E.configureRoute(s, r.id, r.fleet, r.frequency, q.target);
  else { const f = s.fleet.find(f => f.id === r.fleet); E.configureRoute(s, r.id, f.id, q.target, r.fare); }
  const before = s.cash; E.checkRequests(s);
  assert.equal(s.stats.requests, 1); assert(s.cash > before);
  assert.equal(E.validateSave(JSON.parse(JSON.stringify(s))).stations.mad, 1);
  ok.push('Ciudades: mejora de estación y petición atendida con recompensa.');
}
console.log(ok.slice(-1).map(x => '✓ ' + x).join('\n'));
// 9. Banda sonora: al menos diez piezas completas en ambos estilos.
{
  const {SONGS, validate, arrange} = await import('./dist/music.js');
  assert(SONGS.length >= 10);
  assert(new Set(SONGS.map(s => s.family)).size === 2);
  for (const s of SONGS) {
    validate(s);
    const {events, length} = arrange(s);
    assert(events.length > 300 && length > 80, s.title);
    assert(events.every(e => e.t >= -0.05 && e.t < length && Number.isFinite(e.midi) && e.vel > 0 && e.vel <= 1), s.title);
  }
  console.log(`✓ Banda sonora: ${SONGS.length} piezas originales (${SONGS.filter(s => s.family === 'estacion').length} «Estación», ${SONGS.filter(s => s.family === 'red').length} «Red»), compases y eventos válidos.`);
}

// 10. Voces y diálogos: cada personaje tiene voz, y todo el texto hablado es pronunciable.
{
  const {CAST, speechText, sentences} = await import('./dist/voice.js');
  const {CHARACTERS, CHAPTERS, DECISIONS} = await import('./dist/story.js');
  assert.deepEqual(Object.keys(CAST).sort(), Object.keys(CHARACTERS).sort());
  assert.equal(speechText('Cuesta 4 M€ a 10× ❗ «hoy»'), 'Cuesta 4 millones de euros a 10 por hoy');
  assert.deepEqual(sentences('Hola. ¿Qué tal? ¡Bien!'), ['Hola.', '¿Qué tal?', '¡Bien!']);
  const lines = [...CHAPTERS.map(c => [c.speaker, c.text]), ...DECISIONS.map(d => [d.person, d.body])];
  for (const [who, text] of lines) {
    assert(CAST[who], who);
    const parts = sentences(text).map(speechText);
    assert(parts.length >= 2 && parts.every(p => p.length > 1 && !/[€×«»❗<>]/.test(p)), text);
  }
  assert(!/Cercan[ií]as y Rodalies a la Alta/.test(await (await import('node:fs')).promises.readFile(new URL('./dist/app.js', import.meta.url), 'utf8')));
  console.log(`✓ Voces: ${Object.keys(CAST).length} personajes con voz propia y ${lines.length} diálogos pronunciables frase a frase.`);
}
