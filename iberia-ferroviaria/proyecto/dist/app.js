// Iberia Ferroviaria v0.3 — interfaz. Mapa a pantalla completa, jornada por turnos y paneles planos.
import {CITIES, CITY, MODELS, MODEL, PROJECTS, HISTORICAL_ORDERS, SOURCES, GAUGES, POWERS} from './data.js';
import {CHAPTERS, CHARACTERS} from './story.js';
import * as E from './engine.js';
import * as O from './operations.js';
import * as G from './gtfs.js';
import * as S from './schedule.js';
import {kindLabel, networkName} from './network.js';
import {RailMap} from './map-v3.js';
import {trainArt, artKey} from './train-art.js';
import {citySkyline} from './city-art.js';
import {trainThumb, mountViewers} from './train3d.js';
import {Voices, sentences, CAST} from './voice.js';
import {Soundtrack, SONGS, STYLE_LABEL, FAMILY_LABEL} from './music.js';
import {Sfx, ACTIONS} from './sfx.js';
import {REAL_TRAIN_CATALOGUE, COMMUTER_NETWORKS} from './assets/realdata.js';

const $ = id => document.getElementById(id);
const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const n = (x, d = 0) => Number(x || 0).toLocaleString('es-ES', {maximumFractionDigits: d, minimumFractionDigits: d});
const money = x => n(x, Math.abs(x) < 10 ? 2 : 1) + ' M€', signed = x => (x >= 0 ? '+' : '') + money(x);
const clock = O.clockText;
const KEY = 'iberia-ferroviaria-v1';
const SPEEDS = [[2, '1×'], [6, '3×'], [20, '10×'], [60, '30×']];
const KIND_COLOR = {av: '#a3123a', intercity: '#2f6f9f', regional: '#c27a18', commuter: '#55803a', md: '#c27a18', ld: '#2f6f9f'};
const ICONS = {
  ops: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.5 2"/>',
  network: '<path d="M4 18c4-1 4-11 8-12s4 9 8 8"/><circle cx="4" cy="18" r="1.6"/><circle cx="20" cy="14" r="1.6"/><circle cx="12" cy="6" r="1.6"/>',
  timetables: '<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M4 9h16M9 9v11M13 13h4M13 16.5h4"/>',
  fleet: '<path d="M5 15V8a3 3 0 0 1 3-3h8a3 3 0 0 1 3 3v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2zM5 11h14M8 20l1.5-3M16 20l-1.5-3"/><circle cx="8.5" cy="14" r=".8"/><circle cx="15.5" cy="14" r=".8"/>',
  market: '<path d="M4 7h16l-1.5 9.5a2 2 0 0 1-2 1.5h-9a2 2 0 0 1-2-1.5zM9 7V5.5a3 3 0 0 1 6 0V7"/>',
  works: '<path d="M4 20h16M6 20V9l6-4 6 4v11M10 20v-5h4v5"/><path d="M15 4l4 2"/>',
  finance: '<path d="M4 19h16M7 16V10M12 16V6M17 16v-4"/>',
  story: '<path d="M5 4h10l4 4v12H5zM15 4v4h4M8 12h8M8 15.5h6"/>',
  archive: '<rect x="4" y="5" width="16" height="4" rx="1"/><path d="M5.5 9v10h13V9M10 12.5h4"/>',
  music: '<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>',
  save: '<path d="M5 5h11l3 3v11H5zM8 5v5h7V5M8 19v-5h8v5"/>',
  help: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.5a2.5 2.5 0 1 1 3.6 2.3c-.8.4-1.2 1-1.2 1.9M12 16.6v.4"/>',
};
const PAGES = {ops: 'Jornada', network: 'Red', timetables: 'Horarios', fleet: 'Flota', market: 'Compras', works: 'Obras', finance: 'Finanzas', story: 'Historia', archive: 'Archivo'};

let state = E.initialState(), saved = null, screen = null, inspect = null, playing = false, speedIndex = 1, layer = 'network';
let lastTick = 0, lastPanel = 0, lastTimeline = 0, observerMinute = 480, seenIncidents = new Set(), alertTimer = null, toastTimer = null;
let ui = {routeTab: 'all', routeStatus: 'all', routeQuery: '', ttType: null, ttStation: '', ttLine: '', ttHour: 6, fleetTab: 'fleet', marketTab: 'catalogue', archiveTab: 'sources', trainQuery: '', autoPause: true};
let referenceFeed = null, referenceDate = '', referenceQuery = '';
O.ensureOps(state);
try { const raw = localStorage.getItem(KEY); if (raw) saved = E.validateSave(JSON.parse(raw)); } catch { saved = null; }

// ------------------------------------------------------------ vista para el mapa
let realCache = {type: null, trips: null};
function realTrips(type) {
  if (realCache.type === type) return realCache.trips;
  realCache = {type, trips: S.dayTrips(type).map(t => ({id: t.key, trip: t, dep: t.start, arrival: t.end, delay: 0, line: t.line, bus: t.bus, route: t.route,
    label: (t.bus ? 'Bus ' : '') + S.lineCode(t.line) + (t.number ? ' ' + t.number : ''), name: S.STATIONS[t.stations[0]].name + ' → ' + S.STATIONS[t.stations.at(-1)].name}))};
  return realCache.trips;
}
const dayType = () => O.dayKind(state);
function plan() { return O.servicePlan(state); }
function currentMinute() {
  const op = state.ops;
  if (op.phase === 'running') return op.minute;
  if (layer === 'real') return observerMinute;
  const b = O.dayBounds(plan());
  return op.phase === 'review' ? (op.last?.last ?? b.last) : b.first;
}
function viewTrips() {
  if (layer === 'real') return realTrips(dayType());
  return state.ops.phase === 'running' ? plan() : [];
}
function networkKey() { return state.routes.filter(r => r.active).map(r => r.id + r.frequency).join('|') + '#' + layer; }
let netKey = networkKey();
const map = new RailMap($('map'), {
  getState: () => state,
  getView: () => ({mode: layer === 'real' ? 'real' : 'campaign', trips: viewTrips(), minute: currentMinute(), date: O.dayDate(state), dayType: dayType(), networkKey: netKey}),
  onPick: hit => pick(hit),
  getCities: () => mapCities(),
  getPopups: () => popups,
});

// ------------------------------------------------------------ banda sonora
function musicMood() {
  if (!state.started || state.ops.phase !== 'running') return 'estacion';
  return O.daylight(state, state.ops.minute).night > .55 ? 'night' : 'day';
}
const music = new Soundtrack(musicMood);
const voices = new Voices(music);
const sfx = new Sfx(music);
// ------------------------------------------------------------ voces de los personajes
/** Texto con cada frase en su propio span, para el subtítulo resaltado mientras se lee. */
function sayHtml(text) { return sentences(text).map(x => `<span class="say-s">${esc(x)}</span>`).join(' '); }
function sayButton(person, where) { return `<button class="say-btn" data-action="say" data-person="${person}" data-where="${where}" aria-label="Escuchar a ${esc(CHARACTERS[person]?.name || '')}" title="Escuchar">${voices.speaking?.where === where ? '■' : '🔊'}</button>`; }
/** Lee el párrafo [data-say] dentro de root con la voz del personaje y resalta cada frase. */
function speakIn(root, person, where) {
  const el = root?.querySelector('[data-say]'); if (!el) return;
  const spans = [...el.querySelectorAll('.say-s')], face = root.querySelector('.portrait');
  const clear = () => { spans.forEach(x => x.classList.remove('on')); face?.classList.remove('talking'); root.querySelectorAll('.say-btn').forEach(b => b.textContent = '🔊'); };
  const ok = voices.speak(person, el.dataset.say, {onSentence: i => { spans.forEach((x, j) => x.classList.toggle('on', j === i)); }, onend: clear});
  if (!ok) return;
  if (voices.speaking) voices.speaking.where = where;
  face?.classList.add('talking'); root.querySelectorAll('.say-btn').forEach(b => b.textContent = '■');
}
function renderMusicButton() {
  const b = $('musicBtn'); if (!b) return;
  b.innerHTML = `${icon('music')}<span>${music.enabled ? 'Música' : 'Silencio'}</span>`;
  b.title = music.current ? `Sonando: ${music.current.song.title}` : music.enabled ? 'Banda sonora' : 'Música apagada';
  b.classList.toggle('on', !!music.current);
  if ($('modal').open && $('modal').querySelector('.tracks')) musicDialog(true);
}
music.on(renderMusicButton);
document.addEventListener('pointerdown', () => { if (music.enabled && !music.current) music.start(); }, {once: true});
['pointerdown', 'keydown', 'click'].forEach(type => document.addEventListener(type, () => sfx.arm(), {once: true, capture: true}));
let lastMood = null;
function checkMusicMood() {
  if (!music.current || music.mode !== 'auto') return;
  const mood = musicMood(), fam = mood === 'estacion' ? 'estacion' : 'red';
  if (music.current.song.family !== fam) music.next();
  else if (mood !== lastMood && fam === 'red' && (mood === 'night') !== (music.current.song.mood === 'night') && music.position > 25) music.next();
  lastMood = mood;
}
function musicDialog(refresh = false) {
  const cur = music.current?.song.id;
  const list = fam => SONGS.filter(x => x.family === fam).map(x => `<button class="track ${x.id === cur ? 'on' : ''}" data-action="music-play" data-id="${x.id}"><span class="no">${String(SONGS.indexOf(x) + 1).padStart(2, '0')}</span><span><b>${esc(x.title)}</b><em>${STYLE_LABEL[x.style]} · ${x.bpm} ppm${x.mood === 'night' ? ' · noche' : ''}</em></span><span class="eq">${x.id === cur ? '<i></i><i></i><i></i>' : '▶'}</span></button>`).join('');
  const html = `<div class="content"><div class="kicker">Banda sonora original</div><h1>Música de Iberia Ferroviaria</h1><p>Catorce piezas compuestas para el juego (orquesta, jazz, bossa, rumba, una bulería y un pasodoble) y tocadas en directo por tu navegador con instrumentos reales muestreados. En modo automático suenan las de «Estación» mientras preparas el día y las de «Red» durante la jornada; de noche, las nocturnas.</p>
  <div class="tracks"><h3>${FAMILY_LABEL.estacion}</h3>${list('estacion')}<h3>${FAMILY_LABEL.red}</h3>${list('red')}</div>
  <div class="toolbar"><button class="btn ${music.enabled ? '' : 'primary'}" data-action="music-toggle">${music.enabled ? 'Apagar música' : 'Encender música'}</button><button class="btn" data-action="music-next" ${music.enabled ? '' : 'disabled'}>Siguiente pieza</button>
  <label style="margin:0">Modo</label><select id="musicMode"><option value="auto" ${music.mode === 'auto' ? 'selected' : ''}>Automático según el momento</option><option value="list" ${music.mode === 'list' ? 'selected' : ''}>Toda la lista</option><option value="repeat" ${music.mode === 'repeat' ? 'selected' : ''}>Repetir pieza</option></select></div>
  <label for="musicVolume">Volumen</label><input id="musicVolume" type="range" min="0" max="1" step="0.05" value="${music.volume}">
  <h3 class="sub">Voces de los personajes</h3><p class="small">${voices.neural ? `Voces pregrabadas con XTTS-v2 a partir de grabaciones reales de España, con dirección de voz para cada remate. Pedro Sancho: ${CAST.president.label}; Raquel Sanz: ${CAST.minister.label}; Óscar del Puente: ${CAST.successor.label}.` : voices.available ? `Leídas con las voces en español de tu sistema (${esc(voices.voices.slice(0, 3).map(v => v.name).join(', '))}${voices.voices.length > 3 ? '…' : ''}). Pedro Sancho: ${CAST.president.label}; Raquel Sanz: ${CAST.minister.label}; Óscar del Puente: ${CAST.successor.label}.` : 'Tu navegador no ofrece voces en español. En Chrome, Edge o Safari, o instalando una voz española en el sistema, los personajes hablarán.'}</p>
  <div class="toolbar"><button class="btn ${voices.enabled ? '' : 'primary'}" data-action="voice-toggle">${voices.enabled ? 'Silenciar personajes' : 'Activar voces'}</button></div>
  <h3 class="sub">Efectos de sonido</h3><p class="small">Cada botón, cada clic del mapa y cada control tiene su sonido: madera, papel, campanas de estación y vibráfono, afinados entre sí. Se oyen aunque la música esté apagada.</p>
  <div class="toolbar"><button class="btn ${sfx.enabled ? '' : 'primary'}" data-action="sfx-toggle">${sfx.enabled ? 'Silenciar efectos' : 'Activar efectos'}</button></div>
  <label for="sfxVolume">Volumen de los efectos</label><input id="sfxVolume" type="range" min="0" max="1" step="0.05" value="${sfx.volume}">
  <div class="actions"><button class="btn primary" data-action="close-modal">Cerrar</button></div></div>`;
  if (refresh) { const sc = $('modal').querySelector('.content')?.scrollTop || 0; $('modal').innerHTML = `<div class="modal single">${html}</div>`; $('modal').querySelector('.content').scrollTop = sc; }
  else showModal(html, 'single');
}

