// Campaña completa 2022–2050 jugada solo con acciones legales del motor: decisiones, servicios, compras,
// reformas, peticiones, obras de ancho y catenaria, cambiadores y líneas nuevas. Comprueba que los cinco
// capítulos se pueden superar con la red real y que la partida termina en 2050 sin quiebra.
// Uso: node campaign-test.mjs [--verbose]
import assert from 'node:assert/strict';
import * as E from './dist/engine.js';
import * as I from './dist/infra.js';
import {MODEL, MODELS, PROJECTS, CITIES} from './dist/data.js';
import {CHAPTERS} from './dist/story.js';

const verbose = process.argv.includes('--verbose'), trace = process.argv.includes('--trace');
const s = E.initialState(); s.started = true;
const say = (...x) => { if (verbose) console.log(E.dateOf(s.month), '·', ...x); };
const tryDo = (fn) => { try { fn(); return true; } catch { return false; } };
const reserve = () => 60 + s.month * .25;
const free = (fam) => s.fleet.filter(f => MODEL[f.model].family === fam && f.condition >= 30).reduce((n, f) => n + Math.max(0, E.available(s, f)), 0);
const coming = (fam) => s.orders.filter(o => !o.historical && MODEL[o.model].family === fam).reduce((n, o) => n + o.qty - o.delivered, 0);

