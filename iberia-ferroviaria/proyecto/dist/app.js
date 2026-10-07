// Iberia Ferroviaria 2.0 — interfaz. Mapa a pantalla completa, jornada por turnos, red de anchos y catenaria.
import {CITIES, CITY, MODELS, MODEL, PROJECTS, HISTORICAL_ORDERS, GAUGES, POWERS} from './data.js';
import {CHAPTERS, CHARACTERS} from './story.js';
import * as E from './engine.js';
import * as O from './operations.js';
import * as S from './schedule.js';
import * as I from './infra.js';
import {RailMap, FAMILY_COLOR, GAUGE_COLOR, ELEC_COLOR} from './map-v3.js';
import {trainArt, artKey} from './train-art.js';
import {citySkyline} from './city-art.js';
import {trainThumb, mountViewers} from './train3d.js';
import {Voices, sentences, CAST} from './voice.js';
import {Soundtrack, SONGS, STYLE_LABEL, FAMILY_LABEL} from './music.js';
import {Sfx, ACTIONS} from './sfx.js';
import {faceURL} from './faces.js';

const $ = id => document.getElementById(id);
const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const n = (x, d = 0) => Number(x || 0).toLocaleString('es-ES', {maximumFractionDigits: d, minimumFractionDigits: d});
const money = x => n(x, Math.abs(x) < 10 ? 2 : 1) + ' M€', signed = x => (x >= 0 ? '+' : '') + money(x);
const clock = O.clockText;
const KEY = 'iberia-ferroviaria-v2';
const SPEEDS = [[2, '1×'], [6, '3×'], [20, '10×'], [60, '30×']];
const LAYERS = ['network', 'real', 'gauge', 'power', 'works'];
const ICONS = {
  ops: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3.5 2"/>',
  network: '<path d="M4 18c4-1 4-11 8-12s4 9 8 8"/><circle cx="4" cy="18" r="1.6"/><circle cx="20" cy="14" r="1.6"/><circle cx="12" cy="6" r="1.6"/>',
  timetables: '<rect x="4" y="4" width="16" height="16" rx="2.5"/><path d="M4 9h16M9 9v11M13 13h4M13 16.5h4"/>',
  fleet: '<path d="M5 15V8a3 3 0 0 1 3-3h8a3 3 0 0 1 3 3v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2zM5 11h14M8 20l1.5-3M16 20l-1.5-3"/><circle cx="8.5" cy="14" r=".8"/><circle cx="15.5" cy="14" r=".8"/>',
  market: '<path d="M4 7h16l-1.5 9.5a2 2 0 0 1-2 1.5h-9a2 2 0 0 1-2-1.5zM9 7V5.5a3 3 0 0 1 6 0V7"/>',
  works: '<path d="M4 20h16M6 20V9l6-4 6 4v11M10 20v-5h4v5"/><path d="M15 4l4 2"/>',
  finance: '<path d="M4 19h16M7 16V10M12 16V6M17 16v-4"/>',
  story: '<rect x="3.5" y="8" width="17" height="11.5" rx="2"/><path d="M9 8V6a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 6v2M3.5 13h17M11 13v2h2v-2"/>',
  speaker: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>',
  stopsq: '<rect x="7" y="7" width="10" height="10" rx="1.5"/>',
  alert: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5.5M12 16.3v.2"/>',
  bolt: '<path d="M13 3.5 6 13.5h5l-1 7 7-10h-5z"/>',
  cone: '<path d="M10.2 4.5h3.6l4.2 14H6zM8.3 11h7.4M7.4 14.6h9.2M4.5 18.5h15"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2.3M12 18.2v2.3M3.5 12h2.3M18.2 12h2.3M6 6l1.6 1.6M16.4 16.4 18 18M6 18l1.6-1.6M16.4 7.6 18 6"/>',
  signal: '<rect x="8" y="3.5" width="8" height="12" rx="3"/><circle cx="12" cy="7.3" r="1.4"/><circle cx="12" cy="11.6" r="1.4"/><path d="M12 15.5v5M8.5 20.5h7"/>',
  hand: '<path d="M8 12V6.5a1.5 1.5 0 0 1 3 0V11M11 10V5a1.5 1.5 0 0 1 3 0v5M14 10V6.5a1.5 1.5 0 0 1 3 0v6.5a6.5 6.5 0 0 1-6.5 6.5A5.5 5.5 0 0 1 5 14.5l-1-2.5a1.4 1.4 0 0 1 2.5-1.2L8 13"/>',
  cloud: '<path d="M7 17.5h10a4 4 0 0 0 .4-8 5.5 5.5 0 0 0-10.6 1.3A3.4 3.4 0 0 0 7 17.5z"/><path d="M9 20l1-1.5M13 20l1-1.5"/>',
  swap: '<path d="M5 8.5h13l-3.5-3.5M19 15.5H6l3.5 3.5"/>',
  archive: '<rect x="4" y="5" width="16" height="4" rx="1"/><path d="M5.5 9v10h13V9M10 12.5h4"/>',
  music: '<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="16.5" cy="16" r="2.5"/>',
  save: '<path d="M5 5h11l3 3v11H5zM8 5v5h7V5M8 19v-5h8v5"/>',
  help: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.5a2.5 2.5 0 1 1 3.6 2.3c-.8.4-1.2 1-1.2 1.9M12 16.6v.4"/>',
};
const PAGES = {ops: 'Jornada', network: 'Red', fleet: 'Trenes', works: 'Obras', story: 'Despacho'};
// Secciones antiguas que ahora son pestañas de una de las cinco páginas.
const ALIASES = {timetables: ['network', 'netView', 'timetables'], market: ['fleet', 'fleetTab', 'market'], finance: ['story', 'officeTab', 'finance'], archive: ['story', 'officeTab', 'journal']};