// ------------------------------------------------------------ utilidades de UI
function toast(text) { $('toast').textContent = text; $('toast').classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').classList.remove('show'), 4200); }
function autosave(announce = false) {
  try { localStorage.setItem(KEY, JSON.stringify(state)); saved = state; if (announce) toast('Partida guardada en este navegador.'); return true; }
  catch { if (announce) toast('El navegador no permite guardar aquí. Exporta la partida.'); return false; }
}
function act(fn, message) {
  try { fn(); if (message) toast(message); netKey = networkKey(); map.dirty = true; afterCityAction(); autosave(); render(); sfx.result(true); return true; }
  catch (error) { toast(error.message); sfx.result(false); return false; }
}
/** Efecto de sonido de cada botón (ver ACTIONS en sfx.js): al pulsar, al salir bien la acción o según el estado. */
const hashOf = x => [...String(x)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);
function clickSound(a, b) {
  const spec = ACTIONS[a], id = b.dataset.id;
  sfx.intent = null;
  if (!spec || spec[0] === '@') return;
  if (spec[0] === '=') {
    const r = (a === 'freq-up' || a === 'freq-down') && routeById(id);
    return sfx.expect(spec.slice(1), r ? () => ({level: r.frequency / Math.max(1, E.maxFrequency(r))}) : {});
  }
  if (spec === '!play') return sfx.play(a === 'play' && playing ? 'pause' : state.started && state.ops.phase === 'planning' && layer !== 'real' ? 'departure' : 'resume');
  if (spec === '!toggle') {
    const on = a === 'music-toggle' ? !music.enabled : a === 'voice-toggle' ? !voices.enabled : a === 'sfx-toggle' ? !sfx.enabled : !map.follow;
    return a === 'sfx-toggle' && on ? null : sfx.play(on ? 'toggleOn' : 'toggleOff'); // al activar los efectos, el clic suena después
  }
  const siblings = [...(b.parentElement?.querySelectorAll(`[data-action="${a}"]`) || [])];
  const opts = {nav: {i: Object.keys(PAGES).indexOf(b.dataset.screen)}, tab: {i: Math.max(0, siblings.indexOf(b))}, pickCity: {i: hashOf(id)}, lever: {i: ['network', 'real', 'works'].indexOf(id)},
    speed: {i: +id}, tutorialNext: {i: (tut?.step ?? 0) + 1}}[spec] || {};
  sfx.play(spec, opts);
}
function icon(name) { return `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`; }
function chip(text, color) { return `<span class="chip" style="background:${esc(color)}">${esc(text)}</span>`; }
function routeColor(r) { return r.color || KIND_COLOR[r.kind] || '#8a2a46'; }
function routeChip(r) {
  if (r.code) return chip(r.code, routeColor(r));
  const p = r.products?.[0] || {av: 'AV', intercity: 'LD', regional: 'MD', commuter: 'C'}[r.kind] || 'R';
  const short = {'Media Distancia': 'MD', 'Regional Exprés': 'RE', 'Regional': 'R', 'Proximidad': 'PX', 'Larga distancia': 'LD', 'Avant Exprés': 'Avant', 'AVE Internacional': 'AVE'}[p] || p;
  return chip(short, routeColor(r));
}
function routeName(r) { return r.name || E.routeName(r); }
function sourceLink(id, text = 'Fuente') { const s = SOURCES.find(x => x.id === id); return s ? `<a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(text)}</a>` : ''; }
function statusOf(r) {
  if (r.active) return ['on', 'En servicio'];
  if (!E.isUnlocked(state, r)) return ['works', r.project ? 'Pendiente de obra' : 'Disponible ' + (r.availableFrom || E.dateOf(r.unlock))];
  return ['off', 'Por recuperar'];
}
function workOn(r) { return state.projects.find(p => !p.done && (p.route === r.id || PROJECTS.find(d => d.id === p.id)?.routes.includes(r.id))); }

/** Serie ilustrada para una circulación: producto, núcleo y tracción de la relación. */
function tripArtKey(t, r) {
  if (t.bus) return 'bus';
  const code = t.line !== undefined && t.line !== null ? S.lineCode(t.line) : '';
  if (r?.fleet) { const f = state.fleet.find(f => f.id === r.fleet); if (f) return artKey(f.model); }
  if (code === 'AVLO') return '106avlo';
  if (code === 'AVE' || code === 'EM') return '112';
  if (code === 'Avant') return '114';
  if (code === 'Alvia' || code === 'IC') return '130';
  if (code === 'MD' || code === 'PX') return '449';
  if (code === 'R' || code === 'RE' || code === 'TC') return r?.power === 'diesel' ? '599' : '449';
  if (r?.gauge === 'metric' || S.LINES[t.line]?.metric) return '2900';
  return r?.net === 'rodalies' ? '447' : r?.net === 'madrid' ? '465' : '463';
}


// ------------------------------------------------------------ ciudades: datos para el mapa
let cityCache = {key: null, list: []};
function mapCities() {
  const op = state.ops;
  const key = netKey + '#' + JSON.stringify(state.requests || []) + JSON.stringify(state.stations || {}) + state.month + '#' + JSON.stringify(op.surges || []) + Math.floor((op.minute || 0) / 15) + op.phase;
  if (cityCache.key === key) return cityCache.list;
  const ids = new Set(CITIES.map(c => c.id));
  for (const r of state.routes) for (const c of r.ends) ids.add(c);
  const list = [];
  for (const id of ids) {
    const c = CITY[id];
    if (!c) continue;
    const routes = E.cityRoutes(state, id), active = routes.filter(r => r.active).length;
    if (!routes.length && !E.cityPopulation(id)) continue;
    const crowd = routes.some(r => r.active && E.metrics(state, r).occupancy > .93);
    const request = (state.requests || []).some(q => q.city === id) || liveSurges().some(x => x.city === id);
    list.push({id, name: c.name, lon: c.lon, lat: c.lat, pop: E.cityPopulation(id), total: routes.length, active,
      status: !routes.length || !active ? 'off' : active === routes.length ? 'on' : 'some', crowd, request, station: state.stations?.[id] || 0});
  }
  list.sort((a, b) => (a.pop || 0) - (b.pop || 0));
  return (cityCache = {key, list}).list;
}
function liveSurges() { const op = state.ops; return op.phase === 'running' ? (op.surges || []).filter(x => !x.done && !x.failed && op.minute >= x.at - 30) : []; }
function otherEnd(r, id) { const o = r.ends.find(c => c !== id) || r.ends[0]; return CITY[o]?.name || o; }
function nearCity(st, c) { return Math.hypot((st.lon - c.lon) * 85, (st.lat - c.lat) * 111) < 18; }

// ------------------------------------------------------------ viajeros e ingresos de la jornada
let popups = [], today = {pax: 0, money: 0, trains: 0}, perTrip = {}, seenSurges = new Set();
function resetToday() { today = {pax: 0, money: 0, trains: 0}; perTrip = {}; popups = []; seenSurges = new Set(); }
function tripYield(t) {
  const r = state.routes.find(r => r.id === t.route);
  if (!r) return {pax: 0, money: 0};
  if (!perTrip[r.id]) { const m = E.metrics(state, r), k = Math.max(1, r.frequency * (r.circular ? 1 : 2) * 30); perTrip[r.id] = {pax: m.passengers / k, money: m.revenue * 1e6 / k}; }
  const y = perTrip[r.id], f = .7 + ((t.dep * 37 + t.id.length * 11) % 60) / 100;
  return {pax: Math.max(1, Math.round(y.pax * f)), money: y.money * f};
}
function spawnArrivals(from, to) {
  const now = performance.now();
  for (const t of plan()) {
    if (!(t.arrival > from && t.arrival <= to)) continue;
    const y = tripYield(t);
    today.pax += y.pax; today.money += y.money; today.trains++;
    let ll = null;
    if (t.trip) { const st = S.STATIONS[t.trip.stations.at(-1)]; ll = [st.lon, st.lat]; } else if (t.coords?.length) ll = t.coords.at(-1);
    if (ll && popups.length < 50) popups.push({lon: ll[0], lat: ll[1], text: '+' + n(y.pax) + ' viajeros', sub: '+' + n(y.money / 1000, 1) + ' mil €', color: '#2f7d48', born: now});
  }
  popups = popups.filter(p => now - p.born < 2700);
}
function celebrate(city, text, sub) {
  const c = CITY[city];
  if (c) popups.push({lon: c.lon, lat: c.lat, text, sub, color: '#b07a12', born: performance.now()});
}
function checkSurgeEvents() {
  for (const x of state.ops.surges || []) {
    if (!seenSurges.has(x.id) && state.ops.minute >= x.at - 30 && !x.done && !x.failed) {
      seenSurges.add(x.id);
      const r = state.routes.find(r => r.id === x.route);
      showAlert({type: 'surge', reason: x.reason + ' en ' + (CITY[x.city]?.name || ''), route: x.route, place: `refuerza hasta ${x.need} salidas antes de las ${clock(x.until)} · +${n(x.bonus * 1000)} mil €`, city: x.city}, r);
    }
  }
  for (const x of O.checkSurges(state)) { celebrate(x.city, '¡Refuerzo a tiempo!', '+' + n(x.bonus * 1000) + ' mil €'); toast('Momento del día cumplido: ' + x.reason + ' · +' + n(x.bonus * 1000) + ' mil €'); cityCache.key = null; }
}

// ------------------------------------------------------------ acciones rápidas sobre conexiones
function fleetFor(r, freq) {
  const lots = state.fleet.filter(f => f.qty && f.condition >= 30 && E.compatible(r, MODEL[f.model]));
  const fits = f => E.available(state, f, r.id) >= E.requiredUnits(r, MODEL[f.model], freq);
  return lots.find(f => f.id === r.fleet && fits(f)) || lots.filter(fits).sort((a, b) => E.available(state, b, r.id) - E.available(state, a, r.id))[0] || null;
}
function setService(r, freq, fare = r.fare) {
  const max = E.maxFrequency(r);
  freq = Math.max(1, Math.min(max, freq));
  let f = fleetFor(r, freq), want = freq;
  while (!f && freq > 1) { freq--; f = fleetFor(r, freq); }
  if (!f) throw Error('No hay trenes compatibles libres para esta conexión. Compra material o libera unidades de otra línea.');
  E.configureRoute(state, r.id, f.id, freq, fare);
  if (freq < want) toast(`Solo hay trenes para ${freq} salidas por sentido.`);
}
function afterCityAction() {
  const before = state.stats.requests || 0, cash = state.cash;
  E.checkRequests(state);
  if ((state.stats.requests || 0) > before) {
    const gain = state.cash - cash;
    toast(`¡Petición atendida! +${money(gain)} y más reputación.`);
    const city = inspect?.type === 'city' ? inspect.id : 'mad';
    celebrate(city, '¡Petición cumplida!', '+' + money(gain));
  }
  if (state.ops.phase === 'running') checkSurgeEvents();
  perTrip = {}; cityCache.key = null;
}
function reqText(q) {
  const r = state.routes.find(r => r.id === q.route), dest = r ? otherEnd(r, q.city) : '';
  return {open: `Quiere recuperar el tren con ${dest}`, more: `Pide ${q.target} salidas por sentido con ${dest}`, fare: `Pide bajar a ${q.target} € la tarifa con ${dest}`,
    station: `Quiere una estación mejor: ${E.STATION_LEVELS[q.target]}`}[q.type];
}
function doRequest(q) {
  const r = state.routes.find(r => r.id === q.route);
  if (q.type === 'station') E.upgradeStation(state, q.city);
  else if (q.type === 'open') setService(r, Math.max(1, Math.round(E.maxFrequency(r) * .4)));
  else if (q.type === 'more') setService(r, q.target);
  else if (q.type === 'fare') setService(r, r.frequency, q.target);
}

// ------------------------------------------------------------ menú visual de la ciudad
function stationIcon(level, active) {
  const h = 10 + level * 5, w = 16 + level * 6;
  return `<svg viewBox="0 0 44 34" class="st-icon ${active ? 'on' : ''}"><path d="M${22 - w / 2} 30 V${30 - h} L22 ${24 - h} L${22 + w / 2} ${30 - h} V30 Z"/>${level >= 2 ? `<path d="M${22 + w / 2} 30 V${32 - h} Q${30 + w / 2} ${26 - h} ${40} ${32 - h} V30" fill="none"/>` : ''}<rect x="${22 - 3}" y="${24}" width="6" height="6"/></svg>`;
}
function cityInspector() {
  const id = inspect.id, c = CITY[id];
  if (!c) return null;
  map.selectedCity = id;
  const routes = E.cityRoutes(state, id).sort((a, b) => (b.active - a.active) || ((S.routeStats(b.id, 'L')?.trips || 0) - (S.routeStats(a.id, 'L')?.trips || 0)));
  const pop = E.cityPopulation(id), level = state.stations?.[id] || 0, m = currentMinute(), light = O.daylight(state, m, c.lon, c.lat).light;
  const reqs = (state.requests || []).filter(q => q.city === id), surges = liveSurges().filter(x => x.city === id);
  const incidents = state.ops.incidents.filter(x => routes.some(r => r.id === x.route) && m >= x.at && !state.ops.resolved.includes(x.trip));
  const active = routes.filter(r => r.active);
  const monthly = active.reduce((v, r) => v + E.metrics(state, r).net, 0), pax = active.reduce((v, r) => v + E.metrics(state, r).passengers, 0);
  const deps = plan().filter(t => t.dep >= m - 1 && routes.some(r => r.id === t.route) && (t.trip ? nearCity(S.STATIONS[t.trip.stations[0]], c) : t.ends?.[0] === id || (t.coords && Math.hypot(t.coords[0][0] - c.lon, t.coords[0][1] - c.lat) < .2))).slice(0, 6);
  const cards = routes.map(r => {
    const max = E.maxFrequency(r), unlocked = E.isUnlocked(state, r), mt = r.active ? E.metrics(state, r) : null, official = r.real ? S.routeStats(r.id, 'L')?.trips || 0 : 0;
    const pct = r.active ? r.frequency / max * 100 : 0;
    const surge = surges.find(x => x.route === r.id), req = reqs.find(q => q.route === r.id);
    return `<div class="conn ${r.active ? 'on' : unlocked ? 'off' : 'locked'} ${surge || req ? 'hot' : ''}">
      <div class="conn-top">${routeChip(r)}<strong>${esc(otherEnd(r, id))}</strong>${surge ? `<span class="flag">Necesita ${surge.need}</span>` : req ? '<span class="flag">Petición</span><span><i class="crowd">▮▮▮</i>Trenes llenos</span>' : ''}</div>
      <div class="conn-bar"><span style="width:${pct}%;background:${routeColor(r)}"></span></div>
      <div class="conn-meta">${r.active ? `<b>${r.frequency}</b>/${max} salidas por sentido · <span class="${mt.net >= 0 ? 'pos' : 'neg'}">${signed(mt.net)}/mes</span>${mt.occupancy > .93 ? ' · <span class="neg">trenes llenos</span>' : ''}` : unlocked ? (r.real ? `${n(official)} trenes en el horario real` : 'Sin horario publicado') : esc(statusOf(r)[1])}</div>
      <div class="conn-actions">${r.active ? `<button class="round" data-action="freq-down" data-id="${r.id}" aria-label="Menos trenes" ${r.frequency <= 1 ? 'disabled' : ''}>−</button><button class="round plus" data-action="freq-up" data-id="${r.id}" aria-label="Más trenes" ${r.frequency >= max ? 'disabled' : ''}>+</button>` : unlocked ? `<button class="btn small primary" data-action="open-route" data-id="${r.id}" ${state.ended ? 'disabled' : ''}>Abrir · 4 M€</button>` : '<span class="small muted">🚧 En obras</span>'}<button class="btn small ghost" data-action="route" data-id="${r.id}">Detalles</button></div></div>`;
  }).join('');
  const body = `<div class="city-hero">${citySkyline(id, c.name, pop || 30, level, light, m)}<div class="city-title"><span>${pop ? (pop >= 1000 ? n(pop / 1000, 1) + ' millones de habitantes' : n(pop) + ' mil habitantes') : 'Localidad'}</span><h2>${esc(c.name)}</h2></div></div>
  <div class="city-stats"><div><b>${active.length}/${routes.length}</b><span>conexiones</span></div><div><b>${n(pax / 30)}</b><span>viajeros/día</span></div><div><b class="${monthly >= 0 ? 'pos' : 'neg'}">${signed(monthly)}</b><span>al mes</span></div></div>
  ${incidents.map(x => `<div class="req red"><b>${O.INCIDENT_TYPES[x.type]?.icon || '⚠'} ${esc(x.reason)}</b><span>${esc(routeName(state.routes.find(r => r.id === x.route)))} · demora ${x.delay} min</span><div class="actions">${Object.entries(O.RESPONSES).map(([k, v]) => `<button class="btn small ${k === 'team' ? 'primary' : ''}" data-action="respond" data-id="${x.trip}" data-option="${k}">${esc(v.label)}</button>`).join('')}</div></div>`).join('')}
  ${surges.map(x => `<div class="req gold"><b>⚡ ${esc(x.reason)}</b><span>Refuerza la conexión con ${esc(otherEnd(state.routes.find(r => r.id === x.route), id))} hasta ${x.need} salidas antes de las ${clock(x.until)}.</span><em>+${n(x.bonus * 1000)} mil €</em></div>`).join('')}
  ${reqs.map(q => `<div class="req"><b>❗ ${esc(reqText(q))}</b><span>Plazo: ${E.dateOf(q.until)} · recompensa</span><em>+${q.reward} M€</em><div class="actions"><button class="btn small primary" data-action="request" data-id="${q.id}">${q.type === 'station' ? 'Mejorar estación' : q.type === 'open' ? 'Abrir conexión' : q.type === 'fare' ? 'Bajar tarifa' : 'Poner más trenes'}</button></div></div>`).join('')}
  <h3 class="sub">Conexiones</h3><div class="conns">${cards || '<p class="muted">Sin conexiones ferroviarias en el juego.</p>'}</div>
  <h3 class="sub">Estación · ${E.STATION_LEVELS[level]}</h3>
  <div class="stations">${[0, 1, 2, 3].map(l => `<div class="${l <= level ? 'have' : ''}">${stationIcon(l, l === level)}<span>${E.STATION_LEVELS[l]}</span></div>`).join('')}</div>
  ${level < 3 ? `<button class="btn primary" data-action="station-up" data-id="${id}" ${state.ended ? 'disabled' : ''}>Mejorar a «${E.STATION_LEVELS[level + 1]}» · ${E.stationCost(state, id)} M€</button><p class="small muted">+6 % de demanda y más fiabilidad en todas sus conexiones.</p>` : '<p class="small">Estación al máximo nivel.</p>'}
  ${deps.length ? `<h3 class="sub">Próximas salidas</h3><div class="board">${boardRows(deps, m)}</div>` : ''}`;
  return {kicker: 'Ciudad', title: esc(c.name), body, cls: 'city'};
}

// ------------------------------------------------------------ tutorial guiado
const routeById = id => state.routes.find(r => r.id === id);
const TUTORIAL = [
  {title: 'Bienvenida', text: '¡Hola! Soy Raquel Sanz, ministra de Transportes (de ficción, que conste en acta). Te enseño a dirigir la red en un periquete. Si ya sabes, sáltate el tutorial; yo hago como que no me ofendo.', next: true},
  {title: 'Las ciudades mandan', text: 'Cada círculo es una ciudad. Verde: todo funciona; ámbar: funciona a la española; gris: ni está ni se le espera. Pulsa sobre Madrid, que aquí todo pasa por Madrid.', city: 'mad', when: () => inspect?.type === 'city' && inspect.id === 'mad', enter: () => { map.focusAt(-3.7, 40.4, 1.6); }},
  {title: 'El menú de la ciudad', text: 'Aquí tienes la ciudad, sus conexiones y su estación. Lo dorado del mapa son conexiones en servicio; lo demás, promesas electorales.', target: '#inspector .city-hero', next: true},
  {title: 'Más trenes', text: 'Pulsa + en la conexión con València para poner más trenes del horario real. Los valencianos lo agradecerán, y los madrileños con apartamento en la playa, más.', target: '[data-action=freq-up][data-id=madrid-valencia]', when: () => routeById('madrid-valencia')?.frequency > tut.f0, enter: () => { tut.f0 = routeById('madrid-valencia')?.frequency || 0; }},
  {title: 'Abre una conexión', text: 'Las conexiones grises están cerradas. Abre la de Salamanca: cuesta 4 M€ y usa trenes libres compatibles. Calderilla, para lo que se estila.', target: '[data-action=open-route][data-id=madrid-salamanca]', when: () => routeById('madrid-salamanca')?.active},
  {title: 'Peticiones', text: 'Las ciudades con ❗ te piden cosas: más trenes, una conexión, una tarifa más baja o una estación decente. Como los alcaldes, pero sin llamarte a las tantas. Cumplirlas da dinero y reputación. Las tienes a la izquierda.', target: '#mission .requests', next: true, enter: () => { inspect = null; renderInspector(); }},
  {title: 'Empieza el día', text: 'Cada jornada empieza con el primer tren real y termina con el último. Pulsa «Comenzar jornada». Con el café en la mano, a ser posible.', target: '[data-action=day-start]', when: () => state.ops.phase === 'running'},
  {title: 'Más deprisa', text: 'Elige 10× para que el reloj vaya más rápido. Ojalá las obras funcionaran igual.', target: '.speed', when: () => speedIndex >= 2},
  {title: 'Viajeros e ingresos', text: 'Cada tren que llega suma viajeros e ingresos: los verás sobre las ciudades y en «Hoy», arriba. Sí, ese dinero es tuyo. Bueno, de Renfe. Bueno, de Hacienda.', target: '#resources', when: () => today.trains >= 6},
  {title: '¡Una avería!', text: '¡Una incidencia! Tranquilidad, que esto pasa en las mejores familias. Pulsa «Decidir» y elige cómo responder.', target: '.alert-pill', when: () => state.ops.resolved.length > 0, enter: () => { if (state.ops.phase === 'running' && !O.injectIncident(state, state.ops.minute)) tutorialNext(); }},
  {title: 'Momentos del día', text: 'A veces una ciudad tiene un pico de demanda: un partido, un congreso, el puente de diciembre… Si refuerzas a tiempo la conexión indicada, te llevas una bonificación. Los trenes se pueden cambiar en plena jornada.', next: true},
  {title: 'Fin de la jornada', text: 'Pulsa «Hasta el último tren» para cerrar el día. El último en llegar, que apague la luz.', target: '[data-action=day-end]', when: () => state.ops.phase === 'review'},
  {title: 'El parte del día', text: 'El parte del día: puntualidad, viajeros y resultado. Si sale mal, échale la culpa a la meteorología, que es lo que hacemos todos. Pulsa «Siguiente jornada».', target: '#modal [data-action=day-next]', when: () => state.ops.phase === 'planning'},
  {title: 'Compra trenes', text: 'Para crecer necesitas más trenes, y tardan unos dos años en llegar: los fabricantes también tienen su ritmo. Abre «Compras».', target: '[data-screen=market]', when: () => screen === 'market'},
  {title: '¡A dirigir!', text: 'Cumple los objetivos del capítulo para recibir financiación. Acércate con la rueda para ver trenes, estaciones y obras. Y recuerda: si algo sale bien, lo anuncio yo. ¡Buen viaje!', target: '#mission', next: true},
];
let tut = null;
function startTutorial() { tut = {step: -1, f0: 0}; state.tutorial = {done: false}; tutorialNext(); }
function tutorialNext() {
  if (!tut) return;
  tut.step++;
  if (tut.step >= TUTORIAL.length) return endTutorial();
  TUTORIAL[tut.step].enter?.();
  renderCoach();
}
function endTutorial() { if (voices.speaking?.where === 'coach') voices.stop(); tut = null; state.tutorial = {done: true}; autosave(); $('coach')?.remove(); $('spot')?.remove(); toast('Tutorial completado. Lo puedes repetir desde Ayuda.'); }
function renderCoach() {
  if (!tut) return;
  const step = TUTORIAL[tut.step];
  if (step.when?.()) return tutorialNext();
  let coach = $('coach'), spot = $('spot');
  if (!coach) {
    coach = document.createElement('div'); coach.id = 'coach'; coach.className = 'coach';
    spot = document.createElement('div'); spot.id = 'spot'; spot.className = 'spot';
  }
  const host = $('modal').open ? $('modal') : document.body;
  if (coach.parentNode !== host) { host.appendChild(spot); host.appendChild(coach); }
  const html = `<div class="portrait p1" aria-hidden="true"></div><div><div class="kicker">Tutorial · ${tut.step + 1}/${TUTORIAL.length}</div><h3>${esc(step.title)}</h3><p data-say="${esc(step.text)}">${sayHtml(step.text)}</p><div class="actions">${step.next ? '<button class="btn small primary" data-action="tutorial-next">Siguiente</button>' : '<button class="btn small ghost" data-action="tutorial-next">Omitir paso</button>'}<button class="btn small ghost" data-action="tutorial-skip">Salir</button></div></div>`;
  if (coach.dataset.step !== String(tut.step)) { coach.innerHTML = html; coach.dataset.step = tut.step; coach.querySelector('h3').insertAdjacentHTML('beforeend', sayButton('minister', 'coach')); speakIn(coach, 'minister', 'coach'); }
  let rect = null;
  if (step.city) { const c = CITY[step.city], p = map.screenOf(c.lon, c.lat), cr = $('map').getBoundingClientRect(); rect = {left: cr.left + p[0] - 26, top: cr.top + p[1] - 26, width: 52, height: 52, round: true}; }
  else if (step.target) { const el = (host === $('modal') ? $('modal') : document).querySelector(step.target); if (el && el.offsetParent !== null) { const b = el.getBoundingClientRect(); rect = {left: b.left - 6, top: b.top - 6, width: b.width + 12, height: b.height + 12}; } }
  const hostRect = host === document.body ? {left: 0, top: 0} : host.getBoundingClientRect();
  if (rect) { Object.assign(spot.style, {display: 'block', left: rect.left - hostRect.left + 'px', top: rect.top - hostRect.top + 'px', width: rect.width + 'px', height: rect.height + 'px', borderRadius: rect.round ? '50%' : '14px'}); }
  else spot.style.display = 'none';
  const W = coach.offsetWidth || 380, H = coach.offsetHeight || 170, vw = innerWidth, vh = innerHeight;
  let x = rect ? rect.left + rect.width / 2 - W / 2 : vw / 2 - W / 2, y = rect ? (rect.top + rect.height + H + 24 < vh ? rect.top + rect.height + 14 : rect.top - H - 14) : vh / 2 - H / 2;
  x = Math.max(12, Math.min(vw - W - 12, x)); y = Math.max(12, Math.min(vh - H - 12, y));
  coach.style.left = x - hostRect.left + 'px'; coach.style.top = y - hostRect.top + 'px';
}

// ------------------------------------------------------------ selección en el mapa
function pick(hit) {
  sfx.play(!hit ? (inspect ? 'deselect' : 'tick') : {route: 'pickRoute', city: 'pickCity', train: 'pickTrain', station: 'pickStation', work: 'pickWork'}[hit.type] || 'tap', {i: hashOf(hit?.id ?? '')});
  if (!hit) { if (inspect) { inspect = null; map.selected = null; map.selectedTrain = null; map.selectedCity = null; map.follow = false; renderInspector(); } return; }
  if (hit.type === 'route') return selectRoute(hit.id, false);
  map.selectedCity = null;
  if (hit.type === 'city') { inspect = {type: 'city', id: hit.id}; map.selected = null; map.selectedTrain = null; map.selectedCity = hit.id; }
  if (hit.type === 'train') { inspect = {type: 'train', id: hit.id}; map.selectedTrain = hit.id; map.selected = null; }
  if (hit.type === 'station') { inspect = {type: 'station', id: hit.id}; map.selectedTrain = null; }
  if (hit.type === 'work') { inspect = {type: 'work', id: hit.id}; }
  screen = null; renderNav(); $('drawer').classList.add('hidden');
  renderInspector();
}
function selectRoute(id, zoom = true) {
  inspect = {type: 'route', id}; map.selectedTrain = null; map.follow = false; screen = null;
  map.focus(id, zoom); renderNav(); $('drawer').classList.add('hidden'); renderInspector();
}

// ------------------------------------------------------------ reloj de la jornada
function frame(t) {
  requestAnimationFrame(frame);
  const dt = Math.min(250, t - (lastTick || t)); lastTick = t;
  const op = state.ops;
  if (playing) {
    const rate = SPEEDS[speedIndex][0] * dt / 1000;
    if (op.phase === 'running') {
      const before = op.minute, ended = O.moveClock(state, rate);
      spawnArrivals(before, op.minute);
      checkIncidents();
      checkSurgeEvents();
      if (ended) { pause(); finishDay(); }
    } else if (layer === 'real') {
      observerMinute = Math.min(1560, observerMinute + rate);
      if (observerMinute >= 1560) pause();
    } else pause();
  }
  if (t - lastTimeline > 120) { lastTimeline = t; renderClock(); drawTimeline(); renderCoach(); checkMusicMood(); }
  if (t - lastPanel > 1000) {
    lastPanel = t;
    if (playing && screen === 'ops') renderDrawer();
    if (playing && inspect && ['train', 'station', 'city'].includes(inspect.type)) renderInspector();
    if (playing) { renderHud(); renderMission(); }
  }
}
function play() {
  if (layer === 'real' && state.ops.phase !== 'running') { playing = true; renderDaybar(); return; }
  if (!state.started) return intro();
  if (state.ended) return toast('Tu mandato ha terminado.');
  if (E.pendingDecision(state)) return showDecision();
  if ($('modal').open) return;
  const op = state.ops;
  if (op.phase === 'review') return dayReport();
  if (op.phase === 'planning' && layer !== 'real') { try { O.startDay(state); seenIncidents = new Set(); resetToday(); netKey = networkKey(); } catch (e) { sfx.play('error'); return toast(e.message); } }
  playing = true; renderDaybar();
}
function pause() { playing = false; renderDaybar(); }
function checkIncidents() {
  const op = state.ops;
  for (const x of op.incidents) {
    if (op.minute >= x.at && !seenIncidents.has(x.trip)) {
      seenIncidents.add(x.trip);
      if (ui.autoPause) pause();
      showAlert(x);
      if (screen === 'ops') renderDrawer();
    }
  }
}
function showAlert(x, rr) {
  const r = rr || state.routes.find(r => r.id === x.route);
  if (x.type === 'surge') {
    document.querySelector('.alert-pill')?.remove();
    const el = document.createElement('div'); el.className = 'alert-pill gold';
    el.innerHTML = `<span>⚡</span><span><b>${esc(x.reason)}</b> · ${esc(x.place)}</span><button class="btn small gold" data-action="city" data-id="${x.city}">Ver ciudad</button>`;
    $('game').appendChild(el); clearTimeout(alertTimer); alertTimer = setTimeout(() => el.remove(), 12000); return;
  }
  document.querySelector('.alert-pill')?.remove();
  const el = document.createElement('div');
  el.className = 'alert-pill';
  el.innerHTML = `<span>${O.INCIDENT_TYPES[x.type]?.icon || '⚠'}</span><span><b>${esc(x.reason)}</b> · ${esc(routeName(r))}${x.place ? ' · ' + esc(x.place) : ''}</span><button class="btn small gold" data-action="open-incidents">Decidir</button>`;
  $('game').appendChild(el);
  clearTimeout(alertTimer); alertTimer = setTimeout(() => el.remove(), 12000);
}
function finishDay() {
  try { O.endDay(state); } catch (e) { return toast(e.message); }
  autosave(); render(); dayReport();
}

// ------------------------------------------------------------ render general
function render() {
  O.ensureOps(state);
  netKey = networkKey();
  renderHud(); renderNav(); renderMission(); renderLegend(); renderDaybar();
  if (screen) renderDrawer(); else $('drawer').classList.add('hidden');
  renderInspector();
}
function renderHud() {
  const b = E.balance(state), kind = dayType();
  const long = O.dayDate(state).toLocaleDateString('es-ES', {weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC'});
  $('date').textContent = state.ended && state.ending === '2050' ? '31 dic 2050' : long[0].toUpperCase() + long.slice(1);
  $('dateShort').textContent = O.dayLabel(state);
  $('dayKind').textContent = `Jornada ${state.ops.completed + 1} · ${S.DAY_TYPES[kind]} · horario oficial ${kind === 'L' ? 'laborable' : kind === 'S' ? 'de sábado' : 'de domingo'}`;
  const trains = plan().length;
  $('resources').innerHTML = [
    ['Tesorería', money(state.cash), ''],
    ['Resultado / mes', `<span class="${b.net >= 0 ? 'pos' : 'neg'}">${signed(b.net)}</span>`, ''],
    ['Viajeros hoy', state.ops.phase === 'planning' ? '—' : n(today.pax), ''],
    ['Ingresos hoy', state.ops.phase === 'planning' ? '—' : today.money < 1e6 ? n(today.money / 1000) + ' mil €' : n(today.money / 1e6, 2) + ' M€', ''],
    ['Satisfacción', n(state.satisfaction) + '<small>%</small>', ''],
  ].map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`).join('');
  renderClock();
}
function renderClock() {
  const m = currentMinute(), d = O.daylight(state, m);
  $('clock').textContent = clock(m);
  const night = d.night > .55;
  if ((document.body.dataset.sky === 'night') !== night) document.body.dataset.sky = night ? 'night' : 'day';
}
function renderNav() {
  const pending = state.ops.incidents.filter(x => state.ops.minute >= x.at && !state.ops.resolved.includes(x.trip)).length;
  $('navigation').innerHTML = Object.entries(PAGES).map(([k, name]) => `<button class="${screen === k ? 'active' : ''}" data-action="navigate" data-screen="${k}" aria-label="${name}" ${screen === k ? 'aria-current="page"' : ''}>${icon(k)}<span>${name}</span>${k === 'ops' && pending ? `<span class="badge">${pending}</span>` : ''}</button>`).join('') +
    `<div class="spacer"></div><button id="musicBtn" class="music-btn" data-action="music" aria-label="Banda sonora"></button><button data-action="save-dialog" aria-label="Guardar partida">${icon('save')}<span>Guardar</span></button><button data-action="help" aria-label="Cómo jugar">${icon('help')}<span>Ayuda</span></button>`;
  renderMusicButton();
}
function renderMission() {
  const c = CHAPTERS[state.chapter];
  const el = $('mission');
  el.classList.toggle('hidden', !!screen || (!!inspect && innerWidth < 1200) || !state.started);
  if (!c) return;
  el.innerHTML = `<div class="kicker">Capítulo ${state.chapter + 1} · ${c.years}</div><h2>${esc(c.title)}</h2><ul>${c.objectives.map(([k, target, title]) => {
    const v = E.objectiveValue(state, k), done = v >= target;
    return `<li class="${done ? 'done' : ''}"><i></i><span>${esc(title)}<div class="meter"><span style="width:${Math.min(100, v / target * 100)}%"></span></div></span><span>${k === 'solvent' ? (v ? '✓' : '—') : n(Math.min(v, target)) + '/' + n(target)}</span></li>`;
  }).join('')}</ul>${(state.requests || []).length || liveSurges().length ? `<div class="requests"><div class="kicker">Peticiones de las ciudades</div>${liveSurges().map(x => `<button data-action="city" data-id="${x.city}"><b>⚡ ${esc(CITY[x.city]?.name)}</b><span>${esc(x.reason)} · hasta ${clock(x.until)}</span><em>+${n(x.bonus * 1000)}k€</em></button>`).join('')}${(state.requests || []).map(q => `<button data-action="city" data-id="${q.city}"><b>❗ ${esc(CITY[q.city]?.name)}</b><span>${esc(reqText(q))}</span><em>+${q.reward} M€</em></button>`).join('')}</div>` : ''}`;
}
function renderLegend() {
  const items = layer === 'works'
    ? [['#d18a2a', 'Obra en ejecución'], ['#5a4630', 'Tramo terminado'], ['#a06a1c', 'Proyecto negociable', true]]
    : [['#a3123a', 'AVE · AVLO · Avant'], ['#2f6f9f', 'Alvia · Intercity'], ['#c27a18', 'Media Distancia'], ['#8a7c69', layer === 'real' ? 'Geometría aproximada' : 'Por recuperar', true]];
  $('legend').innerHTML = items.map(([c, t, d]) => `<span><i class="${d ? 'dash' : ''}" style="background:${c};color:${c}"></i>${t}</span>`).join('') + (layer === 'works' ? '' : '<span><i class="dot" style="border-color:#3f9d5a"></i>Ciudad conectada</span><span><i class="dot" style="border-color:#f0b544"></i>Parcial</span><span><i class="dot" style="border-color:#9c8b74"></i>Sin tren</span><span><i class="pin">!</i>Petición</span><span><i class="crowd">▮▮▮</i>Trenes llenos</span>') + `<span class="muted">${layer === 'real' ? 'Todas las circulaciones publicadas · ' + S.DAY_TYPES[dayType()] : 'Pulsa una ciudad'}</span>`;
}
function renderDaybar() {
  const op = state.ops, trips = plan(), b = O.dayBounds(trips);
  const observer = layer === 'real' && op.phase !== 'running';
  const primary = op.phase === 'planning' ? ['day-start', 'Comenzar jornada'] : op.phase === 'running' ? ['day-end', 'Hasta el último tren'] : ['day-review', 'Ver parte del día'];
  $('daybar').innerHTML = `<div class="turn"><small>${observer ? 'Observación del horario real' : op.phase === 'planning' ? 'Preparación' : op.phase === 'running' ? 'Jornada en curso' : 'Jornada cerrada'}</small><strong>${observer ? S.DAY_TYPES[dayType()] : clock(b.first) + ' → ' + clock(b.last)}</strong><span>${observer ? n(realTrips(dayType()).length) + ' circulaciones publicadas' : n(trips.length) + ' circulaciones · ' + n(trips.filter(t => t.bus).length) + ' en autobús'}</span></div>
  <div class="timeline" id="timeline" title="${observer ? 'Pulsa para cambiar la hora de observación' : 'Ritmo del día: trenes en circulación'}"><canvas id="timelineCanvas"></canvas></div>
  <div class="controls"><div class="speed" role="group" aria-label="Velocidad">${SPEEDS.map(([, label], i) => `<button class="${i === speedIndex ? 'active' : ''}" data-action="speed" data-id="${i}">${label}</button>`).join('')}</div>
  <button class="play" data-action="play" aria-label="${playing ? 'Pausar' : 'Reproducir'}">${playing ? '❚❚' : '▶'}</button>
  ${observer ? '' : `<button class="btn primary" data-action="${primary[0]}">${primary[1]}</button>`}
  ${op.phase !== 'running' && !observer ? '<button class="btn" data-action="skip-month" title="Liquida el resto del mes sin jugar sus jornadas">Delegar mes</button>' : ''}</div>`;
  drawTimeline();
}
function drawTimeline() {
  const cv = $('timelineCanvas');
  if (!cv) return;
  const w = cv.clientWidth, h = cv.clientHeight, dpr = Math.min(2, devicePixelRatio || 1);
  if (!w) return;
  if (cv.width !== w * dpr) { cv.width = w * dpr; cv.height = h * dpr; }
  const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0); c.clearRect(0, 0, w, h);
  const observer = layer === 'real' && state.ops.phase !== 'running';
  const trips = observer ? realTrips(dayType()) : plan();
  const b = observer ? {first: 240, last: 1560} : O.dayBounds(trips), span = Math.max(60, b.last - b.first);
  const x = m => (m - b.first) / span * w, night = document.body.dataset.sky === 'night';
  // cielo: día y noche según la altura del sol en Madrid
  for (let px = 0; px < w; px += 3) {
    const m = b.first + px / w * span, l = O.daylight(state, m).light;
    c.fillStyle = `rgba(${Math.round(mix(28, 250, l))},${Math.round(mix(36, 214, l))},${Math.round(mix(70, 150, l))},${night ? .35 : .28})`;
    c.fillRect(px, 0, 3, h - 14);
  }
  // trenes en circulación cada 10 minutos
  const bins = Math.ceil(span / 10), counts = new Array(bins).fill(0);
  for (const t of trips) { const a = Math.max(0, Math.floor((t.dep - b.first) / 10)), z = Math.min(bins - 1, Math.floor((t.arrival - b.first) / 10)); for (let i = a; i <= z; i++) counts[i]++; }
  const max = Math.max(1, ...counts);
  c.beginPath(); c.moveTo(0, h - 14);
  counts.forEach((v, i) => c.lineTo(i / bins * w, h - 14 - v / max * (h - 22)));
  c.lineTo(w, h - 14); c.closePath();
  c.fillStyle = night ? 'rgba(255,210,130,.45)' : 'rgba(138,42,70,.32)'; c.fill();
  c.strokeStyle = night ? 'rgba(255,220,150,.9)' : 'rgba(138,42,70,.85)'; c.lineWidth = 1.2; c.stroke();
  // horas
  c.font = '500 10px "IBM Plex Mono", monospace'; c.fillStyle = night ? 'rgba(240,230,210,.75)' : 'rgba(60,45,30,.7)';
  for (let m = Math.ceil(b.first / 120) * 120; m <= b.last; m += 120) { c.fillRect(x(m), h - 14, 1, 4); c.fillText(clock(m).slice(0, 5), Math.min(w - 32, Math.max(0, x(m) - 14)), h - 2); }
  // incidencias
  for (const inc of observer ? [] : state.ops.incidents) { const px = x(inc.at); c.fillStyle = state.ops.resolved.includes(inc.trip) ? '#3f7d4e' : '#c23b2f'; c.beginPath(); c.moveTo(px, 2); c.lineTo(px + 5, 10); c.lineTo(px - 5, 10); c.closePath(); c.fill(); }
  // ahora
  const now = currentMinute(), px = x(now);
  c.fillStyle = night ? '#ffe2a0' : '#2a1f1c'; c.fillRect(px - 1, 0, 2, h - 14);
  c.beginPath(); c.arc(px, h - 14, 4, 0, Math.PI * 2); c.fill();
  cv.dataset.first = b.first; cv.dataset.span = span;
}
function mix(a, b, t) { return a + (b - a) * t; }

// ------------------------------------------------------------ cajón de páginas
function navigate(to) {
  if (screen === to || !PAGES[to]) { screen = null; $('drawer').classList.add('hidden'); renderNav(); renderMission(); return; }
  screen = to; inspect = null; map.selected = null; map.selectedTrain = null;
  renderNav(); renderMission(); renderInspector(); renderDrawer();
}
function header(kicker, title, text = '') {
  return `<header><div><div class="kicker">${kicker}</div><h1>${title}</h1>${text ? `<p>${text}</p>` : ''}</div><button class="close" data-action="close-drawer" aria-label="Cerrar">×</button></header>`;
}
function renderDrawer() {
  const el = $('drawer');
  if (!screen) { el.classList.add('hidden'); return; }
  const pages = {ops: opsPage, network: networkPage, timetables: timetablesPage, fleet: fleetPage, market: marketPage, works: worksPage, finance: financePage, story: storyPage, archive: archivePage};
  const scroll = el.querySelector('.body')?.scrollTop || 0, focusId = document.activeElement?.id, pos = document.activeElement?.selectionStart;
  const [head, body] = pages[screen]();
  el.innerHTML = head + `<div class="body">${body}</div>`;
  el.classList.remove('hidden');
  el.querySelector('.body').scrollTop = scroll;
  if (focusId && $(focusId)) { $(focusId).focus(); try { $(focusId).setSelectionRange(pos, pos); } catch {} }
  if (screen === 'finance') drawChart();
}

function boardRows(trips, minute, opts = {}) {
  return trips.map(t => {
    const r = state.routes.find(r => r.id === t.route);
    const color = t.line !== undefined && t.line !== null ? S.LINES[t.line]?.color : r ? routeColor(r) : '#8a2a46';
    const code = t.line !== undefined && t.line !== null ? S.lineCode(t.line) : r?.code || 'R';
    const dep = opts.at !== undefined ? opts.at(t) : t.dep;
    const status = minute < dep ? (t.delay > 5 ? `<span class="late">+${t.delay} min</span>` : '<span class="ok">En hora</span>') : minute < t.arrival ? `<span class="run">En marcha${t.delay > 5 ? ' · +' + t.delay : ''}</span>` : '<span>Llegado</span>';
    return `<div class="row"><span>${clock(dep)}</span><span>${chip(t.bus ? 'BUS' : code, t.bus ? '#c98a1c' : color)}</span><button class="dest" data-action="train" data-id="${esc(t.id)}">${esc(opts.dest ? opts.dest(t) : t.name)}${t.number ? ` <span class="muted">${esc(t.number)}</span>` : ''}</button><span>${status}</span></div>`;
  }).join('');
}

function opsPage() {
  const op = state.ops, trips = plan(), b = O.dayBounds(trips), m = currentMinute();
  const moving = trips.filter(t => m >= t.dep && m < t.arrival).length, done = trips.filter(t => t.arrival <= m), late = done.filter(t => t.delay > 5).length;
  const reached = op.incidents.filter(x => m >= x.at || op.phase === 'review');
  const next = trips.filter(t => t.dep >= m - 1).slice(0, 40);
  const kind = dayType();
  const head = header('Centro de control · ' + S.DAY_TYPES[kind], op.phase === 'planning' ? 'Prepara la jornada.' : op.phase === 'running' ? 'El día está en marcha.' : 'La jornada ha terminado.',
    `${O.dayLabel(state)}. Las circulaciones de las relaciones abiertas son las del horario oficial Renfe para un día ${kind === 'L' ? 'laborable' : kind === 'S' ? 'de sábado' : 'festivo'}. Tú decides cuántas se ofrecen y con qué material.`);
  const body = `<dl class="figures"><div><dt>Reloj</dt><dd class="mono">${clock(m)}</dd></div><div><dt>En circulación</dt><dd>${n(moving)}</dd></div><div><dt>Programadas</dt><dd>${n(trips.length)}</dd></div><div><dt>Puntualidad</dt><dd>${done.length ? n((1 - late / done.length) * 100) + ' %' : '—'}</dd></div><div><dt>Primera / última</dt><dd class="mono" style="font-size:19px">${clock(b.first)} · ${clock(b.last)}</dd></div></dl>
  ${reached.length ? `<h2 class="section">Incidencias</h2>${reached.map(x => {
    const r = state.routes.find(r => r.id === x.route), choice = op.choices?.[x.trip], solved = op.resolved.includes(x.trip);
    return `<div class="incident"><div class="split"><strong>${O.INCIDENT_TYPES[x.type]?.icon || '⚠'} ${esc(x.reason)}</strong><span class="status ${solved ? 'on' : 'late'}">${solved ? esc(O.RESPONSES[choice || 'team'].label) : 'Pendiente'}</span></div>
    <p>${esc(routeName(r))} · ${esc(x.label || '')}${x.place ? ' · cerca de ' + esc(x.place) : ''} · ${clock(x.at)} · demora estimada ${x.delay} min${x.type === 'weather' ? ' durante ' + Math.round(x.span / 60) + ' h' : ''}</p>
    ${solved || op.phase !== 'running' ? '' : `<div class="actions">${Object.entries(O.RESPONSES).map(([k, v]) => `<button class="btn small ${k === 'team' ? 'primary' : ''}" data-action="respond" data-id="${x.trip}" data-option="${k}" title="${esc(v.note)}">${esc(v.label)}${v.cost ? ' · ' + n(v.cost * 1000) + ' mil €' : ''}</button>`).join('')}</div>`}</div>`;
  }).join('')}` : ''}
  <div class="toolbar"><label style="margin:0">Prioridad de explotación</label><select id="dayPriority" ${op.phase !== 'planning' ? 'disabled' : ''}><option value="balanced" ${op.priority === 'balanced' ? 'selected' : ''}>Equilibrio entre coste y puntualidad</option><option value="punctual" ${op.priority === 'punctual' ? 'selected' : ''}>Refuerzo de puntualidad · 9.000 €/día</option></select>
  <label style="margin:0 0 0 auto"><input type="checkbox" id="autoPause" ${ui.autoPause ? 'checked' : ''}> Pausar ante incidencias</label></div>
  <h2 class="section">Próximas salidas</h2>
  <div class="board"><div class="row head"><span>Hora</span><span>Línea</span><span>Recorrido</span><span>Estado</span></div>${boardRows(next, m) || '<div class="row"><span></span><span></span><span>No quedan salidas programadas.</span></div>'}</div>
  ${!trips.length ? '<div class="empty">No hay servicios abiertos. Abre una línea en <b>Red</b> para empezar a circular.</div>' : ''}
  <p class="note">Los retrasos se derivan de incidencias simuladas, obras y la prioridad elegida. El horario de referencia es el publicado en octubre de 2026 para el tipo de día; la campaña lo usa como base desde 2022. Los ingresos se liquidan al cerrar el mes.</p>`;
  return [head, body];
}

function networkPage() {
  const q = ui.routeQuery.toLowerCase();
  const tabs = [['all', 'Todas'], ['av', 'Alta velocidad'], ['ld', 'Larga y media distancia']];
  const statuses = [['all', 'Cualquier estado'], ['active', 'En servicio'], ['closed', 'Por recuperar'], ['works', 'En obras']];
  let list = state.routes.filter(r => {
    if (ui.routeTab === 'av' && r.kind !== 'av') return false;
    if (ui.routeTab === 'ld' && !['intercity', 'regional'].includes(r.kind)) return false;
    if (ui.routeTab === 'commuter' && r.kind !== 'commuter') return false;
    const unlocked = E.isUnlocked(state, r);
    if (ui.routeStatus === 'active' && !r.active) return false;
    if (ui.routeStatus === 'closed' && (r.active || !unlocked)) return false;
    if (ui.routeStatus === 'works' && unlocked && !workOn(r)) return false;
    return !q || (routeName(r) + ' ' + (r.code || '') + ' ' + (r.products || []).join(' ')).toLowerCase().includes(q);
  });
  const row = r => {
    const [cls, label] = statusOf(r), m = r.active ? E.metrics(state, r) : null, trips = r.real ? (S.routeStats(r.id, 'L')?.trips || 0) : null;
    return `<tr class="clickable" data-action="route" data-id="${r.id}"><td>${routeChip(r)}</td><td><strong>${esc(routeName(r))}</strong><small>${r.km} km${r.stations ? ' · ' + r.stations + ' estaciones' : ''}${r.products?.length && !r.code ? ' · ' + esc(r.products.join(', ')) : ''}</small></td>
    <td class="num">${trips !== null ? n(trips) : '<span class="muted">—</span>'}</td><td><span class="status ${workOn(r) ? 'works' : cls}">${workOn(r) ? 'En obras' : label}</span>${r.active ? `<small>${r.frequency}/${r.real ? r.baseFrequency : r.frequency} por sentido</small>` : ''}</td>
    <td class="num">${m ? n(m.passengers) : '—'}</td><td class="num ${m ? (m.net >= 0 ? 'pos' : 'neg') : ''}">${m ? signed(m.net) : '—'}</td></tr>`;
  };
  const thead = '<thead><tr><th></th><th>Relación</th><th class="num">Trenes / día*</th><th>Estado</th><th class="num">Viajeros / mes</th><th class="num">Resultado</th></tr></thead>';
  let body = `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.routeTab === k ? 'active' : ''}" data-action="route-tab" data-id="${k}">${t}</button>`).join('')}</div>
  <div class="toolbar"><input type="search" id="routeSearch" placeholder="Buscar ciudad o producto (AVE, Alvia, MD…)" value="${esc(ui.routeQuery)}" aria-label="Buscar relación"><select id="routeStatus" aria-label="Estado">${statuses.map(([k, t]) => `<option value="${k}" ${ui.routeStatus === k ? 'selected' : ''}>${t}</option>`).join('')}</select></div>`;
  body += `<table>${thead}<tbody>${list.map(row).join('')}</tbody></table>`;
  if (!list.length) body += '<div class="empty">No hay relaciones que coincidan.</div>';
  body += `<p class="note">* Circulaciones publicadas por Renfe en un día laborable (GTFS de octubre de 2026), en ambos sentidos. Las relaciones sin cifra no tienen horario publicado (proyectos, servicios perdidos o líneas propias) y funcionan con un plan simulado. ${state.routes.length} relaciones en total.</p>`;
  return [header('Red y servicios', 'Cada línea, su horario.', 'Abre o ajusta servicios: material compatible, salidas por sentido sobre el horario oficial y tarifa media. Abrir un servicio cuesta 4 M€.'), body];
}

function timetablesPage() {
  const type = ui.ttType || dayType(), all = realTrips(type);
  const q = ui.ttStation.trim().toLowerCase();
  const fold = x => x.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase(), tokens = fold(q).split(/[^a-z0-9ñ]+/).filter(Boolean);
  const stations = q.length >= 2 ? S.STATIONS.filter(s => s.traffic && tokens.every(t => fold(s.name).includes(t))).sort((a, b) => b.traffic - a.traffic).slice(0, 12) : [];
  const station = stations.find(s => s.name.toLowerCase() === q) || (stations.length === 1 ? stations[0] : null) || (ui.ttStationId !== undefined ? S.STATIONS[ui.ttStationId] : null);
  let body = `<div class="tabs">${Object.entries(S.DAY_TYPES).map(([k, t]) => `<button class="${type === k ? 'active' : ''}" data-action="tt-type" data-id="${k}">${t} <span class="muted">${n(S.dayTrips(k).length)}</span></button>`).join('')}</div>
  <dl class="figures"><div><dt>Circulaciones</dt><dd>${n(all.length)}</dd></div><div><dt>Estaciones con servicio</dt><dd>${n(S.STATIONS.filter(s => s.traffic).length)}</dd></div><div><dt>Líneas y productos</dt><dd>${S.LINES.length}</dd></div><div><dt>Autobuses por obras</dt><dd>${n(all.filter(t => t.bus).length)}</dd></div></dl>
  <div class="toolbar"><input type="search" id="ttStation" placeholder="Busca una estación: Atocha, Sants, Abando, Xàtiva…" value="${esc(ui.ttStation)}" aria-label="Buscar estación"><label style="margin:0">Desde</label><select id="ttHour">${Array.from({length: 22}, (_, i) => i + 4).map(h => `<option value="${h}" ${ui.ttHour === h ? 'selected' : ''}>${String(h % 24).padStart(2, '0')}:00</option>`).join('')}</select></div>`;
  if (stations.length > 1 && !station) body += `<div class="rows">${stations.map(s => `<div><span class="chip" style="background:#2a1f1c">${n(s.traffic)}</span><div><h3>${esc(s.name)}</h3><p>Código ${esc(s.id)} · circulaciones en laborable</p></div><button class="btn small" data-action="tt-station" data-id="${s.i}">Ver salidas</button></div>`).join('')}</div>`;
  if (station) {
    const from = ui.ttHour * 60;
    const deps = [];
    for (const t of all) { const j = t.trip.stations.indexOf(station.i); if (j < 0 || j === t.trip.stations.length - 1) continue; const dep = t.trip.times[j * 2 + 1]; if (dep >= from) deps.push({t, dep}); }
    deps.sort((a, b) => a.dep - b.dep);
    body += `<div class="group-title"><h2>${esc(station.name)}</h2><span>${n(deps.length)} salidas desde las ${String(ui.ttHour).padStart(2, '0')}:00</span><button class="btn small" data-action="station-map" data-id="${station.i}">Ver en el mapa</button></div>
    <div class="board"><div class="row head"><span>Salida</span><span>Línea</span><span>Destino</span><span>Tren</span></div>${deps.slice(0, 80).map(({t, dep}) => `<div class="row"><span>${clock(dep)}</span><span>${chip(t.bus ? 'BUS' : S.lineCode(t.line), t.bus ? '#c98a1c' : S.LINES[t.line].color)}</span><button class="dest" data-action="real-trip" data-id="${t.id}">${esc(S.STATIONS[t.trip.stations.at(-1)].name)}</button><span>${esc(t.trip.number || '—')}</span></div>`).join('')}</div>${deps.length > 80 ? '<p class="note">Se muestran 80 salidas. Cambia la hora para ver más.</p>' : ''}`;
  }
  if (!station && stations.length === 0) {
    const counts = {};
    for (const t of all) counts[t.line] = (counts[t.line] || 0) + 1;
    body += `<h2 class="section">Líneas y productos del día</h2><div class="rows">${Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([line, c]) => {
      const L = S.LINES[line];
      return `<div>${chip(S.lineCode(line), L.color)}<div><h3>${esc(L.net ? networkName(L.net) + ' · ' + L.code : L.code)}</h3><p>${esc(L.name)}</p></div><span class="num"><b>${n(c)}</b> <span class="muted">circ.</span></span></div>`;
    }).join('')}</div>`;
  }
  body += `<h2 class="section">Fuente y alcance</h2><p class="small">Horario oficial de Renfe (GTFS de Cercanías y de AV/LD/MD, CC BY 4.0) publicado el ${esc(S.META.snapshot)}, procesado para tres días tipo: laborable ${esc(S.META.days.L)}, sábado ${esc(S.META.days.S)} y domingo ${esc(S.META.days.D)}. Incluye las circulaciones por carretera que Renfe publica como servicio alternativo por obras. El GTFS no informa del material asignado ni de la matrícula.</p>
  <h2 class="section">Importar otro GTFS</h2><p class="small">Puedes cargar un ZIP GTFS completo (por ejemplo, una versión más reciente) para consultarlo. Se lee en tu navegador; no altera la campaña.</p>
  <div class="toolbar"><input id="gtfsImport" type="file" accept=".zip,application/zip"><span id="gtfsProgress" class="small"></span></div>
  ${referenceFeed ? referenceTable() : ''}`;
  return [header('Horarios oficiales', 'Todos los trenes, a su hora.', 'Busca una estación para ver su panel de salidas real, o recorre las líneas del día. Cada circulación se puede seguir en el mapa.'), body];
}
function referenceTable() {
  const trips = G.scheduleFor(referenceFeed, referenceDate).filter(t => !referenceQuery || (t.name + ' ' + t.id + ' ' + (t.headsign || '')).toLowerCase().includes(referenceQuery.toLowerCase()));
  return `<div class="toolbar"><strong>${esc(referenceFeed.name)}</strong><input type="date" id="referenceDate" value="${referenceDate}" min="${G.dateISO(referenceFeed.dateStart)}" max="${G.dateISO(referenceFeed.dateEnd)}"><input type="search" id="referenceSearch" placeholder="Filtrar" value="${esc(referenceQuery)}"></div>
  <table><thead><tr><th>Salida</th><th>Línea</th><th>Destino</th><th>Llegada</th></tr></thead><tbody>${trips.slice(0, 150).map(t => `<tr><td class="mono">${t.approximate ? 'cada ' + n(t.frequency.headway) + ' min' : clock(t.dep)}</td><td>${esc(t.name)}<small>${esc(t.id)}</small></td><td>${esc(t.headsign || t.stops?.at(-1)?.name || '')}</td><td class="mono">${t.arrival === null ? '—' : clock(t.arrival)}</td></tr>`).join('')}</tbody></table><p class="note">${n(trips.length)} circulaciones en la fecha; se muestran hasta 150.</p>`;
}

function fleetPage() {
  const tabs = [['fleet', 'Parque'], ['workshop', 'Talleres'], ['atlas', 'Atlas de series']];
  let body = `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.fleetTab === k ? 'active' : ''}" data-action="fleet-tab" data-id="${k}">${t}</button>`).join('')}</div>`;
  if (ui.fleetTab === 'fleet') {
    const total = state.fleet.reduce((v, f) => v + f.qty, 0), free = state.fleet.reduce((v, f) => v + E.available(state, f), 0);
    body += `<dl class="figures"><div><dt>Unidades</dt><dd>${n(total)}</dd></div><div><dt>Asignadas</dt><dd>${n(total - free)}</dd></div><div><dt>Libres</dt><dd>${n(free)}</dd></div><div><dt>En taller</dt><dd>${n(state.refits.filter(r => !r.done).reduce((v, r) => v + r.qty, 0))}</dd></div></dl>
    <table><thead><tr><th style="width:150px"></th><th>Material</th><th class="num">Parque</th><th class="num">Libres</th><th>Estado</th></tr></thead><tbody>${state.fleet.filter(f => f.qty > 0).map(f => {
      const m = MODEL[f.model];
      return `<tr class="clickable" data-action="fleet-detail" data-id="${f.id}"><td>${trainThumb(f.model)}</td><td><strong>${esc(m.name)}</strong><small>${esc(f.origin)} · desde ${f.born} · ${GAUGES[m.gauge]} · ${POWERS[m.power] || m.power}</small></td><td class="num">${f.qty}</td><td class="num">${E.available(state, f)}</td><td style="min-width:120px"><div class="bar ${f.condition < 50 ? '' : 'green'}"><span style="width:${f.condition}%"></span></div><small>${n(f.condition)} %</small></td></tr>`;
    }).join('')}</tbody></table><p class="note">Las unidades asignadas a una línea no pueden venderse ni entrar en taller. Libéralas reduciendo salidas o suspendiendo el servicio. Las unidades necesarias se calculan con el pico de trenes simultáneos del horario oficial.</p>`;
  } else if (ui.fleetTab === 'workshop') {
    body += state.refits.length ? `<div class="rows">${state.refits.map(r => `<div><span class="status ${r.done ? 'on' : 'works'}"></span><div><h3>${esc(MODEL[r.model].name)} · ${r.qty} unidades</h3><p>${r.done ? 'Reforma completada' : 'Salida prevista: ' + E.dateOf(r.due)}</p></div><span></span></div>`).join('')}</div>` : '<div class="empty">No hay trenes en reforma. Elige un lote con unidades libres en Parque.</div>';
    body += '<p class="note">Una reforma cuesta el 12 % del precio base y dura 5 meses. Devuelve el estado al 98 % conservando la edad del vehículo.</p>';
  } else {
    const records = REAL_TRAIN_CATALOGUE.filter(t => !ui.trainQuery || [t.series, t.name, t.category, t.builder].join(' ').toLowerCase().includes(ui.trainQuery.toLowerCase()));
    body += `<div class="toolbar"><input type="search" id="trainSearch" placeholder="Serie, fabricante o familia" value="${esc(ui.trainQuery)}"></div><table><thead><tr><th style="width:150px"></th><th>Serie</th><th>Familia</th><th class="num">Velocidad</th><th class="num">Plazas</th></tr></thead><tbody>${records.map(t => `<tr class="clickable" data-action="train-record" data-id="${t.id}"><td>${trainThumb(t.series || t.id)}</td><td><strong>${esc(t.series || t.name)}</strong><small>${esc(t.name || '')}</small></td><td>${esc(t.category || '')}<small>${esc(t.builder || '')}</small></td><td class="num">${t.maxSpeedKmH?.length ? t.maxSpeedKmH.join('/') + ' km/h' : '—'}</td><td class="num">${t.seatedCapacity?.length ? t.seatedCapacity.join('/') : '—'}</td></tr>`).join('')}</tbody></table><p class="note">Fichas documentales de series y programas (Renfe Data 2020 y fuentes posteriores). No equivalen a unidades físicas ni a asignaciones diarias.</p>`;
  }
  return [header('Flota y talleres', 'Los trenes que hacen posible la red.'), body];
}

