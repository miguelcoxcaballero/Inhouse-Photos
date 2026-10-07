// Pruebas de reglas de Iberia Ferroviaria 2.0: solo AVE y Alvia, red con anchos y catenaria, obras,
// cambiadores, obras históricas, imprevistos, personajes con retrato y guardado. Uso: node test.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as E from './dist/engine.js';
import * as I from './dist/infra.js';
import * as O from './dist/operations.js';
import * as S from './dist/schedule.js';
import {MODEL, MODELS, ROUTES, PROJECTS, CITIES} from './dist/data.js';
import {CHARACTERS, CHAPTERS, DECISIONS, EVENTS} from './dist/story.js';
import {faceSVG, LOOKS, MOOD_LIST} from './dist/faces.js';
const ok = [];
const fresh = () => { const s = E.initialState(); s.started = true; return s; };
const decideAll = s => { for (let d; (d = E.pendingDecision(s));) { const i = d.choices.findIndex(c => s.cash >= -(c.effects?.cash || 0)); E.decide(s, d.id, Math.max(0, i)); } };
/** Avanza meses resolviendo decisiones con la primera opción que se pueda pagar. */
const months = (s, n) => { for (let k = 0; k < n; k++) { decideAll(s); assert(E.step(s), 'el mes avanza'); } decideAll(s); };