let state = E.initialState(), saved = null, screen = null, inspect = null, playing = false, speedIndex = 1, layer = 'network';
let lastTick = 0, lastPanel = 0, lastTimeline = 0, observerMinute = 480, seenIncidents = new Set(), alertTimer = null, toastTimer = null;
let ui = {routeTab: 'all', routeStatus: 'all', routeQuery: '', netView: 'routes', ttType: null, ttStation: '', ttLine: '', ttHour: 6, fleetTab: 'fleet', worksTab: 'conv', officeTab: 'campaign', autoPause: true};
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
function networkKey() { return state.routes.filter(r => r.active).map(r => r.id + r.frequency + r.fleet).join('|') + '#' + layer + '#' + state.infra.ver + '#' + state.projects.filter(p => !p.done).length; }
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
function sayButton(person, where) { return `<button class="say-btn" data-action="say" data-person="${person}" data-where="${where}" aria-label="Escuchar a ${esc(CHARACTERS[person]?.name || '')}" title="Escuchar">${voices.speaking?.where === where ? glyph('stopsq') : glyph('speaker')}</button>`; }
/** Lee el párrafo [data-say] dentro de root con la voz del personaje y resalta cada frase. */
function speakIn(root, person, where) {
  const el = root?.querySelector('[data-say]'); if (!el) return;
  const spans = [...el.querySelectorAll('.say-s')], face = root.querySelector('.portrait');
  const clear = () => { spans.forEach(x => x.classList.remove('on')); face?.classList.remove('talking'); root.querySelectorAll('.say-btn').forEach(b => b.innerHTML = glyph('speaker')); };
  const ok = voices.speak(person, el.dataset.say, {onSentence: i => { spans.forEach((x, j) => x.classList.toggle('on', j === i)); }, onend: clear});
  if (!ok) return;
  if (voices.speaking) voices.speaking.where = where;
  face?.classList.add('talking'); root.querySelectorAll('.say-btn').forEach(b => b.innerHTML = glyph('stopsq'));
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
  const html = `<div class="content"><div class="kicker">Banda sonora</div><h1>Música de Iberia Ferroviaria</h1>
  <div class="tracks"><h3>${FAMILY_LABEL.estacion}</h3>${list('estacion')}<h3>${FAMILY_LABEL.red}</h3>${list('red')}</div>
  <div class="toolbar"><button class="btn ${music.enabled ? '' : 'primary'}" data-action="music-toggle">${music.enabled ? 'Apagar música' : 'Encender música'}</button><button class="btn" data-action="music-next" ${music.enabled ? '' : 'disabled'}>Siguiente pieza</button>
  <label style="margin:0">Modo</label><select id="musicMode"><option value="auto" ${music.mode === 'auto' ? 'selected' : ''}>Automático según el momento</option><option value="list" ${music.mode === 'list' ? 'selected' : ''}>Toda la lista</option><option value="repeat" ${music.mode === 'repeat' ? 'selected' : ''}>Repetir pieza</option></select></div>
  <label for="musicVolume">Volumen</label><input id="musicVolume" type="range" min="0" max="1" step="0.05" value="${music.volume}">
  <h3 class="sub">Voces de los personajes</h3>
  <div class="toolbar"><button class="btn ${voices.enabled ? '' : 'primary'}" data-action="voice-toggle">${voices.enabled ? 'Silenciar personajes' : 'Activar voces'}</button></div>
  <h3 class="sub">Efectos de sonido</h3>
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
  const opts = {nav: {i: Object.keys(PAGES).indexOf(b.dataset.screen)}, tab: {i: Math.max(0, siblings.indexOf(b))}, pickCity: {i: hashOf(id)}, lever: {i: LAYERS.indexOf(id)},
    speed: {i: +id}, tutorialNext: {i: (tut?.step ?? 0) + 1}}[spec] || {};
  sfx.play(spec, opts);
}
function icon(name) { return `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`; }
function glyph(name) { return `<svg class="ic" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`; }
const INCIDENT_ICON = {breakdown: 'gear', signal: 'signal', trespass: 'hand', weather: 'cloud', changer: 'swap'};
const incidentGlyph = x => glyph(INCIDENT_ICON[x.type] || 'alert');
/** Retrato del personaje con la cara que toca (happy, angry, worried). */
const faceStyle = (person, mood = 'happy') => `background-image:url('${faceURL(person, mood)}')`;
function chip(text, color) { return `<span class="chip" style="background:${esc(color)}">${esc(text)}</span>`; }
/** Producto de la relación: el de su tren o, si está cerrada, el mejor que permite la red. */
function familyOf(r) { return E.product(state, r) || E.bestProduct(state, r); }
function routeColor(r) { return FAMILY_COLOR[familyOf(r)] || '#8a7c69'; }
function routeChip(r) { const f = familyOf(r); return chip(f || 'Sin vía', FAMILY_COLOR[f] || '#8a7c69'); }
function routeName(r) { return r.name || E.routeName(r); }
function statusOf(r) {
  if (r.active) return ['on', 'En servicio'];
  if (r.cut) return ['works', 'Cortada por obras'];
  if (!E.isUnlocked(state, r)) return ['blocked', 'Sin vía posible'];
  return ['off', 'Por abrir'];
}
const workOn = r => O.workOn(state, r);
/** Lo que falta para que circule un AVE (o un Alvia, si ni eso). */
function missingFor(r) {
  const o = E.routeOptions(state, r);
  if (o.ave.ok) return null;
  const alt = o.alvia.ok ? o.alvia : o.hybrid.ok ? o.hybrid : null;
  return {ave: o.ave.faults, alvia: alt ? null : o.alvia.faults, hybrid: alt ? null : o.hybrid.faults, alt};
}
function faultList(faults, max = 3) {
  return faults.slice(0, max).map(f => `<li>${f.tramo ? `<button class="linkish" data-action="tramo" data-id="${esc(f.tramo)}">${esc(I.faultText(state, f))}</button>` : f.node ? `<button class="linkish" data-action="node" data-id="${esc(f.node)}">${esc(I.faultText(state, f))}</button>` : esc(I.faultText(state, f))}</li>`).join('') + (faults.length > max ? `<li class="muted">y ${faults.length - max} más</li>` : '');
}

/** Serie ilustrada para una circulación: material asignado o producto. */
function tripArtKey(t, r) {
  if (t.bus) return 'bus';
  if (r?.fleet) { const f = state.fleet.find(f => f.id === r.fleet); if (f) return artKey(f.model); }
  const code = t.line !== undefined && t.line !== null ? S.lineCode(t.line) : t.family || '';
  return code === 'Alvia' ? '130' : '112';
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
/** Lote de trenes para una relación: el suyo si cabe; si no, AVE antes que Alvia y eléctrico antes que híbrido. */
function fleetFor(r, freq) {
  const rank = f => (MODEL[f.model].family === 'AVE' ? 0 : MODEL[f.model].power === 'electric' ? 1 : 2);
  const lots = state.fleet.filter(f => f.qty && f.condition >= 30 && E.canRun(state, r, MODEL[f.model]));
  const fits = f => E.available(state, f, r.id) >= E.requiredUnits(state, r, MODEL[f.model], freq);
  return lots.find(f => f.id === r.fleet && fits(f)) || lots.filter(fits).sort((a, b) => rank(a) - rank(b) || E.available(state, b, r.id) - E.available(state, a, r.id))[0] || null;
}
function setService(r, freq, fare = r.fare) {
  const max = E.maxFrequency(r);
  freq = Math.max(1, Math.min(max, freq));
  let f = fleetFor(r, freq), want = freq;
  while (!f && freq > 1) { freq--; f = fleetFor(r, freq); }
  if (!f) {
    if (!E.isUnlocked(state, r)) { const o = E.routeOptions(state, r); throw Error('Por ahí no pasa ni un AVE ni un Alvia: ' + I.faultText(state, o.hybrid.faults[0] || o.ave.faults[0]).toLowerCase() + '.'); }
    throw Error('No te quedan trenes libres que puedan ir por esa vía. Compra, reforma o quítaselos a otra línea.');
  }
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
  return {open: `Quiere tren con ${dest}, y lo quiere ya`, more: `Exige ${q.target} salidas por sentido con ${dest}`, fare: `Pide bajar a ${q.target} € el billete a ${dest}`,
    station: `Quiere una estación decente: ${E.STATION_LEVELS[q.target]}`, ave: `¡Quiere AVE! Nada de Alvia hasta ${dest}`}[q.type];
}
function doRequest(q) {
  const r = state.routes.find(r => r.id === q.route);
  if (q.type === 'station') E.upgradeStation(state, q.city);
  else if (q.type === 'open') setService(r, Math.max(1, Math.round(E.maxFrequency(r) * .4)));
  else if (q.type === 'more') setService(r, q.target);
  else if (q.type === 'fare') setService(r, r.frequency, q.target);
  else if (q.type === 'ave') { const f = state.fleet.find(f => f.qty && MODEL[f.model].family === 'AVE' && E.canRun(state, r, MODEL[f.model]) && E.available(state, f, r.id) >= E.requiredUnits(state, r, MODEL[f.model], r.frequency));
    if (!f) throw Error(E.routeOptions(state, r).ave.ok ? 'No hay AVE libres para esa línea.' : 'La vía no deja pasar un AVE: ' + I.faultText(state, E.routeOptions(state, r).ave.faults[0]).toLowerCase() + '.');
    E.configureRoute(state, r.id, f.id, r.frequency, r.fare); }
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
      <div class="conn-meta">${r.active ? `<b>${r.frequency}</b>/${max} salidas por sentido · <span class="${mt.net >= 0 ? 'pos' : 'neg'}">${signed(mt.net)}/mes</span>${mt.occupancy > .93 ? ' · <span class="neg">trenes llenos</span>' : ''}` : r.cut ? 'Cortada por obras de cambio de ancho' : unlocked ? (r.real ? `${n(official)} trenes en el horario real` : 'Sin horario: lo pones tú') : glyph('cone') + ' ' + esc(I.faultText(state, E.routeOptions(state, r).hybrid.faults[0] || {type: 'nopath'}))}</div>
      <div class="conn-actions">${r.active ? `<button class="round" data-action="freq-down" data-id="${r.id}" aria-label="Menos trenes" ${r.frequency <= 1 ? 'disabled' : ''}>−</button><button class="round plus" data-action="freq-up" data-id="${r.id}" aria-label="Más trenes" ${r.frequency >= max ? 'disabled' : ''}>+</button>` : unlocked && !r.cut ? `<button class="btn small primary" data-action="open-route" data-id="${r.id}" ${state.ended ? 'disabled' : ''}>Abrir · 4 M€</button>` : ''}<button class="btn small ghost" data-action="route" data-id="${r.id}">Detalles</button></div></div>`;
  }).join('');
  const body = `<div class="city-hero">${citySkyline(id, c.name, pop || 30, level, light, m)}<div class="city-title"><span>${pop ? (pop >= 1000 ? n(pop / 1000, 1) + ' millones de habitantes' : n(pop) + ' mil habitantes') : 'Localidad'}</span><h2>${esc(c.name)}</h2></div></div>
  <div class="city-stats"><div><b>${active.length}/${routes.length}</b><span>conexiones</span></div><div><b>${n(pax / 30)}</b><span>viajeros/día</span></div><div><b class="${monthly >= 0 ? 'pos' : 'neg'}">${signed(monthly)}</b><span>al mes</span></div></div>
  ${incidents.map(x => `<div class="req red"><b>${incidentGlyph(x)} ${esc(x.reason)}</b><span>${esc(routeName(state.routes.find(r => r.id === x.route)))} · demora ${x.delay} min</span><div class="actions">${Object.entries(O.RESPONSES).map(([k, v]) => `<button class="btn small ${k === 'team' ? 'primary' : ''}" data-action="respond" data-id="${x.trip}" data-option="${k}">${esc(v.label)}</button>`).join('')}</div></div>`).join('')}
  ${surges.map(x => `<div class="req gold"><b>${glyph('bolt')} ${esc(x.reason)}</b><span>Refuerza la conexión con ${esc(otherEnd(state.routes.find(r => r.id === x.route), id))} hasta ${x.need} salidas antes de las ${clock(x.until)}.</span><em>+${n(x.bonus * 1000)} mil €</em></div>`).join('')}
  ${reqs.map(q => `<div class="req"><b>${glyph('alert')} ${esc(reqText(q))}</b><span>Plazo: ${E.dateOf(q.until)} · recompensa</span><em>+${q.reward} M€</em><div class="actions"><button class="btn small primary" data-action="request" data-id="${q.id}">${q.type === 'station' ? 'Mejorar estación' : q.type === 'open' ? 'Abrir conexión' : q.type === 'fare' ? 'Bajar tarifa' : q.type === 'ave' ? 'Poner un AVE' : 'Poner más trenes'}</button>${q.type === 'ave' ? `<button class="btn small ghost" data-action="route" data-id="${q.route}">Ver qué falta</button>` : ''}</div></div>`).join('')}
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
  {title: 'Bienvenida', text: 'Hola, soy Raquel Sanz, ministra de Transportes y, desde hoy, tu jefa. Te lo explico rapidito, que a las doce inauguro algo y todavía no sé el qué. Si ya sabes jugar, sáltatelo; yo haré como que me importa.', next: true},
  {title: 'Las ciudades mandan', text: 'Cada círculo es una ciudad. Verde: todo funciona. Ámbar: funciona a la española. Gris: ni está ni se la espera. Pulsa en Madrid, que aquí todo pasa por Madrid, y lo que no pasa, se le obliga.', city: 'mad', when: () => inspect?.type === 'city' && inspect.id === 'mad', enter: () => { map.focusAt(-3.7, 40.4, 1.6); }},
  {title: 'El menú de la ciudad', text: 'Esto es Madrid: sus conexiones, su estación y sus quejas. Lo rojo es AVE, lo azul es Alvia y lo gris es una promesa electoral.', target: '#inspector .city-hero', next: true},
  {title: 'Más trenes', text: 'Pulsa el más en València. Más trenes, más viajeros, más dinero. Hasta tú lo puedes entender.', target: '[data-action=freq-up][data-id=madrid-valencia]', when: () => routeById('madrid-valencia')?.frequency > tut.f0, enter: () => { tut.f0 = routeById('madrid-valencia')?.frequency || 0; }},
  {title: 'Abre una conexión', text: 'Abre la de Salamanca. Es un Alvia: sale por la alta velocidad, se cambia de ancho en Medina del Campo y sigue por la vía de toda la vida. Cuesta cuatro millones, que para lo que se estila es calderilla.', target: '[data-action=open-route][data-id=madrid-salamanca]', when: () => routeById('madrid-salamanca')?.active},
  {title: 'El mapa de anchos', text: 'Pulsa «Anchos». Rojo es ancho estándar: por ahí va el AVE. Naranja es el ibérico de toda la vida: solo Alvia. Morado es mixto: valen los dos. Los rombos son cambiadores, donde el Alvia se cambia de zapatos.', target: '[data-layer=gauge]', when: () => layer === 'gauge', enter: () => { inspect = null; renderInspector(); }},
  {title: 'La catenaria', mood: 'worried', text: 'Ahora pulsa «Electrificación». Lo discontinuo no tiene catenaria: por ahí solo pasa el Alvia híbrido, quemando gasóleo como si fuera mil novecientos ochenta y cinco.', target: '[data-layer=power]', when: () => layer === 'power'},
  {title: 'Las obras', text: 'Pulsa cualquier tramo del mapa y verás qué admite: electrificar, tercer carril o pasarlo a ancho estándar. El estándar sale barato, pero corta la línea mientras dura. Como todo lo barato.', next: true},
  {title: 'Peticiones', mood: 'angry', text: 'Las ciudades con exclamación te piden cosas. Si una te pide AVE, que no te tiemble el pulso: eso no se arregla con un tren, se arregla con obras. Cumplir da dinero; ignorarlas, titulares.', target: '#mission .requests', next: true, enter: () => { setLayer('network'); inspect = null; renderInspector(); }},
  {title: 'Empieza el día', text: 'Cada jornada empieza con el primer tren y acaba con el último. Pulsa «Comenzar jornada». Con el café en la mano, a ser posible.', target: '[data-action=day-start]', when: () => state.ops.phase === 'running'},
  {title: 'Más deprisa', mood: 'angry', text: 'Pon diez por. Ojalá las obras fueran igual de rápidas.', target: '.speed', when: () => speedIndex >= 2},
  {title: 'Viajeros e ingresos', text: 'Cada tren que llega suma viajeros y dinero, arriba, en «Hoy». Ese dinero es tuyo. Bueno, de Renfe. Bueno, de Hacienda.', target: '#resources', when: () => today.trains >= 6},
  {title: '¡Una avería!', mood: 'worried', text: '¡Una incidencia! Tranquilidad, que esto pasa en las mejores familias. Pulsa «Decidir» y elige. Si es en un cambiador de ancho, ya sabes a quién culpar: al ancho ibérico.', target: '.alert-pill', when: () => state.ops.resolved.length > 0, enter: () => { if (state.ops.phase === 'running' && !O.injectIncident(state, state.ops.minute)) tutorialNext(); }},
  {title: 'Momentos del día', text: 'A veces una ciudad tiene un pico de demanda: un partido, un congreso, un puente. Si refuerzas a tiempo, cobras. Si no, te lo recordarán en las redes.', next: true},
  {title: 'Fin de la jornada', text: 'Pulsa «Hasta el último tren». El último que llegue, que apague la luz.', target: '[data-action=day-end]', when: () => state.ops.phase === 'review'},
  {title: 'El parte del día', mood: 'worried', text: 'El parte del día. Si sale mal, échale la culpa a la meteorología, que es lo que hacemos todos. Pulsa «Siguiente jornada».', target: '#modal [data-action=day-next]', when: () => state.ops.phase === 'planning'},
  {title: 'Compra trenes', text: 'Para crecer necesitas trenes, y tardan dos años en llegar. Abre «Trenes». Los AVE solo van por ancho estándar; los Alvia, por donde les echen.', target: '[data-screen=fleet]', when: () => screen === 'fleet', mood: 'angry'},
  {title: '¡A dirigir!', text: 'Cumple los objetivos del capítulo y te suelto dinero. Y recuerda: si algo sale bien, lo anuncio yo. Si sale mal, has sido tú. ¡Buen viaje!', target: '#mission', next: true},
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
  const html = `<div class="portrait" style="${faceStyle('minister', step.mood)}" aria-hidden="true"></div><div><div class="kicker">Tutorial · ${tut.step + 1}/${TUTORIAL.length}</div><h3>${esc(step.title)}</h3><p data-say="${esc(step.text)}">${sayHtml(step.text)}</p><div class="actions">${step.next ? '<button class="btn small primary" data-action="tutorial-next">Siguiente</button>' : '<button class="btn small ghost" data-action="tutorial-next">Omitir paso</button>'}<button class="btn small ghost" data-action="tutorial-skip">Salir</button></div></div>`;
  const fresh = coach.dataset.step !== String(tut.step);
  if (fresh) { coach.innerHTML = html; coach.dataset.step = tut.step; coach.querySelector('h3').insertAdjacentHTML('beforeend', sayButton('minister', 'coach')); speakIn(coach, 'minister', 'coach'); }
  let rect = null;
  if (step.city) { const c = CITY[step.city], p = map.screenOf(c.lon, c.lat), cr = $('map').getBoundingClientRect(); rect = {left: cr.left + p[0] - 26, top: cr.top + p[1] - 26, width: 52, height: 52, round: true}; }
  else if (step.target) {
    const el = (host === $('modal') ? $('modal') : document).querySelector(step.target);
    if (el && el.offsetParent !== null) { if (fresh) el.scrollIntoView({block: 'center'}); const b = el.getBoundingClientRect(); rect = {left: b.left - 6, top: b.top - 6, width: b.width + 12, height: b.height + 12}; }
  }
  const hostRect = host === document.body ? {left: 0, top: 0, right: innerWidth, bottom: innerHeight} : host.getBoundingClientRect();
  if (rect) { Object.assign(spot.style, {display: 'block', left: rect.left - hostRect.left + 'px', top: rect.top - hostRect.top + 'px', width: rect.width + 'px', height: rect.height + 'px', borderRadius: rect.round ? '50%' : '14px'}); }
  else spot.style.display = 'none';
  // el globo no sale nunca de su contenedor (la pantalla o la ventana abierta)
  const W = coach.offsetWidth || 380, H = coach.offsetHeight || 170, L = hostRect.left, T = hostRect.top, R = hostRect.right, B = hostRect.bottom;
  let x = rect ? rect.left + rect.width / 2 - W / 2 : (L + R) / 2 - W / 2, y = rect ? (rect.top + rect.height + H + 24 < B ? rect.top + rect.height + 14 : rect.top - H - 14) : (T + B) / 2 - H / 2;
  x = Math.max(L + 12, Math.min(R - W - 12, x)); y = Math.max(T + 12, Math.min(B - H - 12, y));
  coach.style.left = x - hostRect.left + 'px'; coach.style.top = y - hostRect.top + 'px';
}

// ------------------------------------------------------------ selección en el mapa
function pick(hit) {
  sfx.play(!hit ? (inspect ? 'deselect' : 'tick') : {route: 'pickRoute', city: 'pickCity', train: 'pickTrain', station: 'pickStation', work: 'pickWork', tramo: 'pickRoute', node: 'pickStation'}[hit.type] || 'tap', {i: hashOf(hit?.id ?? '')});
  if (!hit) { if (inspect) { inspect = null; map.selected = null; map.selectedTrain = null; map.selectedCity = null; map.selectedTramo = null; map.follow = false; renderInspector(); } return; }
  if (hit.type === 'route') return selectRoute(hit.id, false);
  map.selectedCity = null; map.selectedTramo = null;
  if (hit.type === 'tramo') { inspect = {type: 'tramo', id: hit.id}; map.selectedTramo = hit.id; map.selected = null; map.selectedTrain = null; }
  if (hit.type === 'node') { inspect = {type: 'node', id: hit.id}; map.selected = null; map.selectedTrain = null; }
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
    el.innerHTML = `<span>${glyph('bolt')}</span><span><b>${esc(x.reason)}</b> · ${esc(x.place)}</span><button class="btn small gold" data-action="city" data-id="${x.city}">Ver ciudad</button>`;
    $('game').appendChild(el); clearTimeout(alertTimer); alertTimer = setTimeout(() => el.remove(), 12000); return;
  }
  document.querySelector('.alert-pill')?.remove();
  const el = document.createElement('div');
  el.className = 'alert-pill';
  el.innerHTML = `<span>${incidentGlyph(x)}</span><span><b>${esc(x.reason)}</b> · ${esc(routeName(r))}${x.place ? ' · ' + esc(x.place) : ''}</span><button class="btn small gold" data-action="open-incidents">Decidir</button>`;
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
  }).join('')}</ul>${(state.requests || []).length || liveSurges().length ? `<div class="requests"><div class="kicker">Peticiones de las ciudades</div>${liveSurges().map(x => `<button data-action="city" data-id="${x.city}"><b>${glyph('bolt')} ${esc(CITY[x.city]?.name)}</b><span>${esc(x.reason)} · hasta ${clock(x.until)}</span><em>+${n(x.bonus * 1000)}k€</em></button>`).join('')}${(state.requests || []).map(q => `<button data-action="city" data-id="${q.city}"><b>${glyph('alert')} ${esc(CITY[q.city]?.name)}</b><span>${esc(reqText(q))}</span><em>+${q.reward} M€</em></button>`).join('')}</div>` : ''}`;
}
function renderLegend() {
  const items = {
    works: [['#d18a2a', 'Obra en marcha'], ['#5a4630', 'Tramo terminado'], ['#a06a1c', 'Gran obra por financiar', true]],
    gauge: [[GAUGE_COLOR.std, 'Ancho estándar'], [GAUGE_COLOR.ib, 'Ancho ibérico'], [GAUGE_COLOR.mixto, 'Ancho mixto'], ['#8a7c69', 'Proyectada', true]],
    power: [[ELEC_COLOR['25kv'], '25 kV'], [ELEC_COLOR['3kv'], '3 kV'], [ELEC_COLOR.no, 'Sin catenaria', true], ['#8a7c69', 'Proyectada', true]],
  }[layer] || [[FAMILY_COLOR.AVE, 'AVE'], [FAMILY_COLOR.Alvia, 'Alvia'], ['#8a7c69', layer === 'real' ? 'Trazado aproximado' : 'Por abrir', true]];
  const extra = layer === 'gauge' ? '<span><i class="rombo"></i>Cambiador de ancho</span><span class="muted">Pulsa un tramo o un cambiador</span>' : layer === 'power' ? '<span class="muted">Pulsa un tramo para electrificarlo</span>' : layer === 'works' ? '' :
    '<span><i class="dot" style="border-color:#3f9d5a"></i>Ciudad conectada</span><span><i class="dot" style="border-color:#f0b544"></i>Parcial</span><span><i class="dot" style="border-color:#9c8b74"></i>Sin tren</span><span><i class="pin">!</i>Petición</span><span><i class="crowd">▮▮▮</i>Trenes llenos</span>' + `<span class="muted">${layer === 'real' ? 'AVE y Alvia publicados · ' + S.DAY_TYPES[dayType()] : 'Pulsa una ciudad'}</span>`;
  $('legend').innerHTML = items.map(([c, t, d]) => `<span><i class="${d ? 'dash' : ''}" style="background:${c};color:${c.startsWith('linear') ? GAUGE_COLOR.std : c}"></i>${t}</span>`).join('') + extra;
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
  if (ALIASES[to]) { const [page, key, value] = ALIASES[to]; ui[key] = value; to = page; if (screen === to) { renderDrawer(); return; } }
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
  const pages = {ops: opsPage, network: () => ui.netView === 'timetables' ? withView(timetablesPage()) : withView(networkPage()), fleet: trainsPage, works: worksPage, story: officePage};
  const scroll = el.querySelector('.body')?.scrollTop || 0, focusId = document.activeElement?.id, pos = document.activeElement?.selectionStart;
  const [head, body] = pages[screen]();
  el.innerHTML = head + `<div class="body">${body}</div>`;
  el.classList.remove('hidden');
  el.querySelector('.body').scrollTop = scroll;
  if (focusId && $(focusId)) { $(focusId).focus(); try { $(focusId).setSelectionRange(pos, pos); } catch {} }
  if (screen === 'story' && ui.officeTab === 'finance') drawChart();
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
  const head = header('Centro de control · ' + S.DAY_TYPES[kind], op.phase === 'planning' ? 'Prepara la jornada.' : op.phase === 'running' ? 'El día está en marcha.' : 'La jornada ha terminado.', esc(O.dayLabel(state)) + '.');
  const body = `<dl class="figures"><div><dt>Reloj</dt><dd class="mono">${clock(m)}</dd></div><div><dt>En circulación</dt><dd>${n(moving)}</dd></div><div><dt>Programadas</dt><dd>${n(trips.length)}</dd></div><div><dt>Puntualidad</dt><dd>${done.length ? n((1 - late / done.length) * 100) + ' %' : '—'}</dd></div><div><dt>Primera / última</dt><dd class="mono" style="font-size:19px">${clock(b.first)} · ${clock(b.last)}</dd></div></dl>
  ${reached.length ? `<h2 class="section">Incidencias</h2>${reached.map(x => {
    const r = state.routes.find(r => r.id === x.route), choice = op.choices?.[x.trip], solved = op.resolved.includes(x.trip);
    return `<div class="incident"><div class="split"><strong>${incidentGlyph(x)} ${esc(x.reason)}</strong><span class="status ${solved ? 'on' : 'late'}">${solved ? esc(O.RESPONSES[choice || 'team'].label) : 'Pendiente'}</span></div>
    <p>${esc(routeName(r))} · ${esc(x.label || '')}${x.place ? ' · cerca de ' + esc(x.place) : ''} · ${clock(x.at)} · demora estimada ${x.delay} min${x.type === 'weather' ? ' durante ' + Math.round(x.span / 60) + ' h' : ''}</p>
    ${solved || op.phase !== 'running' ? '' : `<div class="actions">${Object.entries(O.RESPONSES).map(([k, v]) => `<button class="btn small ${k === 'team' ? 'primary' : ''}" data-action="respond" data-id="${x.trip}" data-option="${k}" title="${esc(v.note)}">${esc(v.label)}${v.cost ? ' · ' + n(v.cost * 1000) + ' mil €' : ''}</button>`).join('')}</div>`}</div>`;
  }).join('')}` : ''}
  <div class="toolbar"><label style="margin:0">Prioridad de explotación</label><select id="dayPriority" ${op.phase !== 'planning' ? 'disabled' : ''}><option value="balanced" ${op.priority === 'balanced' ? 'selected' : ''}>Equilibrio entre coste y puntualidad</option><option value="punctual" ${op.priority === 'punctual' ? 'selected' : ''}>Refuerzo de puntualidad · 9.000 €/día</option></select>
  <label style="margin:0 0 0 auto"><input type="checkbox" id="autoPause" ${ui.autoPause ? 'checked' : ''}> Pausar ante incidencias</label></div>
  <h2 class="section">Próximas salidas</h2>
  <div class="board"><div class="row head"><span>Hora</span><span>Línea</span><span>Recorrido</span><span>Estado</span></div>${boardRows(next, m) || '<div class="row"><span></span><span></span><span>No quedan salidas programadas.</span></div>'}</div>
  ${!trips.length ? '<div class="empty">No hay servicios abiertos. Abre una línea en <b>Red</b> para empezar a circular.</div>' : ''}
`;
  return [head, body];
}