function marketPage() {
  const tabs = [['catalogue', 'Catálogo'], ['orders', 'Mis pedidos'], ['historical', 'Contratos históricos']];
  let body = `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.marketTab === k ? 'active' : ''}" data-action="market-tab" data-id="${k}">${t}</button>`).join('')}</div>`;
  if (ui.marketTab === 'catalogue') {
    body += `<div class="catalogue">${MODELS.map(m => {
      const unlocked = E.yearOf(state) >= m.year, q = E.purchaseQuote(state, m.id, 1);
      return `<div>${trainThumb(m.id)}<div><h3>${esc(m.name)}</h3><p>${esc(m.desc)}</p><div class="specline"><span><b>${m.speed}</b> km/h</span><span><b>${n(m.seats)}</b> plazas*</span><span>${GAUGES[m.gauge]}</span><span>${POWERS[m.power] || m.power}</span><span>plazo base <b>${m.lead}</b> meses</span><span>${esc(m.maker)}</span></div></div>
      <div style="text-align:right"><strong style="font:600 20px var(--serif)">${money(q.total)}</strong><br><button class="btn small ${unlocked ? 'primary' : ''}" data-action="purchase" data-id="${m.id}" ${!unlocked || state.ended ? 'disabled' : ''}>${unlocked ? 'Encargar' : 'Desde ' + m.year}</button></div></div>`;
    }).join('')}</div><p class="note">* Capacidad de simulación; en Cercanías incluye plazas de pie. Precios y plazos son parámetros del juego; anticipo del 30 % y saldo a la entrega de cada lote.</p>`;
  } else if (ui.marketTab === 'orders') {
    const orders = state.orders.filter(o => !o.historical);
    body += orders.length ? `<div class="rows">${orders.map(o => `<div><span class="status ${o.delivered === o.qty ? 'on' : 'works'}"></span><div><h3>${esc(MODEL[o.model].name)} · ${o.qty} unidades</h3><p>${o.delivered === o.qty ? 'Pedido completado' : 'Próximo lote: ' + E.dateOf(o.next)}${o.delay ? ' · retraso acumulado ' + o.delay + ' meses' : ''} · ${money(o.remaining)} pendiente</p><div class="bar gold"><span style="width:${o.delivered / o.qty * 100}%"></span></div></div><span class="num">${o.delivered}/${o.qty}</span></div>`).join('')}</div>` : '<div class="empty">Aún no has encargado trenes.</div>';
  } else {
    body += `<table><thead><tr><th>Contrato o programa</th><th class="num">Unidades</th><th>En tu partida</th></tr></thead><tbody>${HISTORICAL_ORDERS.map(h => {
      const o = state.orders.find(x => x.id === h.id);
      return `<tr><td><strong>${esc(h.name)}</strong><small>${esc(h.note)} ${sourceLink(h.source)}</small></td><td class="num">${h.qty}</td><td>${h.signed > state.month ? 'Futuro · ' + (2022 + Math.floor(h.signed / 12)) : h.tender ? 'Licitación' : !h.model ? 'Registro documental' : `${o?.delivered || 0}/${h.qty} recibidos`}</td></tr>`;
    }).join('')}</tbody></table><p class="note">Contratos reales identificados. Su financiación queda fuera de tu caja de campaña; las entregas mensuales se simulan.</p>`;
  }
  return [header('Compras de material', 'Un buen pedido se hace con tiempo.', 'Plazos de unos dos años, variables según la carga de los fabricantes y los retrasos de homologación.'), body];
}

function worksPage() {
  let body = `<div class="toolbar"><button class="btn primary" data-action="new-line">Proponer una línea nueva</button><button class="btn" data-action="layer" data-id="works">Ver todas las obras en el mapa</button></div>`;
  body += `<div class="rows">${PROJECTS.map(p => {
    const job = state.projects.find(j => j.id === p.id), st = job ? O.constructionStatus(state, job) : null;
    return `<div><span class="status ${job ? (job.done ? 'on' : 'works') : 'off'}"></span><div><h3>${esc(p.name)}</h3><p>${esc(p.region)} · ${esc(p.desc)}</p>${job ? `<div class="bar gold" style="margin-top:8px"><span style="width:${st.progress * 100}%"></span></div><p class="small">${job.done ? 'En servicio en tu partida' : st.stage + ' · ' + n(st.progress * 100) + ' % · fin previsto ' + E.dateOf(job.due) + (job.delay ? ' · +' + job.delay + ' meses de retraso' : '')}</p>` : `<p class="small muted">${esc(p.status)} Plazo de juego: ${p.duration} meses, no antes de ${p.earliest}.</p>`}</div>
    <div style="text-align:right;white-space:nowrap">${job ? `<button class="btn small" data-action="visit-work" data-id="${p.id}">Visitar obra</button>` : `<strong>${money(p.cost)}</strong><br><button class="btn small primary" data-action="project" data-id="${p.id}" ${state.ended ? 'disabled' : ''}>Financiar</button>`}<br><span class="small">${sourceLink(p.source)}</span></div></div>`;
  }).join('')}</div>`;
  const custom = state.projects.filter(p => p.type === 'custom'), upgrades = state.projects.filter(p => p.type === 'upgrade' && !p.done);
  if (custom.length) body += `<h2 class="section">Tus líneas nuevas</h2><div class="rows">${custom.map(p => { const r = state.routes.find(r => r.id === p.route); return `<div><span class="status ${p.done ? 'on' : 'works'}"></span><div><h3>${esc(routeName(r))}</h3><p>${p.done ? 'Disponible: asigna material.' : 'Fin previsto ' + E.dateOf(p.due)}</p></div><button class="btn small" data-action="route" data-id="${p.route}">Ver</button></div>`; }).join('')}</div>`;
  if (upgrades.length) body += `<h2 class="section">Mejoras de servicio en curso</h2><div class="rows">${upgrades.map(p => { const r = state.routes.find(r => r.id === p.route); return `<div><span class="status works"></span><div><h3>${esc(routeName(r))}</h3><p>Información, accesibilidad y fiabilidad · fin ${E.dateOf(p.due)}</p></div><span></span></div>`; }).join('')}</div>`;
  body += '<p class="note">El importe es tu aportación de campaña, no el coste real de la obra. Las fases y su avance sobre el trazado son simulados; los proyectos y su situación documental tienen fuente.</p>';
  return [header('Infraestructura', 'Las vías del próximo capítulo.', 'Negocia con Adif prioridades y cofinanciación. Acércate en el mapa para ver cada fase sobre el trazado.'), body];
}

function financePage() {
  const b = E.balance(state), commit = state.orders.filter(o => !o.historical).reduce((v, o) => v + o.remaining, 0);
  const body = `<dl class="figures"><div><dt>Tesorería</dt><dd>${money(state.cash)}</dd></div><div><dt>Resultado mensual</dt><dd class="${b.net >= 0 ? 'pos' : 'neg'}">${signed(b.net)}</dd></div><div><dt>Deuda</dt><dd>${money(state.debt)}</dd></div><div><dt>Pedidos pendientes</dt><dd>${money(commit)}</dd></div></dl>
  <h2 class="section">Cuenta de explotación del mes</h2><table><tbody>${[['Venta de billetes', b.revenue], ['Obligación de servicio público y apoyo', b.subsidy], ['Operación, canon, mantenimiento y estructura', -b.cost], ['Resultado previsto', b.net]].map(([t, v], i) => `<tr><td>${i === 3 ? '<strong>' + t + '</strong>' : t}</td><td class="num ${v >= 0 ? 'pos' : 'neg'}">${i === 3 ? '<strong>' + signed(v) + '</strong>' : signed(v)}</td></tr>`).join('')}</tbody></table>
  <h2 class="section">Evolución de la tesorería</h2><canvas id="cashChart" class="chart" role="img" aria-label="Gráfico de tesorería mensual"></canvas>
  <h2 class="section">Financiación y mantenimiento</h2><div class="toolbar"><button class="btn" data-action="borrow" ${state.debt >= 1500 || state.ended ? 'disabled' : ''}>Solicitar 100 M€</button><button class="btn" data-action="repay" ${state.debt < 100 || state.cash < 100 || state.ended ? 'disabled' : ''}>Amortizar 100 M€</button></div>
  <label for="maintenance">Esfuerzo de mantenimiento: <strong>${n(state.maintenance * 100)} %</strong></label><input id="maintenance" type="range" min="0.6" max="1.5" step="0.1" value="${state.maintenance}" ${state.ended ? 'disabled' : ''}>
  <p class="note">Cifras de simulación en millones de euros. El coste por tren-km incluye energía, personal, canon de Adif y mantenimiento; la compensación de servicio público se paga por tren-km en Cercanías y Media Distancia. No reproduce la contabilidad real de Renfe.</p>`;
  return [header('Finanzas', 'Que las cuentas también lleguen.'), body];
}
function drawChart() {
  const el = $('cashChart'); if (!el) return;
  const w = el.clientWidth || 700, h = 190, dpr = 2; el.width = w * dpr; el.height = h * dpr;
  const c = el.getContext('2d'); c.scale(dpr, dpr);
  const data = state.history.map(x => x.cash);
  c.font = '11px Figtree'; c.fillStyle = '#8a7c69';
  if (data.length < 2) { c.fillText('La gráfica aparece al cerrar el primer mes.', 8, 30); return; }
  const min = Math.min(0, ...data), max = Math.max(100, ...data), y = v => h - 22 - (v - min) / (max - min || 1) * (h - 40);
  c.strokeStyle = 'rgba(74,56,36,.15)';
  for (let i = 0; i <= 3; i++) { const v = min + (max - min) / 3 * i; c.beginPath(); c.moveTo(48, y(v)); c.lineTo(w, y(v)); c.stroke(); c.fillText(n(v), 0, y(v) + 4); }
  const g = c.createLinearGradient(0, 0, 0, h); g.addColorStop(0, 'rgba(138,42,70,.3)'); g.addColorStop(1, 'rgba(138,42,70,0)');
  c.beginPath(); data.forEach((v, i) => { const x = 50 + i / (data.length - 1) * (w - 55); i ? c.lineTo(x, y(v)) : c.moveTo(x, y(v)); });
  c.strokeStyle = '#8a2a46'; c.lineWidth = 2; c.stroke(); c.lineTo(w - 5, h - 22); c.lineTo(50, h - 22); c.fillStyle = g; c.fill();
}

function storyPage() {
  const c = CHAPTERS[state.chapter], person = CHARACTERS[c.speaker], score = E.finalScore(state);
  const body = `${state.ended ? `<div class="callout"><strong>${state.ending === '2050' ? '31 de diciembre de 2050' : 'Intervención de la compañía'}</strong><br>Tu legado: <b>${score}/100</b>. ${state.routes.filter(r => r.active).length} servicios, ${n(E.dailyTrains(state))} circulaciones diarias, ${n(state.stats.passengers / 1e6, 1)} millones de viajes.</div>` : ''}
  <div class="chapters">${CHAPTERS.map((ch, i) => `<div class="${state.claimed.includes(ch.id) ? 'done' : i === state.chapter ? 'now' : ''}"><strong>${esc(ch.title)}</strong>${ch.years}</div>`).join('')}</div>
  <div class="story"><div class="portrait p${person.portrait}" role="img" aria-label="${esc(person.name)}"></div><div><div class="kicker" style="color:var(--wine);font-weight:700;font-size:11.5px;letter-spacing:1.4px;text-transform:uppercase">${esc(person.name)} · personaje ficticio</div><h2 class="section" style="margin-top:4px">${esc(c.title)} ${sayButton(c.speaker, 'story')}</h2><p data-say="${esc(c.text)}">${sayHtml(c.text)}</p>
  <ul class="objectives">${c.objectives.map(([k, target, title]) => { const v = E.objectiveValue(state, k); return `<li class="${v >= target ? 'done' : ''}"><i></i><span>${esc(title)}</span><span class="num">${k === 'solvent' ? (v ? '✓' : '—') : n(Math.min(v, target)) + ' / ' + n(target)}</span></li>`; }).join('')}</ul>
  <div class="toolbar"><button class="btn primary" data-action="claim" ${!E.chapterReady(state) || state.ended ? 'disabled' : ''}>${state.claimed.includes(c.id) ? 'Capítulo completado' : 'Reclamar ' + c.reward + ' M€'}</button><button class="btn" data-action="navigate" data-screen="network">Gestionar la red</button></div>
  ${E.yearOf(state) < c.year ? `<p class="callout">Esta etapa comienza en ${c.year}. Puedes preparar sus objetivos mientras tanto.</p>` : ''}</div></div>
  <div class="toolbar" style="margin-top:30px"><button class="btn" data-action="save-dialog">Guardar o exportar</button><button class="btn danger" data-action="new-game">Nueva campaña</button></div>`;
  return [header('Campaña 2022–2050', 'Tu mandato, tu historia.', 'Cada capítulo desbloquea financiación para el siguiente. Las escenas políticas y sus personajes son ficción.'), body];
}

function archivePage() {
  const tabs = [['sources', 'Fuentes'], ['method', 'Qué es real'], ['journal', 'Diario']];
  let body = `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.archiveTab === k ? 'active' : ''}" data-action="archive-tab" data-id="${k}">${t}</button>`).join('')}</div>`;
  if (ui.archiveTab === 'journal') body += state.log.map(l => `<div class="news"><time>${E.dateOf(l.month)}</time><div><h3>${esc(l.title)}</h3><p>${esc(l.body)}</p></div></div>`).join('');
  else if (ui.archiveTab === 'method') body += `<ul class="method">
  <li><strong>Horarios reales:</strong> todas las circulaciones publicadas por Renfe en sus GTFS oficiales de Cercanías/Rodalies y de AV/LD/MD (copia del ${esc(S.META.snapshot)}), para un laborable, un sábado y un domingo: ${n(S.META.counts.L)}, ${n(S.META.counts.S)} y ${n(S.META.counts.D)} circulaciones, incluidos los autobuses alternativos por obras. Son horarios de 2026: la campaña los usa como base desde 2022 y no reconstruye la oferta histórica de cada año. Los festivos nacionales usan el horario de domingo; los autonómicos y locales no se modelan.</li>
  <li><strong>Trazados:</strong> ${n(S.META.geometry.shape)} tramos siguen los shapes del GTFS de Cercanías y ${n(S.META.geometry.osm)} se calculan sobre la red OSM (abril de 2026) según ancho y velocidad del producto. ${n(S.META.geometry.straight)} tramos sin continuidad en el extracto (vía estrecha, Francia) se dibujan como enlace aproximado discontinuo y ${n(S.META.geometry.road)} son recorridos por carretera.</li>
  <li><strong>Movimiento:</strong> la posición entre dos paradas se interpola sobre el trazado con aceleración y frenado. No es un sistema de señalización ni de ocupación de vía.</li>
  <li><strong>Material y unidades:</strong> el GTFS no informa del material. Las unidades necesarias se estiman con el pico de trenes simultáneos de cada relación. Parque inicial, compras y estados son de juego.</li>
  <li><strong>Premisa ficticia:</strong> la escasez inicial y los cierres de 2022 son ficción de campaña. Economía, demanda, incidencias, obras y 2027–2050 son simulación.</li>
  <li><strong>Luz:</strong> la iluminación sigue la altura del sol calculada para la fecha, la hora oficial peninsular y la longitud de cada parte del mapa. Las luces urbanas se escalan con la población y el tráfico ferroviario.</li>
  <li><strong>Relieve y ríos:</strong> ilustración esquemática orientativa, no cartografía.</li>
  <li><strong>Personajes:</strong> Pedro Sancho, Raquel Sanz y Óscar del Puente son caricaturas originales con nombres y diálogos inventados.</li></ul>
  <p class="note">Licencias: horarios Renfe Data (CC BY 4.0); vías © OpenStreetMap contributors (ODbL 1.0); contornos de España y Portugal georgique/world-geojson (GPL-3.0) y Natural Earth (dominio público); tipografías Fraunces, Figtree e IBM Plex Mono (SIL OFL 1.1).</p><button class="btn" data-action="license">Licencia cartográfica</button>`;
  else body += `<div class="rows">${[...S.META.sources.map(s => ({title: s.name, url: s.url, note: s.license || ''})), ...SOURCES].map(s => `<div><span class="status on"></span><div><h3><a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.title)}</a></h3><p>${esc(s.note || '')}</p></div><span></span></div>`).join('')}</div>`;
  return [header('Archivo', 'Lo que hay detrás de la historia.', 'Hechos, previsiones y ficción, separados.'), body];
}