function decideAll() {
  for (let d; (d = E.pendingDecision(s));) {
    let ix = d.choices.findIndex(c => s.cash - reserve() >= -(c.effects?.cash || 0));
    if (ix < 0) ix = d.choices.findIndex(c => s.cash >= -(c.effects?.cash || 0));
    if (ix < 0) { E.loan(s, 100); continue; }
    E.decide(s, d.id, ix);
  }
}
/** Lote con trenes libres que puede ir por la relación, del producto pedido. */
function lotFor(r, fam, freq) {
  const lots = s.fleet.filter(f => MODEL[f.model].family === fam && f.condition >= 30 && E.canRun(s, r, MODEL[f.model]));
  lots.sort((a, b) => E.available(s, b, r.id) - E.available(s, a, r.id));
  return lots.find(f => E.available(s, f, r.id) >= E.requiredUnits(s, r, MODEL[f.model], freq));
}
function openRoute(r, freq) {
  if (r.active || r.cut || !E.isUnlocked(s, r) || s.cash < 4 + reserve() / 3) return false;
  const o = E.routeOptions(s, r);
  freq ??= r.real ? Math.max(1, Math.round(r.baseFrequency * .5)) : 4;
  freq = Math.min(freq, E.maxFrequency(r));
  for (const fam of o.ave.ok ? ['AVE', 'Alvia'] : ['Alvia']) {
    for (let f = freq; f >= 1; f--) {
      const lot = lotFor(r, fam, f);
      if (lot && tryDo(() => E.configureRoute(s, r.id, lot.id, f, r.fare))) { say('abre', E.routeName(r), fam, f); return true; }
    }
  }
  return false;
}
/** Pasa a AVE una relación servida con Alvia cuando la vía ya lo permite. */
function promoteToAve(r) {
  if (!r.active || E.product(s, r) === 'AVE' || !E.routeOptions(s, r).ave.ok) return false;
  const lot = lotFor(r, 'AVE', r.frequency);
  return !!lot && tryDo(() => E.configureRoute(s, r.id, lot.id, r.frequency, r.fare));
}
function addTrains(r, target) {
  const f = s.fleet.find(f => f.id === r.fleet);
  if (!f) return false;
  for (let k = Math.min(target, E.maxFrequency(r)); k > r.frequency; k--)
    if (tryDo(() => E.configureRoute(s, r.id, f.id, k, r.fare))) return true;
  return false;
}
function handleRequests() {
  for (const q of [...s.requests]) {
    const r = s.routes.find(r => r.id === q.route);
    if (q.type === 'open') openRoute(r);
    else if (q.type === 'more') addTrains(r, q.target);
    else if (q.type === 'fare' && r.active) tryDo(() => E.configureRoute(s, r.id, r.fleet, r.frequency, q.target));
    else if (q.type === 'station' && s.cash - E.stationCost(s, q.city) > reserve()) tryDo(() => E.upgradeStation(s, q.city));
    else if (q.type === 'ave') promoteToAve(r);
  }
}
function buyTrains() {
  const year = E.yearOf(s);
  const best = fam => MODELS.filter(m => m.family === fam && m.year <= year && m.power === 'electric').sort((a, b) => b.seats / b.price - a.seats / a.price)[0];
  for (const fam of ['AVE', 'Alvia']) {
    const want = fam === 'AVE' ? 10 : 5;
    if (free(fam) + coming(fam) >= want) continue;
    const m = best(fam), q = E.purchaseQuote(s, m.id, 8);
    if (s.cash - q.deposit > reserve() + 40) { E.buy(s, m.id, 8); say('compra 8 ×', m.name); }
  }
}
/** Obras que acercan el AVE a más ciudades: tercer carril y catenaria en los tramos que lo impiden. */
function aveWorks(limit) {
  const wanted = new Map();
  for (const r of s.routes) {
    if (r.cut) continue;
    const ave = E.routeOptions(s, r).ave;
    if (ave.ok || !ave.faults.length) continue;
    const todo = [];
    for (const f of ave.faults) {
      if (!f.tramo || f.type === 'build' || f.type === 'closed') { todo.length = 0; break; }
      const kind = f.type === 'gauge' ? 'mixed' : f.type === 'elec' ? 'electrify' : null;
      if (!kind) { todo.length = 0; break; }
      todo.push([kind, f.tramo]);
    }
    if (!todo.length) continue;
    const cost = todo.reduce((n, [k, t]) => n + (I.tramoWorks(s, t).find(w => w.work === k)?.cost ?? 999), 0);
    const value = r.demand / Math.max(1, cost);
    for (const [k, t] of todo) { const key = k + '|' + t; wanted.set(key, Math.max(wanted.get(key) || 0, value)); }
  }
  let started = 0;
  for (const [key] of [...wanted].sort((a, b) => b[1] - a[1])) {
    if (started >= limit) break;
    const [kind, tramo] = key.split('|');
    const q = tryDo(() => E.workQuote(s, kind, tramo)) && E.workQuote(s, kind, tramo);
    if (q && s.cash - q.cost > reserve() + 30 && tryDo(() => E.startWork(s, kind, tramo))) { started++; say('obra', kind, tramo, q.cost, 'M€'); }
  }
}
/** Catenaria donde todavía se va con gasóleo (capítulo 4). */
function electrifyMore(limit) {
  const list = I.allTramos(s).filter(d => s.infra.t[d.id]?.b && I.tramoWorks(s, d.id).some(w => w.work === 'electrify' && !w.busy));
  list.sort((a, b) => b.km - a.km);
  let n = 0;
  for (const d of list) {
    if (n >= limit) break;
    const q = E.workQuote(s, 'electrify', d.id);
    if (s.cash - q.cost > reserve() + 30 && tryDo(() => E.startWork(s, 'electrify', d.id))) { n++; say('electrifica', d.name); }
  }
}
function startProjects() {
  for (const p of [...PROJECTS].sort((a, b) => a.earliest - b.earliest)) {
    if (s.projects.some(x => x.id === p.id)) continue;
    if (E.yearOf(s) < p.earliest - Math.ceil(p.duration / 12)) continue;
    if (s.cash - p.cost > reserve() + 50 && tryDo(() => E.startProject(s, p.id))) say('proyecto', p.name);
  }
}
/** Relaciones nuevas hacia ciudades que el AVE ya puede alcanzar pero que no son extremo de ninguna. */
function newServices() {
  const ends = new Set(s.routes.flatMap(r => r.ends));
  for (const c of CITIES) {
    if (ends.has(c.id) || s.routes.filter(r => r.custom).length >= 30) continue;
    const id = tryDo(() => E.createService(s, 'mad', c.id)) ? s.routes.at(-1).id : null;
    if (id) { const r = s.routes.find(r => r.id === id); if (!E.routeOptions(s, r).ave.ok) { /* queda en estudio */ } say('estudia', E.routeName(r)); }
  }
}