function networkPage() {
  const q = ui.routeQuery.toLowerCase();
  const tabs = [['all', 'Todas'], ['AVE', 'AVE'], ['Alvia', 'Alvia'], ['new', 'Sin tren todavía']];
  const statuses = [['all', 'Cualquier estado'], ['active', 'En servicio'], ['closed', 'Por abrir'], ['blocked', 'Sin vía posible'], ['works', 'Con obras']];
  const list = state.routes.filter(r => {
    const fam = familyOf(r), [cls] = statusOf(r);
    if (ui.routeTab === 'AVE' && fam !== 'AVE') return false;
    if (ui.routeTab === 'Alvia' && fam !== 'Alvia') return false;
    if (ui.routeTab === 'new' && r.real) return false;
    if (ui.routeStatus === 'active' && !r.active) return false;
    if (ui.routeStatus === 'closed' && cls !== 'off') return false;
    if (ui.routeStatus === 'blocked' && cls !== 'blocked') return false;
    if (ui.routeStatus === 'works' && !workOn(r) && !r.cut) return false;
    return !q || (routeName(r) + ' ' + (fam || '')).toLowerCase().includes(q);
  }).sort((a, b) => b.active - a.active || b.real - a.real || (S.routeStats(b.id, 'L')?.trips || 0) - (S.routeStats(a.id, 'L')?.trips || 0));
  const row = r => {
    const [cls, label] = statusOf(r), m = r.active ? E.metrics(state, r) : null, trips = r.real ? (S.routeStats(r.id, 'L')?.trips || 0) : null, o = E.routeOptions(state, r);
    const can = [['ave', 'AVE'], ['alvia', 'Alvia'], ['hybrid', 'Híbrido']].map(([k, t]) => `<i class="can ${o[k].ok ? 'ok' : ''}">${t}</i>`).join('');
    return `<tr class="clickable" data-action="route" data-id="${r.id}"><td>${routeChip(r)}</td><td><strong>${esc(routeName(r))}</strong><small>${n(r.km)} km ${can}</small></td>
    <td class="num">${trips !== null ? n(trips) : '<span class="muted">—</span>'}</td><td><span class="status ${workOn(r) ? 'works' : cls}">${workOn(r) ? 'Con obras' : label}</span>${r.active ? `<small>${r.frequency}/${E.maxFrequency(r)} por sentido</small>` : ''}</td>
    <td class="num">${m ? n(m.passengers) : '—'}</td><td class="num ${m ? (m.net >= 0 ? 'pos' : 'neg') : ''}">${m ? signed(m.net) : '—'}</td></tr>`;
  };
  let body = `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.routeTab === k ? 'active' : ''}" data-action="route-tab" data-id="${k}">${t}</button>`).join('')}</div>
  <div class="toolbar"><input type="search" id="routeSearch" placeholder="Busca una ciudad" value="${esc(ui.routeQuery)}" aria-label="Buscar relación"><select id="routeStatus" aria-label="Estado">${statuses.map(([k, t]) => `<option value="${k}" ${ui.routeStatus === k ? 'selected' : ''}>${t}</option>`).join('')}</select><button class="btn" data-action="new-service" ${state.ended ? 'disabled' : ''}>Relación nueva</button></div>`;
  body += `<table><thead><tr><th></th><th>Relación</th><th class="num">Trenes / día</th><th>Estado</th><th class="num">Viajeros / mes</th><th class="num">Resultado</th></tr></thead><tbody>${list.map(row).join('')}</tbody></table>`;
  if (!list.length) body += '<div class="empty">Nada por aquí.</div>';
  return [header('Red y servicios', 'AVE donde se pueda; Alvia donde no.', 'Lo que puede circular depende del ancho y la catenaria de cada tramo. Abrir un servicio cuesta 4 M€.'), body];
}

/** Red y horarios comparten página: un selector arriba cambia de vista. */
function withView([head, body]) {
  const views = [['routes', 'Relaciones'], ['timetables', 'Horarios']];
  return [head, `<div class="segmented">${views.map(([k, t]) => `<button class="${ui.netView === k ? 'active' : ''}" data-action="net-view" data-id="${k}">${t}</button>`).join('')}</div>` + body];
}
function trainsPage() {
  const tabs = [['fleet', 'Parque y taller'], ['market', 'Comprar'], ['orders', 'Pedidos']];
  const [, body] = ['market', 'orders'].includes(ui.fleetTab) ? marketPage(ui.fleetTab === 'market' ? 'catalogue' : 'orders') : fleetPage();
  return [header('Trenes', 'Los que tienes y los que vienen.', 'Los AVE solo van por ancho estándar. Los Alvia, por donde les echen.'), `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.fleetTab === k ? 'active' : ''}" data-action="fleet-tab" data-id="${k}">${t}</button>`).join('')}</div>` + body];
}
function officePage() {
  const tabs = [['campaign', 'Campaña'], ['finance', 'Cuentas'], ['journal', 'Diario']];
  const [, body] = ui.officeTab === 'finance' ? financePage() : ui.officeTab === 'journal' ? archivePage() : storyPage();
  return [header('Despacho', 'Tu mandato, tus cuentas y lo que se dice de ti.'), `<div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.officeTab === k ? 'active' : ''}" data-action="office-tab" data-id="${k}">${t}</button>`).join('')}</div>` + body];
}

function timetablesPage() {
  const type = ui.ttType || dayType(), all = realTrips(type);
  const q = ui.ttStation.trim().toLowerCase();
  const fold = x => x.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase(), tokens = fold(q).split(/[^a-z0-9ñ]+/).filter(Boolean);
  const stations = q.length >= 2 ? S.STATIONS.filter(s => s.traffic && tokens.every(t => fold(s.name).includes(t))).sort((a, b) => b.traffic - a.traffic).slice(0, 12) : [];
  const station = stations.find(s => s.name.toLowerCase() === q) || (stations.length === 1 ? stations[0] : null) || (ui.ttStationId !== undefined ? S.STATIONS[ui.ttStationId] : null);
  let body = `<div class="tabs">${Object.entries(S.DAY_TYPES).map(([k, t]) => `<button class="${type === k ? 'active' : ''}" data-action="tt-type" data-id="${k}">${t} <span class="muted">${n(S.dayTrips(k).length)}</span></button>`).join('')}</div>
  <dl class="figures"><div><dt>Circulaciones</dt><dd>${n(all.length)}</dd></div><div><dt>AVE</dt><dd>${n(all.filter(t => S.lineCode(t.line) === 'AVE').length)}</dd></div><div><dt>Alvia</dt><dd>${n(all.filter(t => S.lineCode(t.line) === 'Alvia').length)}</dd></div><div><dt>Estaciones</dt><dd>${n(S.STATIONS.filter(s => s.traffic).length)}</dd></div></dl>
  <div class="toolbar"><input type="search" id="ttStation" placeholder="Busca una estación: Atocha, Sants, Zaragoza…" value="${esc(ui.ttStation)}" aria-label="Buscar estación"><label style="margin:0">Desde</label><select id="ttHour">${Array.from({length: 22}, (_, i) => i + 4).map(h => `<option value="${h}" ${ui.ttHour === h ? 'selected' : ''}>${String(h % 24).padStart(2, '0')}:00</option>`).join('')}</select></div>`;
  if (stations.length > 1 && !station) body += `<div class="rows">${stations.map(s => `<div><span class="chip" style="background:#2a1f1c">${n(s.traffic)}</span><div><h3>${esc(s.name)}</h3><p>${n(s.traffic)} circulaciones en laborable</p></div><button class="btn small" data-action="tt-station" data-id="${s.i}">Ver salidas</button></div>`).join('')}</div>`;
  if (station) {
    const from = ui.ttHour * 60;
    const deps = [];
    for (const t of all) { const j = t.trip.stations.indexOf(station.i); if (j < 0 || j === t.trip.stations.length - 1) continue; const dep = t.trip.times[j * 2 + 1]; if (dep >= from) deps.push({t, dep}); }
    deps.sort((a, b) => a.dep - b.dep);
    body += `<div class="group-title"><h2>${esc(station.name)}</h2><span>${n(deps.length)} salidas desde las ${String(ui.ttHour).padStart(2, '0')}:00</span><button class="btn small" data-action="station-map" data-id="${station.i}">Ver en el mapa</button></div>
    <div class="board"><div class="row head"><span>Salida</span><span>Tren</span><span>Destino</span><span>Número</span></div>${deps.slice(0, 80).map(({t, dep}) => `<div class="row"><span>${clock(dep)}</span><span>${chip(S.lineCode(t.line), S.LINES[t.line].color)}</span><button class="dest" data-action="real-trip" data-id="${t.id}">${esc(S.STATIONS[t.trip.stations.at(-1)].name)}</button><span>${esc(t.trip.number || '—')}</span></div>`).join('')}</div>${deps.length > 80 ? '<p class="note">Se muestran 80 salidas. Cambia la hora para ver más.</p>' : ''}`;
  }
  if (!station && stations.length === 0) {
    const busiest = S.STATIONS.filter(s => s.traffic).sort((a, b) => b.traffic - a.traffic).slice(0, 12);
    body += `<h2 class="section">Las estaciones con más trenes</h2><div class="rows">${busiest.map(s => `<div><span class="chip" style="background:#2a1f1c">${n(s.traffic)}</span><div><h3>${esc(s.name)}</h3><p>circulaciones en laborable</p></div><button class="btn small" data-action="tt-station" data-id="${s.i}">Ver salidas</button></div>`).join('')}</div>`;
  }
  return [header('Horarios', 'Todos los AVE y Alvia, a su hora.', 'Busca una estación para ver su panel de salidas o sigue cualquier tren en el mapa.'), body];
}

function fleetPage() {
  let body = '';
  if (ui.fleetTab === 'fleet') {
    const total = state.fleet.reduce((v, f) => v + f.qty, 0), free = state.fleet.reduce((v, f) => v + E.available(state, f), 0);
    const count = fam => state.fleet.filter(f => MODEL[f.model].family === fam).reduce((v, f) => v + f.qty, 0);
    body += `<dl class="figures"><div><dt>Unidades</dt><dd>${n(total)}</dd></div><div><dt>AVE</dt><dd>${n(count('AVE'))}</dd></div><div><dt>Alvia</dt><dd>${n(count('Alvia'))}</dd></div><div><dt>Libres</dt><dd>${n(free)}</dd></div></dl>
    <table><thead><tr><th style="width:150px"></th><th>Material</th><th class="num">Parque</th><th class="num">Libres</th><th>Estado</th></tr></thead><tbody>${state.fleet.filter(f => f.qty > 0).map(f => {
      const m = MODEL[f.model];
      return `<tr class="clickable" data-action="fleet-detail" data-id="${f.id}"><td>${trainThumb(f.model)}</td><td><strong>${esc(m.name)}</strong><small>${esc(f.origin)} · desde ${f.born} · ${GAUGES[m.gauge]} · ${POWERS[m.power]}</small></td><td class="num">${f.qty}</td><td class="num">${E.available(state, f)}</td><td style="min-width:120px"><div class="bar ${f.condition < 50 ? '' : 'green'}"><span style="width:${f.condition}%"></span></div><small>${n(f.condition)} %</small></td></tr>`;
    }).join('')}</tbody></table><p class="note">Solo se venden o reforman trenes libres: quítalos antes de alguna línea.</p>`;
    body += `<h2 class="section">Taller</h2>` + (state.refits.length ? `<div class="rows">${state.refits.map(r => `<div><span class="status ${r.done ? 'on' : 'works'}"></span><div><h3>${esc(MODEL[r.model].name)} · ${r.qty} unidades</h3><p>${r.done ? 'Reforma terminada' : 'Salen del taller en ' + E.dateOf(r.due)}</p></div><span></span></div>`).join('')}</div>` : '<div class="empty">El taller está vacío. Los mecánicos, encantados.</div>');
    body += '<p class="note">Una reforma cuesta el 12 % del precio y dura cinco meses. El tren vuelve casi nuevo.</p>';
  }
  return [header('Flota y talleres', 'Los trenes que tienes, no los que te prometieron.'), body];
}

function marketPage(view) {
  let body = '';
  if (view === 'catalogue') {
    body += `<div class="catalogue">${MODELS.filter(m => m.year < 2099).map(m => {
      const unlocked = E.yearOf(state) >= m.year, q = E.purchaseQuote(state, m.id, 1);
      return `<div>${trainThumb(m.id)}<div><h3>${chip(m.family, FAMILY_COLOR[m.family])} ${esc(m.name)}</h3><p>${esc(m.desc)}</p><div class="specline"><span><b>${m.speed}</b> km/h</span><span><b>${n(m.seats)}</b> plazas</span><span>${GAUGES[m.gauge]}</span><span>${POWERS[m.power]}</span><span>entrega en <b>${m.lead}</b> meses</span><span>${esc(m.maker)}</span></div></div>
      <div style="text-align:right"><strong style="font:600 20px var(--serif)">${money(q.total)}</strong><br><button class="btn small ${unlocked ? 'primary' : ''}" data-action="purchase" data-id="${m.id}" ${!unlocked || state.ended ? 'disabled' : ''}>${unlocked ? 'Encargar' : 'Desde ' + m.year}</button></div></div>`;
    }).join('')}</div><p class="note">Precio por unidad. Anticipo del 30 % al firmar y el resto en cada entrega.</p>`;
  } else {
    const orders = state.orders.filter(o => !o.historical);
    body += orders.length ? `<div class="rows">${orders.map(o => `<div><span class="status ${o.delivered === o.qty ? 'on' : 'works'}"></span><div><h3>${esc(MODEL[o.model].name)} · ${o.qty} unidades</h3><p>${o.delivered === o.qty ? 'Pedido completo' : 'Próximo lote: ' + E.dateOf(o.next)}${o.delay ? ' · ' + o.delay + ' meses de retraso' : ''} · ${money(o.remaining)} pendiente</p><div class="bar gold"><span style="width:${o.delivered / o.qty * 100}%"></span></div></div><span class="num">${o.delivered}/${o.qty}</span></div>`).join('')}</div>` : '<div class="empty">No has encargado ni un tren. Así no se crece.</div>';
    body += `<h2 class="section">Contratos heredados</h2><table><thead><tr><th>Contrato</th><th class="num">Unidades</th><th>Estado</th></tr></thead><tbody>${HISTORICAL_ORDERS.map(h => {
      const o = state.orders.find(x => x.id === h.id);
      return `<tr><td><strong>${esc(h.name)}</strong></td><td class="num">${h.qty}</td><td>${h.signed > state.month ? 'Desde ' + (2022 + Math.floor(h.signed / 12)) : h.tender ? 'Licitación' : `${o?.delivered || 0}/${h.qty} recibidos`}</td></tr>`;
    }).join('')}</tbody></table><p class="note">Contratos firmados antes de tu llegada: no los pagas tú, pero sus trenes sí son tuyos.</p>`;
  }
  return [header('Compras de material', 'Un buen pedido se hace con tiempo.', 'Plazos de unos dos años, si el fabricante no se retrasa. Que se retrasará.'), body];
}

function worksPage() {
  const tabs = [['conv', 'Vías y catenaria'], ['changers', 'Cambiadores'], ['projects', 'Alta velocidad nueva'], ['running', 'En marcha']];
  const running = state.projects.filter(p => !p.done);
  let body = `<div class="toolbar"><button class="btn" data-action="layer" data-id="gauge">Mapa de anchos</button><button class="btn" data-action="layer" data-id="power">Mapa de electrificación</button><button class="btn" data-action="layer" data-id="works">Obras en el mapa</button></div>
  <div class="tabs">${tabs.map(([k, t]) => `<button class="${ui.worksTab === k ? 'active' : ''}" data-action="works-tab" data-id="${k}">${t}${k === 'running' && running.length ? ` <span class="muted">${running.length}</span>` : ''}</button>`).join('')}</div>`;
  if (ui.worksTab === 'running') {
    body += running.length ? `<div class="rows">${running.map(p => {
      const st = O.constructionStatus(state, p), name = p.type === 'upgrade' ? 'Mejora de servicio · ' + routeName(routeById(p.route)) : map.workName(p);
      return `<div><span class="status works"></span><div><h3>${esc(name)}</h3><p>${p.type === 'tramo' ? esc(I.WORKS[p.work].label) + ' · ' : ''}${st.stage} · fin previsto ${E.dateOf(p.due)}${p.delay ? ' · +' + p.delay + ' meses' : ''}</p><div class="bar gold" style="margin-top:8px"><span style="width:${st.progress * 100}%"></span></div></div><button class="btn small" data-action="visit-work" data-id="${p.id}">Ver</button></div>`;
    }).join('')}</div>` : '<div class="empty">No hay ni una máquina trabajando. Adif lo agradece.</div>';
  } else if (ui.worksTab === 'projects') {
    body += `<div class="rows">${PROJECTS.map(p => {
      const job = state.projects.find(j => j.id === p.id), st = job ? O.constructionStatus(state, job) : null, km = I.TRAMOS.filter(t => t.plan === p.id).reduce((v, t) => v + t.km, 0);
      return `<div><span class="status ${job ? (job.done ? 'on' : 'works') : 'off'}"></span><div><h3>${esc(p.name)}</h3><p>${esc(p.region)} · ${n(km)} km · ${esc(p.desc)}</p>${job ? `<div class="bar gold" style="margin-top:8px"><span style="width:${st.progress * 100}%"></span></div><p class="small">${job.done ? 'En servicio' : st.stage + ' · ' + n(st.progress * 100) + ' % · fin previsto ' + E.dateOf(job.due)}</p>` : `<p class="small muted">${p.duration} meses de obra, nunca antes de ${p.earliest}.</p>`}</div>
      <div style="text-align:right;white-space:nowrap">${job ? `<button class="btn small" data-action="visit-work" data-id="${p.id}">Ver</button>` : `<strong>${money(p.cost)}</strong><br><button class="btn small primary" data-action="project" data-id="${p.id}" ${state.ended ? 'disabled' : ''}>Financiar</button>`}</div></div>`;
    }).join('')}</div><div class="toolbar"><button class="btn primary" data-action="new-line" ${state.ended ? 'disabled' : ''}>Trazar una línea propia</button></div>`;
  } else if (ui.worksTab === 'changers') {
    const nodes = Object.values(I.NODES).filter(nd => state.infra.c.includes(nd.id) || I.changerPossible(state, nd.id) || state.projects.some(p => !p.done && p.type === 'changer' && p.target === nd.id));
    body += `<p class="small">Un Alvia solo cambia de ancho donde hay cambiador. Sin él, se queda mirando la vía de enfrente.</p><div class="rows">${nodes.sort((a, b) => a.name.localeCompare(b.name)).map(nd => {
      const has = state.infra.c.includes(nd.id), job = state.projects.find(p => !p.done && p.type === 'changer' && p.target === nd.id);
      return `<div><span class="status ${has ? 'on' : job ? 'works' : 'off'}"></span><div><h3>${esc(nd.name)}</h3><p>${has ? 'En servicio' + (nd.changer && nd.changer !== nd.name ? ' · ' + esc(nd.changer) : '') : job ? 'En obras · listo en ' + E.dateOf(job.due) : 'Se cruzan los dos anchos y no hay forma de pasar'}</p></div>
      <div style="text-align:right">${has ? `<button class="btn small" data-action="node" data-id="${nd.id}">Ver</button>` : job ? '' : `<strong>${money(I.CHANGER_WORK.cost)}</strong><br><button class="btn small primary" data-action="work" data-work="changer" data-id="${nd.id}" ${state.ended ? 'disabled' : ''}>Construir</button>`}</div></div>`;
    }).join('')}</div>`;
  } else {
    const list = I.allTramos(state).filter(d => state.infra.t[d.id]?.b && (I.tramoWorks(state, d.id).length || state.projects.some(p => !p.done && p.type === 'tramo' && p.target === d.id)));
    body += `<p class="small">Tramos que admiten obra: catenaria donde no hay, tercer carril para que pasen los dos anchos o ancho estándar para siempre (más barato, pero corta la línea mientras dura).</p>
    <table><thead><tr><th>Tramo</th><th>Ancho</th><th>Catenaria</th><th>Obras</th></tr></thead><tbody>${list.sort((a, b) => a.name.localeCompare(b.name)).map(d => {
      const st = state.infra.t[d.id], job = state.projects.find(p => !p.done && p.type === 'tramo' && p.target === d.id);
      return `<tr><td><button class="linkish" data-action="tramo" data-id="${d.id}"><strong>${esc(d.name)}</strong></button><small>${n(d.km)} km · ${st.v} km/h</small></td><td>${chip(I.GAUGE_LABEL[st.g], GAUGE_COLOR[st.g])}</td><td>${chip(I.ELEC_LABEL[st.e], ELEC_COLOR[st.e])}</td>
      <td>${job ? `<span class="status works">${esc(I.WORKS[job.work].label)} · ${E.dateOf(job.due)}</span>` : I.tramoWorks(state, d.id).map(w => `<button class="btn small" data-action="work" data-work="${w.work}" data-id="${d.id}" ${state.ended ? 'disabled' : ''}>${esc(w.verb)} · ${money(w.cost)}</button>`).join(' ')}</td></tr>`;
    }).join('')}</tbody></table>`;
  }
  return [header('Obras', 'Las vías del próximo capítulo.', 'Ancho, catenaria, cambiadores y líneas nuevas. Pulsa un tramo en los mapas de anchos o de electrificación para verlo de cerca.'), body];
}

function financePage() {
  const b = E.balance(state), commit = state.orders.filter(o => !o.historical).reduce((v, o) => v + o.remaining, 0), works = state.projects.filter(p => !p.done).length;
  const body = `<dl class="figures"><div><dt>Tesorería</dt><dd>${money(state.cash)}</dd></div><div><dt>Resultado mensual</dt><dd class="${b.net >= 0 ? 'pos' : 'neg'}">${signed(b.net)}</dd></div><div><dt>Deuda</dt><dd>${money(state.debt)}</dd></div><div><dt>Pedidos pendientes</dt><dd>${money(commit)}</dd></div></dl>
  <h2 class="section">Cuenta del mes</h2><table><tbody>${[['Billetes', b.revenue], ['Ayudas a los Alvia y apoyo público', b.subsidy], ['Operación, canon, mantenimiento y sede', -b.cost], ['Resultado', b.net]].map(([t, v], i) => `<tr><td>${i === 3 ? '<strong>' + t + '</strong>' : t}</td><td class="num ${v >= 0 ? 'pos' : 'neg'}">${i === 3 ? '<strong>' + signed(v) + '</strong>' : signed(v)}</td></tr>`).join('')}</tbody></table>
  <h2 class="section">Tesorería</h2>${state.history.length >= 2 ? '<canvas id="cashChart" class="chart" role="img" aria-label="Gráfico de tesorería mensual"></canvas>' : '<p class="small muted">La gráfica sale cuando cierres el primer mes. Hacienda tampoco tiene prisa.</p>'}
  <h2 class="section">Financiación y mantenimiento</h2><div class="toolbar"><button class="btn" data-action="borrow" ${state.debt >= 1500 || state.ended ? 'disabled' : ''}>Pedir 100 M€</button><button class="btn" data-action="repay" ${state.debt < 100 || state.cash < 100 || state.ended ? 'disabled' : ''}>Devolver 100 M€</button></div>
  <label for="maintenance">Esfuerzo de mantenimiento: <strong>${n(state.maintenance * 100)} %</strong></label><input id="maintenance" type="range" min="0.6" max="1.5" step="0.1" value="${state.maintenance}" ${state.ended ? 'disabled' : ''}>
  ${works ? `<p class="note">${works} obra${works === 1 ? '' : 's'} en marcha: ya están pagadas.</p>` : ''}`;
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
  const body = `${state.ended ? `<div class="callout"><strong>${state.ending === '2050' ? '31 de diciembre de 2050' : 'Intervención de la compañía'}</strong><br>Tu legado: <b>${score}/100</b>. ${state.routes.filter(r => r.active).length} servicios, ${n(E.dailyTrains(state))} circulaciones diarias, ${E.aveCities(state).size} ciudades con AVE y ${n(state.stats.passengers / 1e6, 1)} millones de viajes.</div>` : ''}
  <div class="chapters">${CHAPTERS.map((ch, i) => `<div class="${state.claimed.includes(ch.id) ? 'done' : i === state.chapter ? 'now' : ''}"><strong>${esc(ch.title)}</strong>${ch.years}</div>`).join('')}</div>
  <div class="story"><div class="portrait" style="${faceStyle(c.speaker, c.mood)}" role="img" aria-label="${esc(person.name)}"></div><div><div class="kicker" style="color:var(--wine);font-weight:700;font-size:11.5px;letter-spacing:1.4px;text-transform:uppercase">${esc(person.name)} · ${esc(person.role)}</div><h2 class="section" style="margin-top:4px">${esc(c.title)} ${sayButton(c.speaker, 'story')}</h2><p data-say="${esc(c.text)}">${sayHtml(c.text)}</p>
  <ul class="objectives">${c.objectives.map(([k, target, title]) => { const v = E.objectiveValue(state, k); return `<li class="${v >= target ? 'done' : ''}"><i></i><span>${esc(title)}</span><span class="num">${k === 'solvent' ? (v ? '✓' : '—') : n(Math.min(v, target)) + ' / ' + n(target)}</span></li>`; }).join('')}</ul>
  <div class="toolbar"><button class="btn primary" data-action="claim" ${!E.chapterReady(state) || state.ended ? 'disabled' : ''}>${state.claimed.includes(c.id) ? 'Capítulo completado' : 'Reclamar ' + c.reward + ' M€'}</button><button class="btn" data-action="navigate" data-screen="network">Gestionar la red</button></div>
  ${E.yearOf(state) < c.year ? `<p class="callout">Esta etapa empieza en ${c.year}. Ve adelantando trabajo.</p>` : ''}</div></div>
  <div class="toolbar" style="margin-top:30px"><button class="btn" data-action="save-dialog">Guardar o exportar</button><button class="btn danger" data-action="new-game">Nueva campaña</button></div>`;
  return [header('Campaña 2022–2050', 'Tu mandato, tu historia.', 'Cada capítulo trae dinero para el siguiente.'), body];
}

function archivePage() {
  const body = state.log.length ? state.log.map(l => `<div class="news"><time>${E.dateOf(l.month)}</time><div><h3>${esc(l.title)}</h3><p>${esc(l.body)}</p></div></div>`).join('') : '<div class="empty">Todavía no ha pasado nada digno de mención.</div>';
  return [header('Diario', 'Lo que ha pasado en tu mandato.'), body];
}

// ------------------------------------------------------------ inspector
function renderInspector() {
  const el = $('inspector');
  renderMission();
  if (!inspect) { el.classList.add('hidden'); map.selected = null; map.selectedCity = null; return; }
  if (inspect.type !== 'city') map.selectedCity = null;
  if (inspect.type !== 'tramo') map.selectedTramo = null;
  const fn = {route: routeInspector, train: trainInspector, station: stationInspector, work: workInspector, city: cityInspector, tramo: tramoInspector, node: nodeInspector}[inspect.type];
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
function optionRow(label, p) {
  return `<div class="option ${p.ok ? 'ok' : 'no'}"><b>${label}</b>${p.ok ? `<span>${clock(p.minutes).replace(/^0/, '')} h · ${n(p.km)} km${p.changes.length ? ' · cambia de ancho en ' + esc(p.changes.map(x => I.NODES[x]?.name || x).join(', ')) : ''}</span>` : `<ul>${faultList(p.faults)}</ul>`}</div>`;
}
function routeInspector() {
  const r = state.routes.find(r => r.id === inspect.id);
  if (!r) return null;
  map.selected = r.id;
  const unlocked = E.isUnlocked(state, r), [cls, label] = statusOf(r), work = workOn(r), stats = r.real ? S.routeStats(r.id, dayType()) || S.routeStats(r.id, 'L') : null, o = E.routeOptions(state, r);
  const lots = state.fleet.filter(f => f.qty > 0), compatible = lots.filter(f => E.canRun(state, r, MODEL[f.model]));
  const maxF = E.maxFrequency(r), freq = r.active ? r.frequency : Math.max(1, Math.round(maxF * (r.real ? .5 : .25)));
  const todays = r.real ? S.thin(S.routeTrips(dayType(), r.id), r.active ? Math.min(1, r.frequency / r.baseFrequency) : 1) : [];
  const m = E.metrics(state, r);
  let body = `<p><span class="status ${work ? 'works' : cls}">${work ? 'Con obras · ' + O.constructionStatus(state, work).stage : label}</span></p>
  <dl class="figures"><div><dt>Horario oficial</dt><dd>${r.real ? n(stats?.trips || 0) : '—'}</dd><em>${r.real ? 'circulaciones · ' + S.DAY_TYPES[dayType()].toLowerCase() : 'sin horario: lo pones tú'}</em></div><div><dt>Longitud</dt><dd>${n(r.km)} km</dd></div>${r.real ? `<div><dt>Trayecto</dt><dd>${clock(r.minutes).replace(/^0/, '')} h</dd></div><div><dt>Pico</dt><dd>${r.peak}</dd><em>trenes a la vez</em></div>` : ''}</dl>
  <h2 class="section">Qué puede circular</h2><div class="options">${optionRow('AVE', o.ave)}${optionRow('Alvia', o.alvia)}${optionRow('Alvia híbrido', o.hybrid)}</div>
  ${r.real ? `<h3>Salidas a lo largo del día ${r.active ? '(tu oferta)' : '(horario oficial)'}</h3>${hourHistogram(todays.map(t => ({dep: t.start})), currentMinute())}` : ''}`;
  if (r.cut) body += `<p class="callout red">Cortada mientras duren las obras de cambio de ancho.</p>`;
  if (!unlocked) body += `<p class="callout">Hoy no puede circular ningún tren por esta relación. Arregla lo que falta en <b>Obras</b>.</p><button class="btn" data-action="navigate" data-screen="works">Ir a Obras</button>`;
  else if (!r.cut) body += `<h2 class="section">Plan de servicio</h2><form id="routeForm">
    <label for="routeFleet">Material</label><select id="routeFleet" required style="width:100%">${lots.map(f => { const ok = E.canRun(state, r, MODEL[f.model]); return `<option value="${f.id}" ${r.fleet === f.id ? 'selected' : ''} ${ok ? '' : 'disabled'}>${esc(MODEL[f.model].name)} · ${ok ? E.available(state, f, r.id) + ' libres · ' + n(f.condition) + ' %' : 'no puede ir por esta vía'}</option>`; }).join('')}</select>
    <label for="frequency">Salidas por sentido: <strong id="freqOut">${freq}</strong> de ${maxF}${r.real ? ' del horario oficial' : ''}</label><input id="frequency" type="range" min="1" max="${maxF}" step="1" value="${freq}">
    <label for="fare">Tarifa media (€)</label><input id="fare" type="number" min="1.5" max="150" step="0.1" value="${r.fare}" style="width:120px">
    <p id="routePreview" class="callout"></p>
    <div class="toolbar"><button class="btn primary" type="submit" ${!compatible.length || state.ended ? 'disabled' : ''}>${r.active ? 'Aplicar plan' : 'Abrir servicio · 4 M€'}</button>${r.active ? `<button class="btn danger" type="button" data-action="close-service" data-id="${r.id}">Suspender</button>` : ''}</div></form>
    <div class="toolbar"><button class="btn small" data-action="upgrade" data-id="${r.id}" ${r.level >= 3 || state.ended ? 'disabled' : ''}>Mejorar servicio · ${12 + 12 * r.level} M€</button><span class="small muted">Nivel ${r.level}/3</span></div>`;
  if (r.active) body += `<h2 class="section">Frente a la carretera</h2><div class="shares"><span style="width:${m.share * 100}%;background:var(--wine)"></span><span style="width:${m.busShare * 100}%;background:var(--gold-2)"></span><span style="width:${m.otherShare * 100}%;background:var(--paper-3)"></span></div>
  <div class="shares-legend"><span><i style="background:var(--wine)"></i>Tren ${n(m.share * 100)} %</span><span><i style="background:var(--gold-2)"></i>Autobús ${n(m.busShare * 100)} %</span><span><i style="background:var(--paper-3)"></i>Coche y otros ${n(m.otherShare * 100)} %</span></div>
  <dl class="figures"><div><dt>Viajeros / mes</dt><dd>${n(m.passengers)}</dd></div><div><dt>Ocupación</dt><dd>${n(m.occupancy * 100)} %</dd></div><div><dt>Resultado</dt><dd class="${m.net >= 0 ? 'pos' : 'neg'}">${signed(m.net)}</dd></div></dl>`;
  if (work && work.type !== 'upgrade') body += `<h2 class="section">Obra en la línea</h2><div class="bar gold"><span style="width:${O.constructionStatus(state, work).progress * 100}%"></span></div><p class="small">${esc(map.workName(work))} · fin previsto ${E.dateOf(work.due)}</p><button class="btn small" data-action="visit-work" data-id="${work.id}">Ver la obra</button>`;
  body += `<div class="toolbar">${r.real ? `<button class="btn small" data-action="route-trips" data-id="${r.id}">Ver sus trenes</button>` : ''}<button class="btn small" data-action="route-zoom" data-id="${r.id}">Encuadrar</button></div>`;
  return {kicker: r.active ? 'Relación en servicio' : r.cut ? 'Relación cortada por obras' : 'Relación por abrir', title: `${routeChip(r)} ${esc(routeName(r))}`, body};
}
function updatePreview() {
  const r = state.routes.find(r => r.id === inspect?.id), f = state.fleet.find(f => f.id === $('routeFleet')?.value), out = $('routePreview');
  if (!r || !out) return;
  const freq = +$('frequency').value;
  $('freqOut').textContent = freq;
  if (!f || !E.canRun(state, r, MODEL[f.model])) { out.textContent = 'Ningún tren tuyo puede ir por esta vía. Compra uno que sí, o arregla la vía.'; return; }
  const m = MODEL[f.model], units = E.requiredUnits(state, r, m, freq), b = E.metrics(state, r, {active: true, fleet: f.id, frequency: freq, fare: +$('fare').value, units});
  out.innerHTML = `${m.family} · ${units} tren${units === 1 ? '' : 'es'} necesario${units === 1 ? '' : 's'} · ${E.available(state, f, r.id)} libre${E.available(state, f, r.id) === 1 ? '' : 's'}<br>${n(freq * 2)} circulaciones al día · ${n(b.passengers)} viajeros/mes · <strong class="${b.net >= 0 ? 'pos' : 'neg'}">${signed(b.net)}/mes</strong>`;
}
function findTrip(id) {
  return plan().find(t => t.id === id) || realTrips(dayType()).find(t => t.id === id) || (String(id).match(/^[LSD]\d+$/) ? realTrips(id[0]).find(t => t.id === id) : null);
}
function trainInspector() {
  const t = findTrip(inspect.id);
  if (!t) return null;
  const minute = currentMinute(), r = state.routes.find(r => r.id === t.route), line = t.line !== undefined && t.line !== null ? S.LINES[t.line] : null;
  const color = FAMILY_COLOR[t.family] || line?.color || (r ? routeColor(r) : '#8a2a46');
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
  <p class="small">${esc(t.model || (S.lineCode(t.line) === 'Alvia' ? 'Alvia' : 'AVE'))}${r ? ' · ' + esc(routeName(r)) : ''}${t.changes?.length ? ' · cambia de ancho en ' + esc(t.changes.map(x => I.NODES[x]?.name || x).join(', ')) : ''}</p>
  <div class="toolbar"><button class="btn small ${map.follow ? 'primary' : ''}" data-action="follow">${map.follow ? 'Siguiendo al tren' : 'Seguir en el mapa'}</button>${r ? `<button class="btn small" data-action="route" data-id="${r.id}">Gestionar la línea</button>` : ''}</div>
  ${stops}`;
  const code = t.family || (t.line !== undefined && t.line !== null ? S.lineCode(t.line) : 'AVE');
  return {kicker: 'Tren ' + esc(t.number || t.label?.split(' ').at(-1) || ''), title: `${chip(code, FAMILY_COLOR[code] || color)} ${esc(t.name)}`, body};
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
  const st = job ? O.constructionStatus(state, job) : null, name = def?.name || map.workName(job);
  const km = def ? I.TRAMOS.filter(t => t.plan === def.id).reduce((v, t) => v + t.km, 0) : job.type === 'tramo' || job.type === 'custom' ? I.tramoDef(state, job.target)?.km || 0 : 0;
  const body = `<p>${esc(def?.desc || (job.type === 'tramo' ? I.WORKS[job.work].label : job.type === 'changer' ? 'Cambiador de ancho para los Alvia.' : job.type === 'custom' ? 'Línea nueva de alta velocidad: ancho estándar y 25 kV.' : ''))}</p>
  ${job ? `<dl class="figures"><div><dt>Avance</dt><dd>${n(st.progress * 100)} %</dd></div><div><dt>Fin previsto</dt><dd style="font-size:17px">${E.dateOf(job.due)}</dd></div>${km ? `<div><dt>Longitud</dt><dd>${n(km)} km</dd></div>` : ''}</dl><div class="bar gold"><span style="width:${st.progress * 100}%"></span></div>
  <ul class="objectives">${O.STAGES.map((nm, i) => `<li class="${i < st.stageIndex ? 'done' : ''}"><i style="${i === st.stageIndex ? 'box-shadow:inset 0 0 0 2px var(--gold);background:rgba(240,181,68,.35)' : ''}"></i><span>${nm}</span><span class="small muted">${i < st.stageIndex ? 'Hecho' : i === st.stageIndex ? 'Ahora' : ''}</span></li>`).join('')}</ul>${job.delay ? `<p class="callout red">Va ${job.delay} meses tarde. Lo normal.</p>` : ''}`
    : `<dl class="figures"><div><dt>Coste</dt><dd>${money(def.cost)}</dd></div><div><dt>Obra</dt><dd>${def.duration} meses</dd></div><div><dt>Longitud</dt><dd>${n(km)} km</dd></div></dl><button class="btn primary" data-action="project" data-id="${def.id}" ${state.ended ? 'disabled' : ''}>Financiar</button>`}
  <div class="toolbar"><button class="btn small" data-action="visit-work" data-id="${inspect.id}">Acercar</button></div>`;
  return {kicker: 'Obra' + (def ? ' · ' + esc(def.region) : ''), title: esc(name), body};
}
/** Relaciones que dependen de un tramo: las que lo usan y las que esperan su arreglo. */
function routesOnTramo(id) {
  const using = [], waiting = [];
  for (const r of state.routes) {
    if (r.active && E.routeUses(state, r, id)) { using.push(r); continue; }
    const o = E.routeOptions(state, r);
    if (!o.ave.ok && o.ave.faults.some(f => f.tramo === id) || (!o.alvia.ok && !o.hybrid.ok && o.hybrid.faults.some(f => f.tramo === id))) waiting.push(r);
  }
  return {using, waiting};
}
function tramoInspector() {
  const d = I.tramoDef(state, inspect.id), st = state.infra.t[inspect.id];
  if (!d || !st) return null;
  map.selectedTramo = d.id;
  const job = state.projects.find(p => !p.done && (p.target === d.id || (p.type === 'infrastructure' && d.plan === p.id)));
  const plan = d.plan && PROJECTS.find(p => p.id === d.plan), {using, waiting} = routesOnTramo(d.id), works = I.tramoWorks(state, d.id);
  let body = `<dl class="figures"><div><dt>Longitud</dt><dd>${n(d.km)} km</dd></div><div><dt>Velocidad</dt><dd>${st.v}</dd><em>km/h</em></div></dl>
  <div class="infra-tags">${st.b ? `${chip(I.GAUGE_LONG[st.g], GAUGE_COLOR[st.g])} ${chip(I.ELEC_LONG[st.e], ELEC_COLOR[st.e])}` : chip('Proyectada', '#8a7c69')} ${chip(d.kind === 'lav' ? 'Alta velocidad' : 'Convencional', '#4a3e30')}</div>
  <p class="small">${!st.b ? 'Todavía no existe.' : st.g === 'std' ? 'Ancho estándar: AVE sí; los Alvia, también.' : st.g === 'mixto' ? 'Tercer carril: pasan los dos anchos sin cambiar.' : 'Ancho ibérico: solo Alvia. Los AVE, que den la vuelta.'} ${st.b && st.e === 'no' ? 'Sin catenaria: solo el Alvia híbrido.' : ''}</p>`;
  if (job) { const s2 = O.constructionStatus(state, job); body += `<h2 class="section">Obra en marcha</h2><p>${esc(map.workName(job))}${job.type === 'tramo' ? ' · ' + esc(I.WORKS[job.work].label) : ''}</p><div class="bar gold"><span style="width:${s2.progress * 100}%"></span></div><p class="small">${s2.stage} · fin previsto ${E.dateOf(job.due)}</p>`; }
  else if (plan) body += `<h2 class="section">Se construye con</h2><p>${esc(plan.name)} · ${money(plan.cost)}</p><button class="btn primary" data-action="project" data-id="${plan.id}" ${state.ended ? 'disabled' : ''}>Ver el proyecto</button>`;
  else if (works.length) body += `<h2 class="section">Obras posibles</h2><div class="works-list">${works.map(w => `<button class="choice" data-action="work" data-work="${w.work}" data-id="${d.id}" ${state.ended || w.busy ? 'disabled' : ''}><strong>${esc(w.label)} · ${money(w.cost)}</strong><span>${w.duration} meses${w.closes ? ' · corta la línea mientras dura' : ''}${w.work === 'mixed' ? ' · pasan AVE y Alvia sin cambiar' : w.work === 'standard' ? ' · solo ancho estándar para siempre' : ' · ya pueden pasar los Alvia eléctricos'}</span></button>`).join('')}</div>`;
  else if (st.b) body += '<p class="small muted">Este tramo ya está como debe. Que no es poco.</p>';
  if (using.length) body += `<h2 class="section">La usan</h2><p>${using.map(r => `<button class="linkish" data-action="route" data-id="${r.id}">${esc(routeName(r))}</button>`).join(' · ')}</p>`;
  if (waiting.length) body += `<h2 class="section">La están esperando</h2><p>${waiting.slice(0, 12).map(r => `<button class="linkish" data-action="route" data-id="${r.id}">${esc(routeName(r))}</button>`).join(' · ')}</p>`;
  body += `<div class="toolbar"><button class="btn small" data-action="tramo-zoom" data-id="${d.id}">Acercar</button>${d.a && I.NODES[d.a] ? `<button class="btn small" data-action="node" data-id="${d.a}">${esc(I.NODES[d.a].name)}</button>` : ''}${d.b && I.NODES[d.b] ? `<button class="btn small" data-action="node" data-id="${d.b}">${esc(I.NODES[d.b].name)}</button>` : ''}</div>`;
  return {kicker: d.kind === 'lav' ? 'Línea de alta velocidad' : 'Línea convencional', title: esc(d.name), body};
}
function nodeInspector() {
  const nd = I.NODES[inspect.id];
  if (!nd) return null;
  const has = state.infra.c.includes(nd.id), job = state.projects.find(p => !p.done && p.type === 'changer' && p.target === nd.id), possible = I.changerPossible(state, nd.id);
  const lines = I.allTramos(state).filter(d => d.a === nd.id || d.b === nd.id);
  let body = `<p>${has ? `Tiene cambiador de ancho${nd.changer && nd.changer !== nd.name ? ' en ' + esc(nd.changer) : ''}: los Alvia cambian de ancho aquí en un par de minutos, sin que nadie se baje.` : job ? 'Cambiador en obras. Las máquinas, a su ritmo; los Alvia, esperando.' : possible ? 'Aquí se juntan los dos anchos y no se dirigen la palabra. Sin cambiador, el Alvia llega, mira y se vuelve.' : 'Sin cambiador ni falta que hace: aquí todo es del mismo ancho.'}</p>`;
  if (job) { const s2 = O.constructionStatus(state, job); body += `<div class="bar gold"><span style="width:${s2.progress * 100}%"></span></div><p class="small">${s2.stage} · fin previsto ${E.dateOf(job.due)}</p>`; }
  else if (!has && possible) body += `<button class="choice" data-action="work" data-work="changer" data-id="${nd.id}" ${state.ended ? 'disabled' : ''}><strong>Construir un cambiador · ${money(I.CHANGER_WORK.cost)}</strong><span>${I.CHANGER_WORK.months} meses</span></button>`;
  body += `<h2 class="section">Líneas</h2><div class="rows">${lines.map(d => { const st = state.infra.t[d.id]; return `<div><span class="status ${st.b ? 'on' : 'off'}"></span><div><h3><button class="linkish" data-action="tramo" data-id="${d.id}">${esc(d.name)}</button></h3><p>${st.b ? I.GAUGE_LABEL[st.g] + ' · ' + I.ELEC_LABEL[st.e] : 'Proyectada'}</p></div><span></span></div>`; }).join('')}</div>`;
  return {kicker: has ? 'Cambiador de ancho' : nd.kind === 'junction' ? 'Bifurcación' : 'Estación', title: esc(nd.name), body};
}