// 1. Solo AVE y Alvia: material, horario oficial y corredores.
{
  assert(MODELS.every(m => ['AVE', 'Alvia'].includes(m.family)), 'solo hay material AVE y Alvia');
  assert(MODELS.filter(m => m.family === 'AVE').every(m => m.gauge === 'uic' && m.power === 'electric'), 'los AVE son de ancho estándar fijo y eléctricos');
  assert(MODELS.filter(m => m.family === 'Alvia').every(m => m.gauge === 'variable'), 'los Alvia son de ancho variable');
  assert(MODELS.some(m => m.power === 'hybrid'), 'hay un Alvia híbrido para las vías sin catenaria');
  const codes = new Set(S.dayTrips('L').map(t => S.lineCode(t.line)));
  assert.deepEqual([...codes].sort(), ['AVE', 'Alvia'], 'el horario oficial solo trae AVE y Alvia');
  for (const k of ['L', 'S', 'D']) assert(S.dayTrips(k).length > 250, 'circulaciones del día ' + k);
  assert(ROUTES.every(r => ['av', 'alvia', 'new'].includes(r.kind)), 'corredores AVE, Alvia o por abrir');
  ok.push(`Solo AVE y Alvia: ${MODELS.length} modelos y ${S.dayTrips('L').length} circulaciones oficiales en laborable.`);
}
// 2. Estado inicial coherente.
{
  const s = fresh(), active = s.routes.filter(r => r.active);
  assert.equal(active.length, 8, 'ocho servicios al empezar');
  for (const r of active) assert(E.canRun(s, r, MODEL[s.fleet.find(f => f.id === r.fleet).model]), 'cada tren puede ir por su vía: ' + r.id);
  assert(s.fleet.every(f => E.available(s, f) >= 0), 'sin trenes asignados dos veces');
  assert(E.validateSave(JSON.parse(JSON.stringify(s))), 'la partida nueva se guarda y se carga');
  ok.push('Ocho servicios iniciales con su material compatible y partida válida.');
}
// 3. Lo que puede circular depende del ancho y la catenaria.
{
  const s = fresh(), soria = s.routes.find(r => r.id === 'madrid-soria'), o = E.routeOptions(s, soria);
  assert(!o.ave.ok && !o.alvia.ok && o.hybrid.ok, 'a Soria solo llega el Alvia híbrido');
  assert(o.alvia.faults.some(f => f.type === 'elec' && f.tramo === 'trb-sor'), 'falta catenaria entre Torralba y Soria');
  const s130 = s.fleet.find(f => f.model === 's130'), s730 = s.fleet.find(f => f.model === 's730');
  assert.throws(() => E.configureRoute(s, 'madrid-soria', s130.id, 2, 22), /catenaria/);
  assert.throws(() => E.configureRoute(s, 'madrid-soria', s.fleet.find(f => f.model === 's103').id, 2, 22), /AVE no puede/);
  E.configureRoute(s, 'madrid-soria', s730.id, 2, 22);
  assert.equal(E.product(s, soria), 'Alvia');
  const gij = E.routeOptions(s, s.routes.find(r => r.id === 'madrid-gijon'));
  assert(!gij.ave.ok && gij.alvia.ok && gij.alvia.changes.length >= 1, 'a Gijón, Alvia con cambio de ancho');
  assert(gij.ave.faults.every(f => f.type === 'gauge' || f.type === 'elec'), 'el AVE a Gijón choca con el ancho ibérico');
  ok.push('AVE solo por ancho estándar o mixto con catenaria; Alvia por cambiadores; híbrido sin catenaria.');
}
// 4. Obras: catenaria, tercer carril, ancho estándar (corta la línea) y cambiadores.
{
  const s = fresh(); s.cash = 3000;
  const q = E.workQuote(s, 'electrify', 'trb-sor');
  assert(q.cost > 0 && q.months > 0 && !q.closes, 'electrificar no corta la línea');
  E.startWork(s, 'electrify', 'trb-sor');
  assert.throws(() => E.startWork(s, 'electrify', 'trb-sor'), /máquinas|sentido/);
  assert.throws(() => E.workQuote(s, 'changer', 'cas'), /no pinta nada/);
  E.startWork(s, 'changer', 'vlc');
  E.startWork(s, 'mixed', 'cas-tar');
  const bad = s.routes.find(r => r.id === 'madrid-badajoz'), path = E.routeCheck(s, bad, MODEL.s730).tramos.map(t => t.id);
  const target = path.find(id => I.tramoWorks(s, id).some(w => w.work === 'standard'));
  const close = E.workQuote(s, 'standard', target);
  assert(close.closes && close.affected.some(r => r.id === 'madrid-badajoz'), 'el cambio de ancho corta los servicios que pasan');
  E.startWork(s, 'standard', target);
  assert(!bad.active && bad.cut, 'Madrid — Badajoz queda cortada mientras dura la obra');
  months(s, 48);
  assert.equal(s.infra.t['trb-sor'].e, '25kv', 'Torralba — Soria electrificada');
  assert(E.canRun(s, s.routes.find(r => r.id === 'madrid-soria'), MODEL.s130), 'el Alvia eléctrico ya llega a Soria');
  assert(s.infra.c.includes('vlc') && s.infra.done.changers === 1, 'cambiador de València en servicio');
  assert.equal(s.infra.t['cas-tar'].g, 'mixto');
  assert(E.routeOptions(s, s.routes.find(r => r.id === 'valencia-barcelona')).ave.ok, 'AVE València — Barcelona tras el tercer carril');
  assert.equal(s.infra.t[target].g, 'std');
  assert(!bad.cut, 'la relación se puede reabrir al acabar la obra');
  assert(s.infra.done.elec > 80 && s.infra.done.conv > 100, 'kilómetros de obra contabilizados');
  ok.push('Obras de catenaria, tercer carril, cambio de ancho con corte y cambiadores terminan y cambian lo que puede circular.');
}
// 5. Obras históricas de la red en su fecha real y proyectos de alta velocidad.
{
  const s = fresh();
  assert(!s.infra.c.includes('pol'), 'en 2022 aún no está la variante de Pajares');
  months(s, 24);
  assert(s.infra.c.includes('pol') && s.infra.c.includes('bur'), 'cambiadores de Pola de Lena y Burgos al abrir sus líneas');
  assert(s.log.some(l => /Pajares/.test(l.title)), 'la apertura de Pajares sale en el diario');
  s.cash = 1000; E.startProject(s, 'almeria');
  assert.throws(() => E.startProject(s, 'almeria'), /contratado/);
  const p = s.projects.find(p => p.id === 'almeria');
  assert(p.due >= (PROJECTS.find(x => x.id === 'almeria').earliest - 2022) * 12, 'nunca antes de su año');
  ok.push('Pajares (nov. 2023), Burgos y el resto de obras históricas llegan en su fecha; proyectos con plazo mínimo.');
}
// 6. Imprevistos y decisiones con personajes.
{
  const s = fresh(); months(s, 120);
  assert(s.events.length >= 12, 'al menos doce imprevistos en diez años: ' + s.events.length);
  assert(new Set(s.events.map(e => e.id)).size >= 9, 'imprevistos variados');
  assert(s.events.every(e => EVENTS.some(x => x.id === e.id)));
  assert(DECISIONS.filter(d => d.at < 120).every(d => s.decided.includes(d.id)), 'todas las decisiones del consejo resueltas');
  const people = new Set([...DECISIONS, ...EVENTS].map(d => d.person).concat(CHAPTERS.map(c => c.speaker)));
  for (const p of people) assert(CHARACTERS[p] && LOOKS[p], 'personaje con ficha y retrato: ' + p);
  for (const d of [...DECISIONS, ...EVENTS, ...CHAPTERS]) assert(!d.mood || MOOD_LIST.includes(d.mood), 'emoción válida en ' + (d.id || d.title));
  assert(Object.keys(CHARACTERS).length >= 9 && EVENTS.length >= 20, 'nueve personajes y veinte imprevistos como mínimo');
  ok.push(`${EVENTS.length} imprevistos y ${DECISIONS.length} decisiones; ${Object.keys(CHARACTERS).length} personajes, todos con retrato.`);
}
// 7. Retratos: una ilustración por personaje y tres emociones distintas.
{
  const all = new Set();
  for (const p of Object.keys(CHARACTERS)) for (const m of ['happy', 'angry', 'worried']) {
    const svg = faceSVG(p, m);
    assert(svg.startsWith('<svg') && svg.endsWith('</svg>') && !/NaN|undefined/.test(svg), `retrato válido ${p}/${m}`);
    all.add(svg.replace(/\b[a-z]f\d+\b|f\d+/g, ''));
  }
  assert.equal(all.size, Object.keys(CHARACTERS).length * 3, 'cada personaje y emoción tiene su propio dibujo');
  ok.push(`${all.size} retratos distintos (${Object.keys(CHARACTERS).length} personajes × 3 emociones).`);
}
// 8. Textos: sin avisos de ficción, sin enlaces externos, sin trenes que no sean AVE o Alvia.
{
  const text = ['dist/story.js', 'dist/app.js', 'dist/index.html', 'dist/data.js', 'dist/engine.js', 'dist/infra.js', 'dist/operations.js'].map(f => fs.readFileSync(f, 'utf8')).join('\n');
  assert(!/ficti|ficción|parodia|inventad[oa]s? por/i.test(text), 'sin avisos de ficción');
  assert(!/href="http|https?:\/\/(?!www\.w3\.org)/.test(text), 'sin enlaces a webs externas');
  assert(!/Cercanías|Rodalies|Media Distancia|Regional Exprés|Avant\b/.test(fs.readFileSync('dist/story.js', 'utf8')), 'el guion solo habla de AVE y Alvia');
  ok.push('Guion sin avisos de ficción ni enlaces; solo AVE y Alvia.');
}
// 9. Jornada: trenes simulados sobre la red real y servicios cortados fuera del plan.
{
  const s = fresh(); decideAll(s); O.ensureOps(s); s.ops.day = 3; s.cash = 2000;
  E.configureRoute(s, 'madrid-soria', s.fleet.find(f => f.model === 's730').id, 3, 22);
  O.startDay(s);
  const sim = O.servicePlan(s).filter(t => t.route === 'madrid-soria');
  assert.equal(sim.length, 6, 'tres salidas por sentido');
  assert(sim.every(t => t.coords.length > 20 && t.duration > 100), 'recorrido sobre las vías con su duración');
  const real = O.servicePlan(s).filter(t => t.real);
  assert(real.length > 30 && real.every(t => ['AVE', 'Alvia'].includes(t.family || S.lineCode(t.line))), 'circulaciones reales AVE y Alvia');
  ok.push(`Jornada con ${O.servicePlan(s).length} circulaciones: horario real y trenes simulados por la red.`);
}
// 10. Guardado: partidas antiguas y manipuladas se rechazan.
{
  const s = fresh();
  assert.throws(() => E.validateSave({...JSON.parse(JSON.stringify(s)), version: 2}), /versión anterior/);
  const bad = JSON.parse(JSON.stringify(s)); bad.routes.find(r => r.id === 'madrid-soria').active = true; bad.routes.find(r => r.id === 'madrid-soria').fleet = 'f3';
  assert.throws(() => E.validateSave(bad), /no puede circular|dos veces/);
  const t = JSON.parse(JSON.stringify(s)); t.infra.t['trb-sor'].g = 'tren-bala';
  assert.throws(() => E.validateSave(t), /vía no válido/);
  ok.push('Guardado: se rechazan partidas de versiones anteriores y estados imposibles.');
}
// 11. Cada botón suena y cada frase tiene su voz grabada.
{
  const {ACTIONS, RECIPES} = await import('./dist/sfx.js');
  const app = fs.readFileSync('dist/app.js', 'utf8');
  const actions = new Set([...app.matchAll(/data-action="([a-z-]+)"/g), ...app.matchAll(/case '([a-z-]+)':/g)].map(m => m[1]));
  for (const a of actions) {
    const spec = ACTIONS[a];
    assert(spec, 'efecto de sonido para ' + a);
    if (spec[0] === '=') assert(RECIPES[spec.slice(1)], 'receta ' + spec);
    else if (spec[0] === '!') assert(['!play', '!toggle'].includes(spec));
    else if (spec[0] !== '@') assert(RECIPES[spec], 'receta ' + spec);
  }
  const lines = JSON.parse(fs.readFileSync('../investigacion/voces/frases.json', 'utf8'));
  const {CLIPS} = await import('./dist/assets/voices.js');
  const missing = lines.filter(l => !CLIPS[l.id]);
  assert.deepEqual(missing.map(l => l.text), [], 'frases sin voz grabada');
  assert(new Set(lines.map(l => l.person)).size >= 9, 'los nueve personajes hablan');
  ok.push(`${actions.size} acciones con su efecto de sonido; ${lines.length} frases con voz grabada de ${new Set(lines.map(l => l.person)).size} personajes.`);
}
console.log(ok.map(x => '✓ ' + x).join('\n'));