const reached = {};
for (let guard = 0; guard < 400 && !s.ended; guard++) {
  decideAll();
  if (E.chapterReady(s)) { reached[CHAPTERS[s.chapter].id] = E.dateOf(s.month); E.claimChapter(s); say('capítulo superado'); decideAll(); }
  const ch = CHAPTERS[s.chapter].id;
  if (s.month === 0) { const old = s.fleet.find(f => f.model === 's100'); E.refurbish(s, old.id, 2); }
  handleRequests();
  buyTrains();
  for (const r of s.routes) promoteToAve(r);
  let opened = 0;
  for (const r of [...s.routes].sort((a, b) => b.demand - a.demand)) if (opened < 3 && openRoute(r)) opened++;
  // más trenes donde van llenos
  for (const r of s.routes.filter(r => r.active)) { const m = E.metrics(s, r); if (m.occupancy > .9 && m.net > 0) addTrains(r, r.frequency + 1); }
  if (E.yearOf(s) >= 2024 && s.infra.done.changers < 1 && !s.projects.some(p => p.type === 'changer')) tryDo(() => E.startWork(s, 'changer', 'vlc'));
  if (E.yearOf(s) >= 2024) aveWorks(ch === 'competition' ? 1 : 3);
  if (E.yearOf(s) >= 2025) startProjects();
  if (E.yearOf(s) >= 2033) electrifyMore(2);
  if (E.yearOf(s) >= 2030 && s.month % 6 === 0) newServices();
  if (ch === 'legacy' && s.debt >= 100 && s.cash > s.debt + 200) tryDo(() => E.loan(s, -100));
  if (trace && s.month % 12 === 0) { const b = E.balance(s); console.log(E.yearOf(s), 'caja', Math.round(s.cash), 'deuda', s.debt, 'neto/mes', b.net.toFixed(1), 'ingresos', b.revenue.toFixed(1), 'costes', b.cost.toFixed(1), 'ayudas', b.subsidy.toFixed(1), 'servicios', s.routes.filter(r => r.active).length, 'trenes/día', E.dailyTrains(s), 'AVE en', E.aveCities(s).size, 'satisf.', Math.round(s.satisfaction), 'flota', s.fleet.reduce((n, f) => n + f.qty, 0)); }
  if (!E.step(s)) { decideAll(); assert(E.step(s), 'la campaña no avanza en ' + E.dateOf(s.month)); }
}
decideAll();
if (E.chapterReady(s)) reached[CHAPTERS[s.chapter].id] = 'final';

const summary = {final: s.ending, month: s.month, cash: Math.round(s.cash), debt: s.debt, score: E.finalScore(s), chapters: reached,
  active: s.routes.filter(r => r.active).length, trains: E.dailyTrains(s), aveCities: E.aveCities(s).size, satisfaction: Math.round(s.satisfaction),
  electrified: Math.round(s.infra.done.elec), converted: Math.round(s.infra.done.conv), changers: s.infra.done.changers, projects: s.projects.filter(p => p.type === 'infrastructure' && p.done).length};
console.log(JSON.stringify(summary, null, 1));
assert.equal(s.ended, true, 'la campaña llega al final');
assert.equal(s.ending, '2050', 'termina en 2050, no en quiebra');
assert.equal(s.claimed.length, 5, 'los cinco capítulos se pueden superar: ' + JSON.stringify(reached));
assert(E.validateSave(JSON.parse(JSON.stringify(s))), 'la partida final se puede guardar y cargar');
console.log('✓ Campaña completa 2022–2050 con acciones legales: 5 capítulos, obras de ancho y catenaria, cambiadores y AVE en', summary.aveCities, 'ciudades.');