// ------------------------------------------------------------ inspector
function renderInspector() {
  const el = $('inspector');
  renderMission();
  if (!inspect) { el.classList.add('hidden'); map.selected = null; map.selectedCity = null; return; }
  if (inspect.type !== 'city') map.selectedCity = null;
  const fn = {route: routeInspector, train: trainInspector, station: stationInspector, work: workInspector, city: cityInspector}[inspect.type];
  const out = fn?.();
  if (!out) { inspect = null; el.classList.add('hidden'); return; }
  const scroll = el.querySelector('.body')?.scrollTop || 0;
  el.classList.toggle('wide', out.cls === 'city');
  el.innerHTML = out.cls === 'city' ? `<button class="close floating" data-action="close-inspector" aria-label="Cerrar">×</button><div class="body city-body">${out.body}</div>` : `<header><div><div class="kicker">${out.kicker}</div><h2>${out.title}</h2></div><button class="close" data-action="close-inspector" aria-label="Cerrar">×</button></header><div class="body">${out.body}</div>`;
  el.classList.remove('hidden');
  el.querySelector('.body').scrollTop = scroll;
  if (inspect.type === 'route') updatePreview();
  if (inspect.type === 'train') mountViewers(el);
}
function hourHistogram(trips, minute) {
  const hours = new Array(24).fill(0);
  for (const t of trips) hours[Math.floor(t.dep / 60) % 24]++;
  const order = [...Array(24).keys()].map(i => (i + 4) % 24), max = Math.max(1, ...hours), now = Math.floor(minute / 60) % 24;
  return `<div class="hist">${order.map(h => `<i class="${h === now ? 'now' : ''}" style="height:${hours[h] / max * 100}%" title="${String(h).padStart(2, '0')}:00 · ${hours[h]}"></i>`).join('')}</div><div class="axis"><span>04</span><span>08</span><span>12</span><span>16</span><span>20</span><span>00</span><span>03</span></div>`;
}
function routeInspector() {
  const r = state.routes.find(r => r.id === inspect.id);
  if (!r) return null;
  map.selected = r.id;
  const unlocked = E.isUnlocked(state, r), [cls, label] = statusOf(r), work = workOn(r), stats = r.real ? S.routeStats(r.id, dayType()) || S.routeStats(r.id, 'L') : null;
  const compatible = state.fleet.filter(f => f.qty > 0 && E.compatible(r, MODEL[f.model]));
  const maxF = E.maxFrequency(r), freq = r.active ? r.frequency : Math.max(1, Math.round(maxF * (r.real ? .5 : .25)));
  const todays = r.real ? S.thin(S.routeTrips(dayType(), r.id), r.active ? Math.min(1, r.frequency / r.baseFrequency) : 1) : [];
  const m = E.metrics(state, r);
  let body = `<p><span class="status ${work ? 'works' : cls}">${work ? 'En obras · ' + O.constructionStatus(state, work).stage : label}</span></p>
  <dl class="figures"><div><dt>Horario oficial</dt><dd>${r.real ? n(stats?.trips || 0) : '—'}</dd><em>${r.real ? 'circulaciones · ' + S.DAY_TYPES[dayType()].toLowerCase() : 'sin horario publicado'}</em></div><div><dt>Longitud</dt><dd>${r.km} km</dd></div>${r.real ? `<div><dt>Trayecto</dt><dd>${clock(r.minutes).replace(/^0/, '')} h</dd></div><div><dt>Pico</dt><dd>${r.peak}</dd><em>trenes a la vez</em></div>` : `<div><dt>Velocidad</dt><dd>${r.speed}</dd><em>km/h</em></div>`}</dl>
  ${r.real ? `<h3>Salidas a lo largo del día ${r.active ? '(tu oferta)' : '(horario oficial)'}</h3>${hourHistogram(todays.map(t => ({dep: t.start})), currentMinute())}` : ''}`;
  if (!unlocked) body += `<p class="callout">${r.project ? 'Necesita terminar la obra asociada.' : 'Disponible a partir de ' + (r.availableFrom || E.dateOf(r.unlock)) + '.'}</p><button class="btn" data-action="navigate" data-screen="works">Ver obras</button>`;
  else body += `<h2 class="section">Plan de servicio</h2><form id="routeForm">
    <label for="routeFleet">Material asignado</label><select id="routeFleet" required style="width:100%">${compatible.length ? compatible.map(f => `<option value="${f.id}" ${r.fleet === f.id ? 'selected' : ''}>${esc(MODEL[f.model].name)} · ${E.available(state, f, r.id)} libres · ${n(f.condition)} %</option>`).join('') : '<option value="">No hay material compatible</option>'}</select>
    <label for="frequency">Salidas por sentido: <strong id="freqOut">${freq}</strong> de ${maxF}${r.real ? ' del horario oficial' : ''}</label><input id="frequency" type="range" min="1" max="${maxF}" step="1" value="${freq}">
    <label for="fare">Tarifa media (€)</label><input id="fare" type="number" min="1.5" max="150" step="0.1" value="${r.fare}" style="width:120px">
    <p id="routePreview" class="callout"></p>
    <div class="toolbar"><button class="btn primary" type="submit" ${!compatible.length || state.ended ? 'disabled' : ''}>${r.active ? 'Aplicar plan' : 'Reabrir servicio · 4 M€'}</button>${r.active ? `<button class="btn danger" type="button" data-action="close-service" data-id="${r.id}">Suspender</button>` : ''}</div></form>
    <div class="toolbar"><button class="btn small" data-action="upgrade" data-id="${r.id}" ${r.level >= 3 || state.ended ? 'disabled' : ''}>Mejorar servicio · ${12 + 12 * r.level} M€</button><span class="small muted">Nivel ${r.level}/3</span></div>`;
  body += `<h2 class="section">Frente a la carretera</h2><div class="shares"><span style="width:${m.share * 100}%;background:var(--wine)"></span><span style="width:${m.busShare * 100}%;background:var(--gold-2)"></span><span style="width:${m.otherShare * 100}%;background:var(--paper-3)"></span></div>
  <div class="shares-legend"><span><i style="background:var(--wine)"></i>Renfe ${n(m.share * 100)} %</span><span><i style="background:var(--gold-2)"></i>Autobús (Alsa) ${n(m.busShare * 100)} %</span><span><i style="background:var(--paper-3)"></i>Coche y otros ${n(m.otherShare * 100)} %</span></div>
  ${r.active ? `<dl class="figures"><div><dt>Viajeros / mes</dt><dd>${n(m.passengers)}</dd></div><div><dt>Ocupación</dt><dd>${n(m.occupancy * 100)} %</dd></div><div><dt>Resultado</dt><dd class="${m.net >= 0 ? 'pos' : 'neg'}">${signed(m.net)}</dd></div></dl>` : ''}
  ${work ? `<h2 class="section">Obra en la línea</h2><div class="bar gold"><span style="width:${O.constructionStatus(state, work).progress * 100}%"></span></div><p class="small">${O.constructionStatus(state, work).stage} · fin previsto ${E.dateOf(work.due)}</p><button class="btn small" data-action="visit-work" data-id="${work.id}">Visitar la obra</button>` : ''}
  <div class="toolbar">${r.real ? `<button class="btn small" data-action="route-trips" data-id="${r.id}">Ver sus circulaciones</button>` : ''}<button class="btn small" data-action="route-zoom" data-id="${r.id}">Encuadrar</button></div>
  <p class="note">${r.real ? 'Horario y paradas: GTFS oficial de Renfe. Al reducir la oferta se mantienen circulaciones reales repartidas a lo largo del día. Demanda, cuotas y cuentas son simulación.' : 'Relación sin horario publicado: el plan de circulación es simulado' + (r.custom ? ' y el trazado, conceptual.' : '.')}</p>`;
  return {kicker: esc(kindLabel(r)), title: `${routeChip(r)} ${esc(routeName(r))}`, body};
}
function updatePreview() {
  const r = state.routes.find(r => r.id === inspect?.id), f = state.fleet.find(f => f.id === $('routeFleet')?.value), out = $('routePreview');
  if (!r || !out) return;
  const freq = +$('frequency').value;
  $('freqOut').textContent = freq;
  if (!f) { out.textContent = 'No hay material compatible con el ancho y la electrificación de esta línea.'; return; }
  const m = MODEL[f.model], units = E.requiredUnits(r, m, freq), b = E.metrics(state, r, {active: true, fleet: f.id, frequency: freq, fare: +$('fare').value, units});
  out.innerHTML = `${units} unidad${units === 1 ? '' : 'es'} necesaria${units === 1 ? '' : 's'} · ${E.available(state, f, r.id)} libre${E.available(state, f, r.id) === 1 ? '' : 's'}<br>${n(freq * 2)} circulaciones al día · ${n(b.passengers)} viajeros/mes · <strong class="${b.net >= 0 ? 'pos' : 'neg'}">${signed(b.net)}/mes</strong>`;
}
function findTrip(id) {
  return plan().find(t => t.id === id) || realTrips(dayType()).find(t => t.id === id) || (String(id).match(/^[LSD]\d+$/) ? realTrips(id[0]).find(t => t.id === id) : null);
}
function trainInspector() {
  const t = findTrip(inspect.id);
  if (!t) return null;
  const minute = currentMinute(), r = state.routes.find(r => r.id === t.route), line = t.line !== undefined && t.line !== null ? S.LINES[t.line] : null;
  const color = t.bus ? '#c98a1c' : line?.color || (r ? routeColor(r) : '#8a2a46');
  let stops = '';
  if (t.trip) {
    const list = S.tripStops(t.trip, t.delay || 0);
    let here = -1;
    list.forEach((s, j) => { if (minute >= s.arr) here = j; });
    stops = `<ul class="stops" style="--line-color:${color}">${list.map((s, j) => `<li class="${j < here ? 'past' : j === here ? 'here' : ''}"><time>${clock(j ? s.arr : s.dep)}</time><button class="dest" style="all:unset;cursor:pointer" data-action="station" data-id="${s.station.i}">${esc(s.station.name)}</button></li>`).join('')}</ul>`;
  }
  const pos = t.trip ? S.position(t.trip, minute, t.delay || 0) : null;
  const where = !pos ? (minute < t.dep ? 'Sale a las ' + clock(t.dep + (t.delay || 0)) : 'Ha llegado a destino') : pos.stopped ? 'Detenido en ' + S.STATIONS[t.trip.stations[pos.at]].name : 'Hacia ' + S.STATIONS[t.trip.stations[pos.next]].name;
  const body = `<div class="train3d" data-train3d="${tripArtKey(t, r)}"></div>
  <dl class="figures"><div><dt>Estado</dt><dd style="font-size:17px">${esc(where)}</dd></div><div><dt>Retraso</dt><dd class="${t.delay > 5 ? 'neg' : 'pos'}">${t.delay ? '+' + t.delay + ' min' : 'En hora'}</dd></div></dl>
  <p class="small">${esc(t.model || (t.bus ? 'Autobús de sustitución' : 'Material no publicado en el GTFS'))}${r ? ' · ' + esc(routeName(r)) : ''}</p>
  <div class="toolbar"><button class="btn small ${map.follow ? 'primary' : ''}" data-action="follow">${map.follow ? 'Siguiendo al tren' : 'Seguir en el mapa'}</button>${r ? `<button class="btn small" data-action="route" data-id="${r.id}">Gestionar la línea</button>` : ''}</div>
  ${stops}<p class="note">${t.trip ? 'Paradas y horas del horario oficial' + (t.delay ? ', desplazadas por el retraso de la jornada.' : '.') : 'Circulación de un plan simulado.'}</p>`;
  return {kicker: t.bus ? 'Autobús alternativo' : 'Circulación ' + esc(t.number || ''), title: `${chip(t.bus ? 'BUS' : (t.line !== undefined && t.line !== null ? S.lineCode(t.line) : r?.code || 'R'), color)} ${esc(t.name)}`, body};
}
function stationInspector() {
  const st = S.STATIONS[inspect.id];
  if (!st) return null;
  const minute = currentMinute(), trips = layer === 'real' || state.ops.phase !== 'running' ? realTrips(dayType()) : plan();
  const deps = [];
  for (const t of trips) {
    if (!t.trip) continue;
    const j = t.trip.stations.indexOf(st.i);
    if (j < 0 || j === t.trip.stations.length - 1) continue;
    const dep = t.trip.times[j * 2 + 1] + (t.delay || 0);
    if (dep >= minute - 1) deps.push({t, dep});
  }
  deps.sort((a, b) => a.dep - b.dep);
  const lines = new Map();
  for (const t of realTrips(dayType())) if (t.trip.stations.includes(st.i)) lines.set(t.line, (lines.get(t.line) || 0) + 1);
  const body = `<dl class="figures"><div><dt>Circulaciones</dt><dd>${n(st.traffic)}</dd><em>en laborable</em></div><div><dt>Código</dt><dd class="mono" style="font-size:18px">${esc(st.id)}</dd></div></dl>
  <p>${[...lines.entries()].sort((a, b) => b[1] - a[1]).map(([l]) => chip(S.lineCode(l), S.LINES[l].color)).join(' ')}</p>
  <h3>Próximas salidas ${layer === 'real' || state.ops.phase !== 'running' ? '(horario oficial)' : '(tu jornada)'}</h3>
  <div class="board">${deps.slice(0, 14).map(({t, dep}) => `<div class="row" style="grid-template-columns:50px 64px 1fr"><span>${clock(dep)}</span><span>${chip(t.bus ? 'BUS' : S.lineCode(t.line), t.bus ? '#c98a1c' : S.LINES[t.line].color)}</span><button class="dest" data-action="train" data-id="${esc(t.id)}">${esc(S.STATIONS[t.trip.stations.at(-1)].name)}${t.delay > 5 ? ` <span class="late">+${t.delay}</span>` : ''}</button></div>`).join('') || '<div class="row"><span></span><span></span><span>Sin más salidas hoy</span></div>'}</div>
  <div class="toolbar"><button class="btn small" data-action="station-map" data-id="${st.i}">Acercar</button><button class="btn small" data-action="station-timetable" data-id="${st.i}">Panel completo</button></div>`;
  return {kicker: 'Estación', title: esc(st.name), body};
}
function workInspector() {
  const def = PROJECTS.find(p => p.id === inspect.id), job = state.projects.find(p => p.id === inspect.id);
  if (!def && !job) return null;
  const st = job ? O.constructionStatus(state, job) : null;
  const body = `<p>${esc(def?.desc || '')}</p>${def ? `<p class="small muted">${esc(def.status)} ${sourceLink(def.source)}</p>` : ''}
  ${job ? `<dl class="figures"><div><dt>Avance</dt><dd>${n(st.progress * 100)} %</dd></div><div><dt>Fin previsto</dt><dd style="font-size:17px">${E.dateOf(job.due)}</dd></div></dl><div class="bar gold"><span style="width:${st.progress * 100}%"></span></div>
  <ul class="objectives">${O.STAGES.map((name, i) => `<li class="${i < st.stageIndex ? 'done' : ''}"><i style="${i === st.stageIndex ? 'box-shadow:inset 0 0 0 2px var(--gold);background:rgba(240,181,68,.35)' : ''}"></i><span>${name}</span><span class="small muted">${i < st.stageIndex ? 'Terminada' : i === st.stageIndex ? 'En curso' : ''}</span></li>`).join('')}</ul>${job.delay ? `<p class="callout red">Retraso acumulado: ${job.delay} meses.</p>` : ''}`
    : `<dl class="figures"><div><dt>Aportación</dt><dd>${money(def.cost)}</dd></div><div><dt>Plazo de juego</dt><dd>${def.duration} meses</dd></div></dl><button class="btn primary" data-action="project" data-id="${def.id}" ${state.ended ? 'disabled' : ''}>Financiar el proyecto</button>`}
  <div class="toolbar"><button class="btn small" data-action="visit-work" data-id="${inspect.id}">Acercar a la obra</button></div>
  <p class="note">Fases y avance espacial simulados. Acércate más en el mapa para ver traviesas, hitos de fase y el frente de obra.</p>`;
  return {kicker: 'Obra · ' + esc(def?.region || ''), title: esc(def?.name || 'Línea nueva'), body};
}