// ------------------------------------------------------------ ventanas modales
function showModal(html, cls = '') { pause(); const was = $('modal').open; $('modal').innerHTML = `<div class="modal ${cls}">${html}</div>`; if (!was) $('modal').showModal(); mountViewers($('modal')); sfx.play(was ? 'page' : 'open'); }
function closeModal() { if ($('modal').open) $('modal').close(); }
$('modal').addEventListener('close', () => { if (!$('modal').open && voices.speaking?.where === 'modal') voices.stop(); sfx.play('close'); });
function intro() {
  showModal(`<div class="art hero-art"></div><div class="content"><div class="kicker">Renfe · 2022–2050</div><h1>El próximo tren lo decides tú.</h1><p>Enero de 2022. Te sientas en el despacho de la alta velocidad española con media flota parada, un ministerio impaciente y una red con dos anchos de vía que no se hablan.</p><p>Pon AVE donde la vía lo permita y Alvia donde no. Electrifica, pon tercer carril o pasa líneas enteras a ancho estándar. Por el mapa circulan los ${n(S.META.counts.L)} AVE y Alvia reales de un día laborable.</p><div class="actions">${saved ? '<button class="btn primary" data-action="continue">Continuar partida</button>' : ''}<button class="btn ${saved ? '' : 'primary'}" data-action="begin">Asumir la dirección</button><button class="btn ghost" data-action="observe">Solo mirar los trenes</button></div></div>`);
}
function showDecision() {
  const d = E.pendingDecision(state); if (!d) return;
  const person = CHARACTERS[d.person];
  showModal(`<div class="art portrait" style="${faceStyle(d.person, d.mood)}" role="img" aria-label="${esc(person.name)}"><span class="plate"><b>${esc(person.name)}</b>${esc(person.role)}</span></div><div class="content"><div class="kicker">${esc(E.dateOf(state.month))} · ${d.event ? 'Imprevisto' : 'Consejo de dirección'}</div><h1>${esc(d.title)}</h1><p data-say="${esc(d.body)}">${sayHtml(d.body)}</p><p class="small speaker">${sayButton(d.person, 'modal')} Escuchar a ${esc(person.name.split(' ')[0])}</p>${d.choices.map((c, i) => `<button class="choice" data-action="decision" data-id="${d.id}" data-choice="${i}" ${state.cash < -(c.effects.cash || 0) ? 'disabled' : ''}><strong>${esc(c.label)}</strong><span>${esc(c.detail)}</span></button>`).join('')}</div>`);
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
function placeOptions(id, selected, withJunctions = true) {
  const list = [...CITIES.map(c => ({id: c.id, name: c.name})), ...(withJunctions ? Object.values(I.NODES).filter(nd => nd.kind === 'junction').map(nd => ({id: nd.id, name: nd.name + ' (bifurcación)'})) : [])].filter(x => I.NODES[x.id] || !withJunctions).sort((a, b) => a.name.localeCompare(b.name));
  return `<select id="${id}">${list.map(c => `<option value="${c.id}" ${c.id === selected ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}</select>`;
}
function newLineDialog() {
  showModal(`<div class="content"><div class="kicker">Alta velocidad nueva</div><h1>Traza tu propia línea.</h1><p>Vía nueva de ancho estándar con catenaria de 25 kV entre dos puntos de la red. Cara, lenta y gloriosa.</p><div class="toolbar">${placeOptions('lineA', 'mur')}<span>→</span>${placeOptions('lineB', 'alm')}</div><p id="lineQuote" class="callout"></p><div class="actions"><button class="btn primary" data-action="confirm-line">Adjudicar la obra</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single');
  updateLineQuote();
}
function updateLineQuote() { try { const q = E.newLineQuote($('lineA').value, $('lineB').value); $('lineQuote').textContent = `${q.km} km · ${money(q.cost)} · ${q.duration} meses de obra, si no se tuerce nada.`; } catch (e) { $('lineQuote').textContent = e.message; } }
function serviceDialog() {
  showModal(`<div class="content"><div class="kicker">Relación nueva</div><h1>Une dos ciudades.</h1><p>Elige origen y destino: la red decide por dónde puede ir cada tren.</p><div class="toolbar">${placeOptions('svcA', 'vlc', false)}<span>→</span>${placeOptions('svcB', 'sev', false)}</div><div id="svcPreview" class="options"></div><div class="actions"><button class="btn primary" data-action="confirm-service">Crear la relación</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single');
  updateServicePreview();
}
function updateServicePreview() {
  const a = $('svcA')?.value, b = $('svcB')?.value, el = $('svcPreview');
  if (!el) return;
  if (!a || !b || a === b) { el.innerHTML = '<p class="small muted">Elige dos ciudades distintas.</p>'; return; }
  const way = [a, b], P = I.PROFILES;
  el.innerHTML = optionRow('AVE', I.plan(state, way, P.ave)) + optionRow('Alvia', I.plan(state, way, P.alvia)) + optionRow('Alvia híbrido', I.plan(state, way, P.hybrid));
}
function saveDialog() {
  showModal(`<div class="content"><div class="kicker">Guardar</div><h1>Tu partida, a salvo.</h1><p>Se guarda sola en este navegador. Exporta una copia para llevártela a otro equipo.</p><div class="actions"><button class="btn primary" data-action="save-now">Guardar ahora</button><button class="btn" data-action="export">Exportar (.json)</button></div><label for="importSave">Importar una partida</label><input id="importSave" type="file" accept="application/json,.json"></div>`, 'single');
}
function help() {
  showModal(`<div class="content"><div class="kicker">Cómo jugar</div><h1>Un día, un turno.</h1><ol class="method">
  <li><b>Pulsa una ciudad.</b> Abre sus conexiones, pon más o menos trenes con + y −, mejora su estación y atiende sus peticiones.</li>
  <li><b>AVE o Alvia.</b> El AVE solo circula por ancho estándar o mixto y con catenaria. El Alvia cambia de ancho en los cambiadores; el Alvia híbrido, además, va sin catenaria.</li>
  <li><b>Arregla la vía.</b> En los mapas de <b>Anchos</b> y <b>Electrificación</b>, pulsa un tramo: electrifica, pon tercer carril o pásalo a ancho estándar. Pulsa un rombo o una bifurcación para construir cambiadores.</li>
  <li><b>Juega la jornada.</b> El reloj va del primer tren al último. Atiende las incidencias y los momentos de mucha demanda.</li>
  <li><b>Crece.</b> Compra trenes, financia líneas nuevas y cumple los capítulos para recibir dinero.</li></ol>
  <p class="small">Atajos: <kbd>Espacio</kbd> pausa · <kbd>1</kbd>–<kbd>4</kbd> velocidad · <kbd>+</kbd>/<kbd>−</kbd> zoom · <kbd>Esc</kbd> cerrar.</p><div class="actions"><button class="btn primary" data-action="close-modal">Entendido</button><button class="btn" data-action="tutorial-start">Repetir el tutorial</button></div>
  <p class="credits">Horarios de Renfe Data (CC BY 4.0). Vías © colaboradores de OpenStreetMap (ODbL). Contornos de Natural Earth.</p></div>`, 'single');
}
function realTripModal(id) { inspect = {type: 'train', id}; map.selectedTrain = id; screen = null; if (layer !== 'real' && !plan().some(t => t.id === id)) setLayer('real'); render(); }

// ------------------------------------------------------------ capas y acciones
function setLayer(l) {
  layer = LAYERS.includes(l) ? l : 'network'; map.layer = ['works', 'gauge', 'power'].includes(layer) ? layer : 'network';
  document.querySelectorAll('[data-layer]').forEach(b => b.classList.toggle('active', b.dataset.layer === layer));
  netKey = networkKey(); map.dirty = true; renderLegend(); renderDaybar();
  if (layer === 'real') toast('Horario real: todos los AVE y Alvia publicados para un día ' + S.DAY_TYPES[dayType()].toLowerCase() + '. Mirar no cuesta dinero.');
}
/** Confirma una obra de vía o un cambiador con su presupuesto y lo que corta. */
function workDialog(kind, target) {
  let q;
  try { q = E.workQuote(state, kind, target); } catch (e) { sfx.play('error'); return toast(e.message); }
  const place = kind === 'changer' ? I.NODES[target].name : I.tramoDef(state, target).name;
  showModal(`<div class="content"><div class="kicker">${esc(q.label)}</div><h1>${esc(place)}</h1>
  <dl class="figures"><div><dt>Coste</dt><dd>${money(q.cost)}</dd></div><div><dt>Obra</dt><dd>${q.months} meses</dd></div><div><dt>Termina</dt><dd style="font-size:18px">${E.dateOf(state.month + q.months)}</dd></div></dl>
  ${q.closes ? `<p class="callout red">La línea se corta mientras dure la obra.${q.affected.length ? ' Se suspenden: ' + q.affected.map(r => esc(routeName(r))).join(', ') + '.' : ''}</p>` : ''}
  <p class="small">${kind === 'electrify' ? 'Catenaria de 25 kV: ya pueden pasar los AVE y los Alvia eléctricos.' : kind === 'mixed' ? 'Un tercer carril: pasan los dos anchos y no se corta el tráfico.' : kind === 'standard' ? 'Fuera el ancho ibérico: el AVE entra hasta la cocina, pero solo por ancho estándar.' : 'Los Alvia podrán cambiar de ancho aquí.'}</p>
  <div class="actions"><button class="btn primary" data-action="confirm-work" data-work="${kind}" data-id="${esc(target)}">Adjudicar · ${money(q.cost)}</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single');
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
    case 'route-trips': { const r = state.routes.find(r => r.id === id); ui.ttStation = ''; ui.ttStationId = undefined; screen = 'network'; ui.netView = 'timetables'; inspect = null; const first = S.routeTrips(dayType(), id)[0]; if (first) { ui.ttStationId = first.stations[0]; ui.ttStation = S.STATIONS[first.stations[0]].name.toLowerCase(); } render(); if (r) toast('Salidas desde ' + S.STATIONS[first?.stations[0]]?.name); break; }
    case 'route-tab': ui.routeTab = id; renderDrawer(); break;
    case 'net-view': ui.netView = id; renderDrawer(); break;
    case 'office-tab': ui.officeTab = id; renderDrawer(); break;
    case 'train': inspect = {type: 'train', id}; map.selectedTrain = id; screen = null; render(); break;
    case 'station': inspect = {type: 'station', id: +id}; render(); break;
    case 'station-map': { const st = S.STATIONS[+id]; screen = null; inspect = {type: 'station', id: +id}; map.focusAt(st.lon, st.lat, 60); render(); break; }
    case 'station-timetable': { const st = S.STATIONS[+id]; ui.ttStationId = +id; ui.ttStation = st.name.toLowerCase(); ui.ttHour = Math.max(4, Math.min(25, Math.floor(currentMinute() / 60))); inspect = null; screen = 'network'; ui.netView = 'timetables'; render(); break; }
    case 'tt-type': ui.ttType = id; renderDrawer(); break;
    case 'tt-station': ui.ttStationId = +id; ui.ttStation = S.STATIONS[+id].name.toLowerCase(); renderDrawer(); break;
    case 'real-trip': realTripModal(id); break;
    case 'follow': map.follow = !map.follow; renderInspector(); break;
    case 'layer': setLayer(id); screen = null; render(); break;
    case 'visit-work': { const job = state.projects.find(p => p.id === id) || {id}; const pts = map.workGeometry(job).flatMap(g => g.pts); setLayer('works'); if (pts.length) map.fit(pts, 45); inspect = {type: 'work', id}; screen = null; render(); break; }
    case 'tramo': { const d = I.tramoDef(state, id); if (!d) break; if (!['gauge', 'power'].includes(layer)) setLayer('gauge'); inspect = {type: 'tramo', id}; map.selectedTramo = id; screen = null; closeModal(); render(); break; }
    case 'tramo-zoom': { const d = I.tramoDef(state, id); if (d) map.fit(I.tramoGeom(d).pts, 40); break; }
    case 'node': { const nd = I.NODES[id]; if (!nd) break; if (!['gauge', 'power'].includes(layer)) setLayer('gauge'); inspect = {type: 'node', id}; screen = null; closeModal(); if (map.zoom < 2) map.focusAt(nd.lon, nd.lat, 3); render(); break; }
    case 'work': workDialog(b.dataset.work, id); break;
    case 'confirm-work': if (act(() => E.startWork(state, b.dataset.work, id), 'Obra adjudicada. Ya hay máquinas en la vía.')) closeModal(); break;
    case 'works-tab': ui.worksTab = id; renderDrawer(); break;
    case 'new-service': serviceDialog(); break;
    case 'confirm-service': { let rid = null; if (act(() => { rid = E.createService(state, $('svcA').value, $('svcB').value); }, 'Relación creada. Ahora ponle trenes.')) { closeModal(); selectRoute(rid); } break; }
    case 'close-service': act(() => E.closeRoute(state, id), 'Servicio suspendido. El material queda libre.'); break;
    case 'upgrade': act(() => E.upgradeRoute(state, id), 'Mejora contratada. Termina en cuatro meses.'); break;
    case 'fleet-tab': ui.fleetTab = id; renderDrawer(); break;
    case 'fleet-detail': fleetDetail(id); break;
    case 'refurbish': if (act(() => E.refurbish(state, id, +$('fleetQty').value), 'Material enviado a reforma.')) closeModal(); break;
    case 'sell': if (act(() => E.sell(state, id, +$('fleetQty').value), 'Venta completada.')) closeModal(); break;
    case 'purchase': purchaseDialog(id); break;
    case 'confirm-buy': if (act(() => E.buy(state, id, +$('buyQty').value), 'Pedido firmado.')) closeModal(); break;
    case 'project': { const p = PROJECTS.find(p => p.id === id); const km = I.TRAMOS.filter(t => t.plan === id).reduce((v, t) => v + t.km, 0); showModal(`<div class="content"><div class="kicker">Alta velocidad nueva · ${esc(p.region)}</div><h1>${esc(p.name)}</h1><p>${esc(p.desc)}</p><dl class="figures"><div><dt>Coste</dt><dd>${money(p.cost)}</dd></div><div><dt>Longitud</dt><dd>${n(km)} km</dd></div><div><dt>Obra</dt><dd>${p.duration} meses</dd></div></dl><p class="small">No estará lista antes de ${p.earliest}. Ancho estándar y 25 kV.</p><div class="actions"><button class="btn primary" data-action="confirm-project" data-id="${id}">Financiar · ${money(p.cost)}</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single'); break; }
    case 'confirm-project': if (act(() => E.startProject(state, id), 'Obra adjudicada. Ahora a esperar.')) closeModal(); break;
    case 'new-line': newLineDialog(); break;
    case 'confirm-line': if (act(() => E.buildLine(state, $('lineA').value, $('lineB').value), 'Línea adjudicada. Nos vemos en la inauguración.')) closeModal(); break;
    case 'borrow': act(() => E.loan(state, 100), 'Financiación de 100 M€ recibida.'); break;
    case 'repay': act(() => E.loan(state, -100), '100 M€ amortizados.'); break;
    case 'save-dialog': saveDialog(); break;
    case 'help': help(); break;
    case 'save-now': autosave(true); break;
    case 'export': { const blob = new Blob([JSON.stringify(state, null, 2)], {type: 'application/json'}), url = URL.createObjectURL(blob), link = document.createElement('a'); link.href = url; link.download = 'Iberia-Ferroviaria-' + E.yearOf(state) + '.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); toast('Partida exportada.'); break; }
    case 'new-game': showModal(`<div class="content"><div class="kicker">Nueva campaña</div><h1>¿Un nuevo mandato?</h1><p>La nueva campaña sustituirá el guardado automático.</p><div class="actions"><button class="btn" data-action="export">Exportar la actual</button><button class="btn primary" data-action="begin">Empezar en 2022</button><button class="btn" data-action="close-modal">Cancelar</button></div></div>`, 'single'); break;
  }
  if (tut && a !== 'tutorial-next') renderCoach(); // el tutorial avanza en cuanto se cumple el paso, sin esperar al siguiente fotograma
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
  if (t.id === 'buyQty') updateQuote();
  if (['lineA', 'lineB'].includes(t.id)) updateLineQuote();
  if (['svcA', 'svcB'].includes(t.id)) updateServicePreview();
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
  if (t.id === 'importSave' && t.files[0]) {
    try { if (t.files[0].size > 6e6) throw Error('El archivo es demasiado grande.'); state = E.validateSave(JSON.parse(await t.files[0].text())); O.ensureOps(state); state.started = true; autosave(); sfx.play('confirm'); closeModal(); inspect = null; screen = null; netKey = networkKey(); map.dirty = true; render(); toast('Partida importada.'); if (E.pendingDecision(state)) showDecision(); }
    catch (e) { sfx.play('error'); toast('No se pudo importar: ' + e.message); }
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
document.querySelectorAll('[data-layer]').forEach(b => b.onclick = () => { sfx.play('lever', {i: LAYERS.indexOf(b.dataset.layer)}); setLayer(b.dataset.layer); renderCoach(); });
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