// ------------------------------------------------------------ ventanas modales
function showModal(html, cls = '') { pause(); const was = $('modal').open; $('modal').innerHTML = `<div class="modal ${cls}">${html}</div>`; if (!was) $('modal').showModal(); mountViewers($('modal')); sfx.play(was ? 'page' : 'open'); }
function closeModal() { if ($('modal').open) $('modal').close(); }
$('modal').addEventListener('close', () => { if (!$('modal').open && voices.speaking?.where === 'modal') voices.stop(); sfx.play('close'); });
function intro() {
  showModal(`<div class="art hero-art"></div><div class="content"><div class="kicker">Campaña · 2022–2050</div><h1>El próximo tren lo decides tú.</h1><p>Enero de 2022. España vuelve a moverse. Asumes la dirección de una Renfe que necesita recuperar servicios, renovar sus trenes y volver a ganarse al viajero.</p><p>Por la red circulan <b>los trenes reales</b>: ${n(S.META.counts.L)} circulaciones de un día laborable del horario oficial, de la Alta Velocidad a los regionales. Cada jornada empieza con el primer tren y termina con el último.</p><div class="actions">${saved ? '<button class="btn primary" data-action="continue">Continuar partida</button>' : ''}<button class="btn ${saved ? '' : 'primary'}" data-action="begin">Asumir la dirección</button><button class="btn ghost" data-action="observe">Solo mirar el horario real</button></div><p class="note">Historia alternativa: la escasez inicial y los cierres son ficción; los horarios, estaciones, proyectos y contratos tienen fuente. Se guarda en este navegador.</p></div>`);
}
function showDecision() {
  const d = E.pendingDecision(state); if (!d) return;
  const person = CHARACTERS[d.person];
  showModal(`<div class="art portrait p${person.portrait}" role="img" aria-label="${esc(person.name)}"></div><div class="content"><div class="kicker">${esc(E.dateOf(state.month))} · Consejo de dirección</div><h1>${esc(d.title)}</h1><p data-say="${esc(d.body)}">${sayHtml(d.body)}</p><p class="small speaker" style="color:var(--gold)">${sayButton(d.person, 'modal')} ${esc(person.name)} · diálogo ficticio</p>${d.choices.map((c, i) => `<button class="choice" data-action="decision" data-id="${d.id}" data-choice="${i}" ${state.cash < -(c.effects.cash || 0) ? 'disabled' : ''}><strong>${esc(c.label)}</strong><span>${esc(c.detail)}</span></button>`).join('')}<p class="note">${d.source ? sourceLink(d.source, 'Contexto documentado') + ' · decisiones y efectos simulados' : 'Escenario ficticio de la campaña'}</p></div>`);
  speakIn($('modal'), d.person, 'modal');
}
function dayReport() {
  const l = state.ops.last; if (!l) return;
  const r = state.routes.find(r => r.id === l.busiest);
  showModal(`<div class="content"><div class="kicker">Parte de la jornada · ${esc(l.date)}</div><h1>El último tren ha llegado.</h1>
  <div class="report-head"><div class="ring" style="--p:${l.punctuality}"><div><strong>${l.punctuality}%</strong><small>puntualidad</small></div></div>
  <dl class="figures" style="margin:0"><div><dt>Circulaciones</dt><dd>${n(l.trains)}</dd></div><div><dt>Tren-km</dt><dd>${n(l.km)}</dd></div><div><dt>Viajeros</dt><dd>${n(l.passengers)}</dd></div><div><dt>Resultado del día</dt><dd class="${l.net >= 0 ? 'pos' : 'neg'}">${signed(l.net)}</dd></div></dl></div>
  <table><tbody><tr><td>Primera salida · última llegada</td><td class="num mono">${clock(l.first)} · ${clock(l.last)}</td></tr><tr><td>Con más de 5 minutos de retraso</td><td class="num">${n(l.late)}</td></tr><tr><td>Incidencias atendidas</td><td class="num">${l.attended} / ${l.incidents}</td></tr>${l.buses ? `<tr><td>Servicios por carretera (obras)</td><td class="num">${n(l.buses)}</td></tr>` : ''}${r ? `<tr><td>Línea con más trenes</td><td class="num">${routeChip(r)} ${esc(routeName(r))} · ${n(l.busiestTrains)}</td></tr>` : ''}${l.worst?.delay ? `<tr><td>Mayor retraso</td><td class="num">${esc(l.worst.label)} · +${l.worst.delay} min</td></tr>` : ''}</tbody></table>
  <p class="note">La explotación se liquida una vez al cerrar el mes; este parte reparte la previsión mensual entre sus días.</p>
  <div class="actions"><button class="btn primary" data-action="day-next">Siguiente jornada</button><button class="btn" data-action="close-modal">Volver al mapa</button></div></div>`, 'single');
}
function fleetDetail(id) {
  const f = state.fleet.find(f => f.id === id), m = MODEL[f.model], free = E.available(state, f);
  const used = state.routes.filter(r => r.active && r.fleet === f.id);
  showModal(`<div class="content"><div class="kicker">Lote de material</div><h1>${esc(m.name)}</h1><div class="train3d" data-train3d="${f.model}"></div><dl class="figures"><div><dt>Unidades</dt><dd>${f.qty}</dd></div><div><dt>Libres</dt><dd>${free}</dd></div><div><dt>Estado</dt><dd>${n(f.condition)} %</dd></div></dl>
  <p class="small">${used.length ? 'Asignado a: ' + used.map(r => esc(routeName(r)) + ' (' + r.units + ')').join(', ') : 'Sin asignar.'}</p>
  <label for="fleetQty">Unidades libres a gestionar</label><input id="fleetQty" type="number" min="1" max="${free}" value="${Math.min(2, free)}">
  <p class="callout">Reforma: ${money(m.price * .12)} por unidad · 5 meses. Venta: unos ${money(m.price * .23 * f.condition / 100)} por unidad.</p>
  <div class="actions"><button class="btn primary" data-action="refurbish" data-id="${id}" ${!free || state.ended ? 'disabled' : ''}>Enviar a reforma</button><button class="btn danger" data-action="sell" data-id="${id}" ${!free || state.ended ? 'disabled' : ''}>Vender</button><button class="btn" data-action="close-modal">Cerrar</button></div></div>`, 'single');
}
function purchaseDialog(id) {
  const m = MODEL[id];
  showModal(`<div class="content"><div class="kicker">Nuevo pedido</div><h1>${esc(m.name)}</h1><div class="train3d" data-train3d="${id}"></div><p>${esc(m.desc)}</p><label for="buyQty">Unidades (1–30)</label><input id="buyQty" type="number" min="1" max="30" value="4" data-model="${id}"><div id="purchaseQuote"></div><div class="actions"><button class="btn primary" data-action="confirm-buy" data-id="${id}">Firmar pedido</button><button class="btn" data-action="close-modal">Cancelar</button></div><p class="note">Entregas de hasta 2 unidades por mes; puede haber un retraso de 2 a 6 meses.</p></div>`, 'single');
  updateQuote();
}
function updateQuote() {
  try { const q = E.purchaseQuote(state, $('buyQty').dataset.model, +$('buyQty').value); $('purchaseQuote').innerHTML = `<dl class="figures"><div><dt>Total</dt><dd>${money(q.total)}</dd></div><div><dt>Anticipo</dt><dd>${money(q.deposit)}</dd></div><div><dt>Primer lote</dt><dd style="font-size:18px">${E.dateOf(state.month + q.lead)}</dd></div></dl>${state.cash < q.deposit ? '<p class="callout red">No hay caja suficiente para el anticipo.</p>' : ''}`; }
  catch (e) { $('purchaseQuote').innerHTML = `<p class="callout red">${esc(e.message)}</p>`; }
}
function newLineDialog() {
  showModal(`<div class="content"><div class="kicker">Planificación de red</div><h1>Dibuja el siguiente enlace.</h1><p>Una conexión hipotética entre dos ciudades. El mapa la dibuja como enlace conceptual.</p><div class="toolbar"><select id="lineA">${CITIES.map(c => `<option value="${c.id}" ${c.id === 'mur' ? 'selected' : ''}>${c.name}</option>`).join('')}</select><span>→</span><select id="lineB">${CITIES.map(c => `<option value="${c.id}" ${c.id === 'vlc' ? 'selected' : ''}>${c.name}</option>`).join('')}</select><select id="lineType"><option value="regional">Regional · ancho ibérico</option><option value="av">Alta velocidad · ancho estándar</option></select></div><p id="lineQuote" class="callout"></p><div class="actions"><button class="btn primary" data-action="confirm-line">Contratar estudio y obra</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single');
  updateLineQuote();
}
function updateLineQuote() { try { const q = E.newLineQuote($('lineA').value, $('lineB').value, $('lineType').value); $('lineQuote').textContent = `${q.km} km estimados · ${money(q.cost)} · ${q.duration} meses de desarrollo antes de posibles retrasos.`; } catch (e) { $('lineQuote').textContent = e.message; } }
function saveDialog() {
  showModal(`<div class="content"><div class="kicker">Guardado local</div><h1>Tu partida, a salvo.</h1><p>El guardado automático pertenece a este navegador. Exporta una copia para conservarla o seguir en otro equipo. Las partidas de la versión 0.2 se pueden importar.</p><div class="actions"><button class="btn primary" data-action="save-now">Guardar ahora</button><button class="btn" data-action="export">Exportar (.json)</button></div><label for="importSave">Importar una partida</label><input id="importSave" type="file" accept="application/json,.json"></div>`, 'single');
}
function help() {
  showModal(`<div class="content"><div class="kicker">Cómo jugar</div><h1>Un día, un turno.</h1><ol class="method">
  <li><b>Pulsa una ciudad.</b> Su menú muestra sus conexiones: ábrelas, pon más o menos trenes con + y −, mejora su estación y atiende sus peticiones (❗).</li>
  <li><b>Comienza la jornada.</b> El reloj arranca con el primer tren y termina con el último. Cada llegada suma viajeros e ingresos. Atento a los momentos ⚡: refuerza a tiempo y cobra la bonificación. Cambia la velocidad (1×–30×) o pausa con <kbd>Espacio</kbd>.</li>
  <li><b>Decide ante las incidencias.</b> Averías, fallos de infraestructura, intrusiones o meteorología: equipo de intervención, plan por carretera o esperar.</li>
  <li><b>Lee el parte del día</b> y pasa a la siguiente jornada. Al cerrar el mes se liquidan las cuentas. Puedes delegar el resto del mes.</li>
  <li><b>Crece.</b> Compra trenes (unos dos años de plazo), reforma material, financia obras y visítalas con zoom en la capa <b>Obras</b>.</li>
  <li><b>Explora.</b> La capa <b>Horario real</b> muestra todas las circulaciones publicadas. Pulsa un tren para seguirlo o una estación para ver su panel de salidas.</li></ol>
  <p class="small">Atajos: <kbd>Espacio</kbd> pausa · <kbd>1</kbd>–<kbd>4</kbd> velocidad · <kbd>+</kbd>/<kbd>−</kbd> zoom · <kbd>Esc</kbd> cerrar.</p><div class="actions"><button class="btn primary" data-action="close-modal">Entendido</button><button class="btn" data-action="tutorial-start">Repetir el tutorial</button></div></div>`, 'single');
}
function trainRecord(id) {
  const t = REAL_TRAIN_CATALOGUE.find(x => x.id === id); if (!t) return;
  const rows = [['Categoría', t.category], ['Fabricante', t.builder], ['Velocidad máxima', t.maxSpeedKmH?.join(' / ') + ' km/h'], ['Plazas sentadas', t.seatedCapacity?.join(' / ')], ['Tracción', t.traction], ['Longitud', t.lengthM ? t.lengthM + ' m' : null], ['Unidades construidas (fuente)', t.constructedUnitsReported], ['Estado documental', t.status]];
  showModal(`<div class="content"><div class="kicker">Ficha de serie</div><h1>${esc(t.name || t.series)}</h1><div class="train3d" data-train3d="${esc(t.series || t.id)}"></div><table><tbody>${rows.map(([k, v]) => `<tr><td>${k}</td><td>${v !== undefined && v !== null && !String(v).startsWith('undefined') ? esc(v) : '<span class="muted">No verificado</span>'}</td></tr>`).join('')}</tbody></table><p class="note">${(t.sources || []).map(s => typeof s === 'string' ? `<a href="${esc(s)}" target="_blank" rel="noopener noreferrer">Fuente</a>` : `<a href="${esc(s.url)}" target="_blank" rel="noopener noreferrer">${esc(s.title || 'Fuente')}</a>`).join(' · ')}</p><div class="actions"><button class="btn" data-action="close-modal">Cerrar</button></div></div>`, 'single');
}
function realTripModal(id) { inspect = {type: 'train', id}; map.selectedTrain = id; screen = null; if (layer !== 'real' && !plan().some(t => t.id === id)) setLayer('real'); render(); }

// ------------------------------------------------------------ capas y acciones
function setLayer(l) {
  layer = l; map.layer = l === 'works' ? 'works' : 'network';
  document.querySelectorAll('[data-layer]').forEach(b => b.classList.toggle('active', b.dataset.layer === l));
  netKey = networkKey(); map.dirty = true; renderLegend(); renderDaybar();
  if (l === 'real') toast('Horario real: todas las circulaciones publicadas para un día ' + S.DAY_TYPES[dayType()].toLowerCase() + '. No altera tu campaña.');
}
function openNetwork(net) {
  let opened = 0, missing = 0;
  for (const r of state.routes.filter(r => r.net === net && !r.active && E.isUnlocked(state, r))) {
    const want = Math.max(1, Math.round(r.baseFrequency * .5));
    const f = state.fleet.filter(f => f.qty && f.condition >= 30 && E.compatible(r, MODEL[f.model])).sort((a, b) => E.available(state, b) - E.available(state, a))[0];
    if (!f) { missing++; continue; }
    let freq = want;
    while (freq > 1 && E.available(state, f, r.id) < E.requiredUnits(r, MODEL[f.model], freq)) freq = Math.floor(freq * .7);
    try { E.configureRoute(state, r.id, f.id, freq, r.fare); opened++; } catch { missing++; }
  }
  netKey = networkKey(); map.dirty = true; autosave(); render(); sfx.result(opened > 0);
  toast(opened ? `${opened} líneas reabiertas${missing ? ' · ' + missing + ' sin material o caja suficiente' : ''}.` : 'No se pudo reabrir ninguna línea: falta material compatible o tesorería.');
}

document.addEventListener('click', event => {
  const b = event.target.closest('[data-action]');
  if (!b || b.disabled) return;
  const a = b.dataset.action, id = b.dataset.id;
  clickSound(a, b);
  switch (a) {
    case 'navigate': navigate(b.dataset.screen); break;
    case 'close-drawer': screen = null; render(); break;
    case 'close-inspector': inspect = null; map.selected = null; map.selectedTrain = null; map.follow = false; renderInspector(); break;
    case 'close-modal': closeModal(); break;
    case 'begin': state = E.initialState(); O.ensureOps(state); state.ops.day = 3; state.started = true; tut = null; closeModal(); netKey = networkKey(); map.dirty = true; render(); autosave(); showDecision(); break;
    case 'continue': if (saved) { state = E.validateSave(saved); O.ensureOps(state); state.started = true; closeModal(); netKey = networkKey(); map.dirty = true; render(); if (E.pendingDecision(state)) showDecision(); } break;
    case 'observe': closeModal(); setLayer('real'); observerMinute = 480; play(); break;
    case 'decision': if (act(() => E.decide(state, id, +b.dataset.choice))) { closeModal(); if (E.pendingDecision(state)) showDecision(); else if (!state.tutorial?.done && !tut && state.month === 0) startTutorial(); } break;
    case 'claim': act(() => E.claimChapter(state), 'Financiación recibida. Tu siguiente etapa está preparada.'); setTimeout(() => { const st = document.querySelector('.story'); if (st && !state.ended) speakIn(st, CHAPTERS[state.chapter].speaker, 'story'); }, 60); break;
    case 'play': playing ? pause() : play(); break;
    case 'speed': speedIndex = +id; renderDaybar(); break;
    case 'day-start': if (layer === 'real') setLayer('network'); play(); break;
    case 'day-end': pause(); if (state.ops.phase === 'running') { state.ops.minute = O.dayBounds(plan()).last; finishDay(); } break;
    case 'day-review': dayReport(); break;
    case 'day-next': try { O.nextDay(state); sfx.result(true); closeModal(); seenIncidents = new Set(); autosave(); render(); if (E.pendingDecision(state)) showDecision(); else if (state.ended) navigate('story'); } catch (e) { sfx.result(false); toast(e.message); } break;
    case 'skip-month': pause(); try { if (O.skipMonth(state)) { sfx.result(true); autosave(); render(); toast('Mes delegado. Cuentas liquidadas.'); if (E.pendingDecision(state)) showDecision(); if (state.ended) navigate('story'); } else sfx.intent = null; } catch (e) { sfx.result(false); toast(e.message); } break;
    case 'open-incidents': document.querySelector('.alert-pill')?.remove(); navigate('ops'); if (screen !== 'ops') navigate('ops'); break;
    case 'respond': act(() => O.resolveIncident(state, id, b.dataset.option), O.RESPONSES[b.dataset.option].note); break;
    case 'route': selectRoute(id); break;
    case 'city': { const c = CITY[id]; document.querySelector('.alert-pill')?.remove(); inspect = {type: 'city', id}; screen = null; map.selectedCity = id; if (c && map.zoom < 1.4) map.focusAt(c.lon, c.lat, 1.6); render(); break; }
    case 'freq-up': case 'freq-down': { const r = routeById(id), step = Math.max(1, Math.round(E.maxFrequency(r) * .1)); act(() => setService(r, r.frequency + (a === 'freq-up' ? step : -step))); break; }
    case 'open-route': { const r = routeById(id); act(() => setService(r, Math.max(1, Math.round(E.maxFrequency(r) * .4))), 'Conexión abierta: ' + routeName(r) + '.'); break; }
    case 'request': { const q = (state.requests || []).find(q => q.id === id); if (q) act(() => doRequest(q)); break; }
    case 'station-up': act(() => E.upgradeStation(state, id), 'Estación mejorada.'); celebrate(id, 'Estación mejorada', E.STATION_LEVELS[state.stations?.[id] || 0]); break;
    case 'music': musicDialog(); break;
    case 'music-play': { const song = SONGS.find(x => x.id === id); if (song) { if (music.mode === 'auto') music.setMode('list'); music.play(song); } break; }
    case 'music-toggle': music.toggle(); break;
    case 'voice-toggle': voices.toggle(); musicDialog(true); break;
    case 'sfx-toggle': if (sfx.toggle()) sfx.play('toggleOn'); musicDialog(true); break;
    case 'say': {
      const where = b.dataset.where, root = where === 'coach' ? $('coach') : where === 'modal' ? $('modal') : b.closest('.story');
      if (voices.speaking?.where === where) voices.stop();
      else { if (!voices.enabled) voices.toggle(); speakIn(root, b.dataset.person, where); }
      break;
    }
    case 'music-next': music.next(); break;
    case 'tutorial-next': tutorialNext(); break;
    case 'tutorial-skip': endTutorial(); break;
    case 'tutorial-start': closeModal(); startTutorial(); break;
    case 'route-zoom': map.focus(id, true); break;
    case 'route-trips': { const r = state.routes.find(r => r.id === id); ui.ttStation = ''; ui.ttStationId = undefined; screen = 'timetables'; inspect = null; const first = S.routeTrips(dayType(), id)[0]; if (first) { ui.ttStationId = first.stations[0]; ui.ttStation = S.STATIONS[first.stations[0]].name.toLowerCase(); } render(); if (r) toast('Salidas desde ' + S.STATIONS[first?.stations[0]]?.name); break; }
    case 'route-tab': ui.routeTab = id; renderDrawer(); break;
    case 'network-zoom': { const lines = state.routes.filter(r => r.net === id); map.fit(lines.flatMap(r => map.routeCoords(r.id)), 40); screen = null; render(); break; }
    case 'open-network': openNetwork(id); break;
    case 'train': inspect = {type: 'train', id}; map.selectedTrain = id; screen = null; render(); break;
    case 'station': inspect = {type: 'station', id: +id}; render(); break;
    case 'station-map': { const st = S.STATIONS[+id]; screen = null; inspect = {type: 'station', id: +id}; map.focusAt(st.lon, st.lat, 60); render(); break; }
    case 'station-timetable': { const st = S.STATIONS[+id]; ui.ttStationId = +id; ui.ttStation = st.name.toLowerCase(); ui.ttHour = Math.max(4, Math.min(25, Math.floor(currentMinute() / 60))); inspect = null; screen = 'timetables'; render(); break; }
    case 'tt-type': ui.ttType = id; renderDrawer(); break;
    case 'tt-station': ui.ttStationId = +id; ui.ttStation = S.STATIONS[+id].name.toLowerCase(); renderDrawer(); break;
    case 'real-trip': realTripModal(id); break;
    case 'follow': map.follow = !map.follow; renderInspector(); break;
    case 'layer': setLayer(id); screen = null; render(); break;
    case 'visit-work': { const job = state.projects.find(p => p.id === id) || {id}; const pts = map.workGeometry(job).flatMap(g => g.pts); setLayer('works'); map.fit(pts, 45); inspect = {type: 'work', id}; screen = null; render(); break; }
    case 'close-service': act(() => E.closeRoute(state, id), 'Servicio suspendido. El material queda libre.'); break;
    case 'upgrade': act(() => E.upgradeRoute(state, id), 'Mejora contratada. Termina en cuatro meses.'); break;
    case 'fleet-tab': ui.fleetTab = id; renderDrawer(); break;
    case 'fleet-detail': fleetDetail(id); break;
    case 'refurbish': if (act(() => E.refurbish(state, id, +$('fleetQty').value), 'Material enviado a reforma.')) closeModal(); break;
    case 'sell': if (act(() => E.sell(state, id, +$('fleetQty').value), 'Venta completada.')) closeModal(); break;
    case 'train-record': trainRecord(id); break;
    case 'market-tab': ui.marketTab = id; renderDrawer(); break;
    case 'purchase': purchaseDialog(id); break;
    case 'confirm-buy': if (act(() => E.buy(state, id, +$('buyQty').value), 'Pedido firmado.')) closeModal(); break;
    case 'project': { const p = PROJECTS.find(p => p.id === id); showModal(`<div class="content"><div class="kicker">Acuerdo de infraestructura</div><h1>${esc(p.name)}</h1><p>${esc(p.desc)}</p><p>Aportación de campaña: <b>${money(p.cost)}</b>, a cargo de tu tesorería al firmar.</p><div class="actions"><button class="btn primary" data-action="confirm-project" data-id="${id}">Firmar y financiar</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single'); break; }
    case 'confirm-project': if (act(() => E.startProject(state, id), 'Acuerdo con Adif firmado.')) closeModal(); break;
    case 'new-line': newLineDialog(); break;
    case 'confirm-line': if (act(() => E.buildLine(state, $('lineA').value, $('lineB').value, $('lineType').value), 'Nueva conexión en desarrollo.')) closeModal(); break;
    case 'borrow': act(() => E.loan(state, 100), 'Financiación de 100 M€ recibida.'); break;
    case 'repay': act(() => E.loan(state, -100), '100 M€ amortizados.'); break;
    case 'archive-tab': ui.archiveTab = id; renderDrawer(); break;
    case 'license': showModal(`<div class="content"><div class="kicker">Licencia</div><h1>Datos cartográficos</h1><pre style="white-space:pre-wrap;font-size:12px">${esc(document.getElementById('geodata-license')?.textContent || 'Consulta LICENSE-GEODATA.txt en el proyecto editable.')}</pre></div>`, 'single'); break;
    case 'save-dialog': saveDialog(); break;
    case 'help': help(); break;
    case 'save-now': autosave(true); break;
    case 'export': { const blob = new Blob([JSON.stringify(state, null, 2)], {type: 'application/json'}), url = URL.createObjectURL(blob), link = document.createElement('a'); link.href = url; link.download = 'Iberia-Ferroviaria-' + E.yearOf(state) + '.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); toast('Partida exportada.'); break; }
    case 'new-game': showModal(`<div class="content"><div class="kicker">Nueva campaña</div><h1>¿Un nuevo mandato?</h1><p>La nueva campaña sustituirá el guardado automático.</p><div class="actions"><button class="btn" data-action="export">Exportar la actual</button><button class="btn primary" data-action="begin">Empezar en 2022</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single'); break;
  }
});
document.addEventListener('submit', event => {
  if (event.target.id !== 'routeForm') return;
  event.preventDefault();
  sfx.expect('plan');
  act(() => E.configureRoute(state, inspect.id, $('routeFleet').value, +$('frequency').value, +$('fare').value), 'Plan de servicio actualizado.');
});
document.addEventListener('input', event => {
  const t = event.target;
  if (t.type === 'range' || t.type === 'number') sfx.slide(t);
  if (t.id === 'sfxVolume') sfx.setVolume(+t.value);
  if (['routeFleet', 'frequency', 'fare'].includes(t.id)) updatePreview();
  if (t.id === 'musicVolume') music.setVolume(+t.value);
  if (t.id === 'routeSearch') { ui.routeQuery = t.value; renderDrawer(); }
  if (t.id === 'ttStation') { ui.ttStation = t.value; ui.ttStationId = undefined; renderDrawer(); }
  if (t.id === 'trainSearch') { ui.trainQuery = t.value; renderDrawer(); }
  if (t.id === 'referenceSearch') { referenceQuery = t.value; renderDrawer(); }
  if (t.id === 'buyQty') updateQuote();
  if (['lineA', 'lineB', 'lineType'].includes(t.id)) updateLineQuote();
});
document.addEventListener('change', async event => {
  const t = event.target;
  if (t.tagName === 'SELECT' || t.type === 'date') sfx.play('select');
  if (t.type === 'checkbox') sfx.play(t.checked ? 'toggleOn' : 'toggleOff');
  if (t.type === 'file' && t.files[0]) sfx.play('page');
  if (t.id === 'maintenance') sfx.intent = null;
  if (t.id === 'routeStatus') { ui.routeStatus = t.value; renderDrawer(); }
  if (t.id === 'ttHour') { ui.ttHour = +t.value; renderDrawer(); }
  if (t.id === 'dayPriority' && state.ops.phase === 'planning') { state.ops.priority = t.value; autosave(); render(); }
  if (t.id === 'autoPause') ui.autoPause = t.checked;
  if (t.id === 'musicMode') music.setMode(t.value);
  if (t.id === 'maintenance') act(() => { E.ensurePlaying(state); state.maintenance = E.clamp(+t.value, .6, 1.5); });
  if (t.id === 'referenceDate') { referenceDate = t.value; renderDrawer(); }
  if (t.id === 'importSave' && t.files[0]) {
    try { if (t.files[0].size > 6e6) throw Error('El archivo es demasiado grande.'); state = E.validateSave(JSON.parse(await t.files[0].text())); O.ensureOps(state); state.started = true; autosave(); sfx.play('confirm'); closeModal(); inspect = null; screen = null; netKey = networkKey(); map.dirty = true; render(); toast('Partida importada.'); if (E.pendingDecision(state)) showDecision(); }
    catch (e) { sfx.play('error'); toast('No se pudo importar: ' + e.message); }
  }
  if (t.id === 'gtfsImport' && t.files[0]) {
    const file = t.files[0]; t.disabled = true;
    try { pause(); const feed = await G.importGTFS(file, msg => { const el = $('gtfsProgress'); if (el) el.textContent = msg; }); referenceFeed = G.combineFeeds(referenceFeed, feed); referenceDate = G.dateISO(feed.dateStart); try { await G.storeFeed(referenceFeed); } catch {} sfx.play('confirm'); toast('GTFS cargado para consulta.'); renderDrawer(); }
    catch (e) { sfx.play('error'); toast('No se pudo leer el horario: ' + e.message); t.disabled = false; }
  }
});
document.addEventListener('pointerdown', event => {
  const cv = event.target.closest?.('#timelineCanvas');
  if (!cv || !(layer === 'real' && state.ops.phase !== 'running')) return;
  const r = cv.getBoundingClientRect();
  observerMinute = +cv.dataset.first + (event.clientX - r.left) / r.width * +cv.dataset.span;
  drawTimeline(); renderClock(); sfx.play('scrub');
});
// campos de formulario (al pulsarlos) y enlaces a las fuentes
document.addEventListener('pointerdown', event => { if (event.target.closest?.('input, select, textarea, label[for], .train3d')) sfx.play('tick'); });
document.addEventListener('click', event => { if (event.target.closest?.('a[href]')) sfx.play('tap'); });
document.querySelectorAll('[data-layer]').forEach(b => b.onclick = () => { sfx.play('lever', {i: ['network', 'real', 'works'].indexOf(b.dataset.layer)}); setLayer(b.dataset.layer); });
$('zoomIn').onclick = () => { sfx.play('zoomIn'); map.zoomAt(map.zoom * 1.5); };
$('zoomOut').onclick = () => { sfx.play('zoomOut'); map.zoomAt(map.zoom / 1.5); };
$('resetMap').onclick = () => { sfx.play('resetMap'); map.reset(); };
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !$('modal').open && ['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName)) document.activeElement.blur();
  else if (['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName) || $('modal').open) return;
  if (event.code === 'Space') { event.preventDefault(); sfx.play(playing ? 'pause' : state.started && state.ops.phase === 'planning' && layer !== 'real' ? 'departure' : 'resume'); playing ? pause() : play(); }
  if (['1', '2', '3', '4'].includes(event.key)) { speedIndex = +event.key - 1; sfx.play('speed', {i: speedIndex}); renderDaybar(); }
  if (event.key === '+' || event.key === '=') { sfx.play('zoomIn'); map.zoomAt(map.zoom * 1.4); }
  if (event.key === '-') { sfx.play('zoomOut'); map.zoomAt(map.zoom / 1.4); }
  if (event.key === 'Escape') { if (screen || inspect) sfx.play('dismiss'); screen = null; inspect = null; map.selected = null; map.selectedTrain = null; map.follow = false; render(); }
});
$('modal').addEventListener('cancel', event => { if (E.pendingDecision(state) || !state.started) event.preventDefault(); });

// API de lectura para verificación automatizada y accesibilidad.
window.railwayGame = {music, voices, sfx, snapshot: () => JSON.parse(JSON.stringify(state)), engine: E, operations: O, schedule: S, map, navigate, setLayer, selectRoute,
  plan: () => plan().map(t => ({id: t.id, route: t.route, dep: t.dep, arrival: t.arrival, delay: t.delay, real: t.real})), minute: currentMinute, play, pause, finishDay,
  state: () => state, render, pick, setMinute: m => { if (state.ops.phase === 'running') state.ops.minute = m; else observerMinute = m; render(); }};

render(); renderMusicButton(); intro(); requestAnimationFrame(frame);
G.loadFeed().then(feed => { if (feed) { referenceFeed = feed; referenceDate = G.dateISO(feed.dateStart); } }).catch(() => {});
