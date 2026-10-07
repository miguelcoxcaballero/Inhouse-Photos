// Banda sonora original de Iberia Ferroviaria, tocada en tiempo real con Web Audio: instrumentos muestreados reales
// (assets/samples.js) y sintetizadores para pads, bajos electrónicos y efectos.
// Doce piezas en dos familias de estilo:
//  · «Estación» (preparación y menús): bossa nova, jazz ligero, vals, pop y lounge.
//  · «Red» (jornadas): ambiental orquestal-electrónica de día y piezas nocturnas.
// Melodías, armonías y arreglos son composiciones originales de este proyecto.
import {SAMPLE_BANK} from './assets/samples.js';

// ------------------------------------------------------------ teoría
const PC = {C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11};
export function midi(name) {
  const m = /^([A-G])([#b]?)(-?\d)$/.exec(name);
  if (!m) throw Error('Nota no válida: ' + name);
  return 12 * (+m[3] + 1) + PC[m[1]] + (m[2] === '#' ? 1 : m[2] === 'b' ? -1 : 0);
}
const hz = m => 440 * 2 ** ((m - 69) / 12);
const QUAL = {
  '': [0, 4, 7], m: [0, 3, 7], maj7: [0, 4, 7, 11], maj9: [0, 4, 7, 11, 14], 'maj7#11': [0, 4, 7, 11, 18], 'maj9#11': [0, 4, 11, 14, 18], 6: [0, 4, 7, 9], 69: [0, 4, 9, 14],
  m6: [0, 3, 7, 9], m7: [0, 3, 7, 10], m9: [0, 3, 10, 14], m11: [0, 3, 10, 14, 17], 7: [0, 4, 7, 10], 9: [0, 4, 10, 14], 13: [0, 4, 10, 14, 21], '7b9': [0, 4, 10, 13],
  m7b5: [0, 3, 6, 10], dim7: [0, 3, 6, 9], sus4: [0, 5, 7], '7sus4': [0, 5, 7, 10], add9: [0, 4, 7, 14], 'Bsus': [0, 5, 7, 14],
};
export function chord(sym) {
  const [main, slash] = sym.split('/');
  const m = /^([A-G][#b]?)(.*)$/.exec(main);
  const root = midi(m[1] + '0') - 12;
  const q = QUAL[m[2]];
  if (!q) throw Error('Acorde no válido: ' + sym);
  const bass = slash ? (midi(slash + '0') - 12) % 12 : ((root % 12) + 12) % 12;
  return {root: ((root % 12) + 12) % 12, bass, iv: q};
}
/** Voz cerrada del acorde dentro de [low, high). */
function voicing(c, low = 52, rootless = true) {
  const ivs = rootless && c.iv.length >= 4 ? c.iv.slice(1) : c.iv;
  return ivs.map(i => { let n = c.root + i; while (n < low) n += 12; while (n >= low + 12) n -= 12; return n; }).sort((a, b) => a - b)
    .map((n, k, arr) => (k > 0 && n - arr[k - 1] < 2 ? n + 12 : n)).sort((a, b) => a - b);
}
const bassNote = (c, low = 36) => { let n = c.bass; while (n < low) n += 12; return n; };
const fifth = (c, low = 36) => bassNote({...c, bass: (c.root + 7) % 12}, low);
const third = (c, low = 36) => bassNote({...c, bass: (c.root + c.iv[1]) % 12}, low);

const pcOf = n => ((n % 12) + 12) % 12;
const avg = a => a.reduce((s, x) => s + x, 0) / a.length;
function tones(c, rootless) { const ivs = rootless && c.iv.length >= 4 ? c.iv.slice(1) : c.iv; return [...new Set(ivs.map(i => pcOf(c.root + i)))]; }
/** Voz con conducción de voces: la inversión (o «drop 2») más cercana a la anterior dentro de [low, high]. */
function led(c, low, high, prev, rootless = true) {
  const pcs = tones(c, rootless), cands = [];
  for (let r = 0; r < pcs.length; r++) {
    const rot = pcs.slice(r).concat(pcs.slice(0, r));
    let n = rot[0]; while (n < low) n += 12;
    const v = [n]; for (let k = 1; k < rot.length; k++) { let x = rot[k]; while (x <= v[k - 1]) x += 12; v.push(x); }
    if (v.at(-1) <= high) cands.push(v);
    if (v.length >= 4) { const d = v.slice(); d[d.length - 2] -= 12; d.sort((a, b) => a - b); if (d[0] >= low - 7 && d.at(-1) <= high) cands.push(d); }
  }
  if (!cands.length) return voicing(c, low, rootless);
  const mid = (low + high) / 2;
  const cost = v => (prev && prev.length ? v.reduce((s, x) => s + Math.min(...prev.map(p => Math.abs(p - x))), 0) + Math.abs(avg(v) - avg(prev)) * .5 : 0) + Math.abs(avg(v) - mid) * .2;
  return cands.reduce((b, v) => (cost(v) < cost(b) ? v : b));
}
/** Segunda voz para la melodía: el tono del acorde más agudo entre 3 y 9 semitonos por debajo (terceras y sextas). */
function under(m, c) { const pcs = c.iv.map(i => pcOf(c.root + i)); for (let n = m - 3; n >= m - 9; n--) if (pcs.includes(pcOf(n))) return n; return null; }
/** Nota de aproximación cromática hacia `target`, desde arriba o desde abajo según venga la línea. */
const approach = (target, from) => target + (from > target ? 1 : -1);

// ------------------------------------------------------------ instrumentos sintetizados
let noiseBuf = null;
function noise(ctx) {
  if (noiseBuf && noiseBuf.sampleRate === ctx.sampleRate) return noiseBuf;
  noiseBuf = ctx.createBuffer(1, ctx.sampleRate * 1.5, ctx.sampleRate);
  const d = noiseBuf.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  return noiseBuf;
}
function out(ctx, bus, t, end, gain, rev = .25, del = 0, pan = 0) {
  const g = ctx.createGain();
  let node = g;
  if (pan && ctx.createStereoPanner) { const p = ctx.createStereoPanner(); p.pan.value = pan; g.connect(p); node = p; }
  node.connect(bus.dry);
  if (rev) { const s = ctx.createGain(); s.gain.value = rev; node.connect(s); s.connect(bus.rev); }
  if (del) { const s = ctx.createGain(); s.gain.value = del; node.connect(s); s.connect(bus.del); }
  g.gain.value = 0;
  return g;
}
function osc(ctx, type, f, t, end, dest, detune = 0) {
  const o = ctx.createOscillator(); o.type = type; o.frequency.value = f; o.detune.value = detune;
  o.connect(dest); o.start(t); o.stop(end + .05); return o;
}
function adsr(p, t, peak, a, d, s, dur, r) {
  p.setValueAtTime(0, t); p.linearRampToValueAtTime(peak, t + a);
  p.setTargetAtTime(peak * s, t + a, d / 3);
  p.setTargetAtTime(0, t + Math.max(a, dur), r / 4);
}

const SYNTH = {
  piano(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), decay = Math.max(.6, 3.2 - (m - 48) * .045), end = t + Math.min(dur + .4, decay + .3);
    const g = out(ctx, bus, t, end, v, o.rev ?? .28, o.del ?? 0, (m - 64) / 60);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1800 + v * 4500; lp.connect(g);
    [[1, 1], [2, .42], [3, .2], [4, .11], [5, .05]].forEach(([k, a]) => { const pg = ctx.createGain(); pg.gain.value = a; pg.connect(lp); osc(ctx, 'sine', f * k * (1 + k * .0004), t, end, pg); });
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .32, t + .006);
    g.gain.setTargetAtTime(v * .1, t + .006, decay / 5); g.gain.setTargetAtTime(0, t + dur, .12);
  },
  epiano(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + .9, g = out(ctx, bus, t, end, v, o.rev ?? .3, o.del ?? .08, (m - 62) / 50);
    const car = ctx.createOscillator(), mod = ctx.createOscillator(), mg = ctx.createGain();
    car.frequency.value = f; mod.frequency.value = f; mg.gain.setValueAtTime(f * (1.4 + v * 2), t); mg.gain.setTargetAtTime(f * .25, t, .25);
    mod.connect(mg); mg.connect(car.frequency); car.connect(g);
    if (o.trem) { const l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = 4.6; lg.gain.value = v * .07; l.connect(lg); lg.connect(g.gain); l.start(t); l.stop(end); }
    [car, mod].forEach(x => { x.start(t); x.stop(end); });
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .3, t + .004); g.gain.setTargetAtTime(v * .12, t + .01, .5); g.gain.setTargetAtTime(0, t + dur, .25);
  },
  pad(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + 2.2, g = out(ctx, bus, t, end, v, o.rev ?? .5, o.del ?? 0, ((m * 7) % 11 - 5) / 12);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = o.bright ? 2400 : 1200; lp.Q.value = .5; lp.connect(g);
    const l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = .15; lg.gain.value = 350; l.connect(lg); lg.connect(lp.frequency); l.start(t); l.stop(end);
    [-9, 0, 8].forEach(dt => osc(ctx, 'sawtooth', f, t, end, lp, dt));
    adsr(g.gain, t, v * .07, o.attack ?? 1.2, 1.5, .85, dur, 2);
  },
  strings(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + 1.5, g = out(ctx, bus, t, end, v, o.rev ?? .45, 0, ((m * 5) % 9 - 4) / 10);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 2600; lp.connect(g);
    const vib = ctx.createOscillator(), vg = ctx.createGain(); vib.frequency.value = 5.2; vg.gain.value = 6; vib.connect(vg); vib.start(t); vib.stop(end);
    [-6, 5].forEach(dt => { const x = osc(ctx, 'sawtooth', f, t, end, lp, dt); vg.connect(x.detune); });
    adsr(g.gain, t, v * .09, o.attack ?? .35, .8, .9, dur, .9);
  },
  flute(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + .5, g = out(ctx, bus, t, end, v, o.rev ?? .35, o.del ?? .1, .15);
    const vib = ctx.createOscillator(), vg = ctx.createGain(); vib.frequency.value = 5; vg.gain.setValueAtTime(0, t); vg.gain.linearRampToValueAtTime(f * .006, t + .35); vib.connect(vg); vib.start(t); vib.stop(end);
    const a = osc(ctx, 'sine', f, t, end, g), b = ctx.createGain(); b.gain.value = .18; b.connect(g); const c = osc(ctx, 'triangle', f * 2, t, end, b);
    vg.connect(a.frequency); vg.connect(c.frequency);
    const n = ctx.createBufferSource(), bp = ctx.createBiquadFilter(), ng = ctx.createGain(); n.buffer = noise(ctx); bp.type = 'bandpass'; bp.frequency.value = f * 2; bp.Q.value = 2; ng.gain.value = .05; n.connect(bp); bp.connect(ng); ng.connect(g); n.start(t); n.stop(end);
    adsr(g.gain, t, v * .2, .06, .3, .8, dur, .12);
  },
  clarinet(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + .4, g = out(ctx, bus, t, end, v, o.rev ?? .3, 0, -.1);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1700; lp.connect(g);
    const vib = ctx.createOscillator(), vg = ctx.createGain(); vib.frequency.value = 4.6; vg.gain.setValueAtTime(0, t); vg.gain.linearRampToValueAtTime(5, t + .4); vib.connect(vg); vib.start(t); vib.stop(end);
    vg.connect(osc(ctx, 'square', f, t, end, lp).detune);
    adsr(g.gain, t, v * .09, .05, .4, .85, dur, .1);
  },
  vibes(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + Math.max(dur, 1.2) + 1.6, g = out(ctx, bus, t, end, v, o.rev ?? .35, o.del ?? .12, .2);
    const tr = ctx.createGain(); tr.connect(g); const l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = 5.5; lg.gain.value = .35; l.connect(lg); lg.connect(tr.gain); l.start(t); l.stop(end);
    osc(ctx, 'sine', f, t, end, tr); const h = ctx.createGain(); h.gain.value = .25; h.connect(tr); osc(ctx, 'sine', f * 4, t, t + .3, h);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .26, t + .004); g.gain.setTargetAtTime(0, t + .01, .9);
  },
  marimba(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + .9, g = out(ctx, bus, t, end, v, o.rev ?? .25, o.del ?? .05, .1);
    osc(ctx, 'sine', f, t, end, g); const h = ctx.createGain(); h.gain.setValueAtTime(.5, t); h.gain.setTargetAtTime(0, t, .03); h.connect(g); osc(ctx, 'sine', f * 4, t, t + .2, h);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .34, t + .003); g.gain.setTargetAtTime(0, t + .005, .22);
  },
  bell(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + 3.5, g = out(ctx, bus, t, end, v, o.rev ?? .5, o.del ?? .2, -.2);
    [[1, 1], [2.76, .38], [5.4, .18], [8.93, .08]].forEach(([k, a]) => { const pg = ctx.createGain(); pg.gain.setValueAtTime(a, t); pg.gain.setTargetAtTime(0, t, 1.2 / k); pg.connect(g); osc(ctx, 'sine', f * k, t, end, pg); });
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .12, t + .003); g.gain.setTargetAtTime(0, t + .01, .9);
  },
  pluck(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + Math.min(dur, .6) + .3, g = out(ctx, bus, t, end, v, o.rev ?? .2, o.del ?? .1, (m % 7 - 3) / 8);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.setValueAtTime(4200, t); lp.frequency.setTargetAtTime(700, t, .08); lp.connect(g);
    osc(ctx, 'triangle', f, t, end, lp); osc(ctx, 'sawtooth', f * 1.002, t, end, lp);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .16, t + .003); g.gain.setTargetAtTime(0, t + .01, o.short ? .06 : .18);
  },
  bass(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + .3, g = out(ctx, bus, t, end, v, .08, 0, 0);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.setValueAtTime(900, t); lp.frequency.setTargetAtTime(300, t, .15); lp.connect(g);
    osc(ctx, 'sine', f, t, end, g); osc(ctx, 'triangle', f, t, end, lp);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .44, t + .008); g.gain.setTargetAtTime(v * .2, t + .01, .3); g.gain.setTargetAtTime(0, t + dur, .06);
  },
  sub(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + 1, g = out(ctx, bus, t, end, v, .05, 0, 0);
    osc(ctx, 'sine', f, t, end, g); const h = ctx.createGain(); h.gain.value = .15; h.connect(g); osc(ctx, 'triangle', f * 2, t, end, h);
    adsr(g.gain, t, v * .4, .08, .8, .8, dur, .5);
  },
  synthbass(ctx, bus, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + .15, g = out(ctx, bus, t, end, v, .05, 0, 0);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.setValueAtTime(1400, t); lp.frequency.setTargetAtTime(260, t, .07); lp.Q.value = 3; lp.connect(g);
    osc(ctx, 'sawtooth', f, t, end, lp); osc(ctx, 'sine', f / 2, t, end, g);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .32, t + .005); g.gain.setTargetAtTime(0, t + dur * .8, .05);
  },
  // ---- percusión
  kick(ctx, bus, t, m, dur, v) {
    const g = out(ctx, bus, t, t + .5, v, .05), o = ctx.createOscillator();
    o.frequency.setValueAtTime(130, t); o.frequency.exponentialRampToValueAtTime(42, t + .12); o.connect(g); o.start(t); o.stop(t + .5);
    g.gain.setValueAtTime(v * .7, t); g.gain.setTargetAtTime(0, t + .01, .09);
  },
  snare(ctx, bus, t, m, dur, v) { perc(ctx, bus, t, v * .45, 'bandpass', 2200, .7, .09, .25); },
  brush(ctx, bus, t, m, dur, v) { perc(ctx, bus, t, v * .35, 'bandpass', 3800, .5, .16, .3); },
  clap(ctx, bus, t, m, dur, v) { [0, .012, .024].forEach(d => perc(ctx, bus, t + d, v * .3, 'bandpass', 1500, 1, .05, .35)); },
  hat(ctx, bus, t, m, dur, v) { perc(ctx, bus, t, v * .22, 'highpass', 7500, .7, dur > .3 ? .12 : .035, .15); },
  shaker(ctx, bus, t, m, dur, v) { perc(ctx, bus, t, v * .2, 'bandpass', 6000, 1.2, .04, .1, .015); },
  rim(ctx, bus, t, m, dur, v) {
    const g = out(ctx, bus, t, t + .1, v, .2); osc(ctx, 'triangle', 1700, t, t + .06, g); osc(ctx, 'sine', 820, t, t + .06, g);
    g.gain.setValueAtTime(v * .25, t); g.gain.setTargetAtTime(0, t, .012);
  },
};
function perc(ctx, bus, t, v, type, f, q, decay, rev, attack = .001) {
  const g = out(ctx, bus, t, t + decay * 6, v, rev), n = ctx.createBufferSource(), bf = ctx.createBiquadFilter();
  n.buffer = noise(ctx); n.playbackRate.value = .8 + Math.random() * .4; bf.type = type; bf.frequency.value = f; bf.Q.value = q;
  n.connect(bf); bf.connect(g); n.start(t, Math.random()); n.stop(t + decay * 6);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v, t + attack); g.gain.setTargetAtTime(0, t + attack, decay);
}

// ------------------------------------------------------------ instrumentos muestreados
// Banco de muestras reales (assets/samples.js): piano de cola, piano eléctrico, vibráfono, marimba, glockenspiel, flauta,
// clarinete, sección de cuerdas, arpa, guitarra de nailon, contrabajo, bajo eléctrico y percusión acústica.
// Si una muestra no está decodificada (o no hay Web Audio), suena el sintetizador equivalente.
const LEVEL = {piano: .5, epiano: .48, vibes: .5, marimba: .55, glock: .3, flute: .42, clarinet: .42, strings: .34, harp: .46, guitar: .46, upright: .38, ebass: .32, mtrumpet: .34,
  hat: .13, hatopen: .09, hatpedal: .1, shaker: .1, tamb: .12, cajon: .4, cajonslap: .21, snare: .24, ghost: .13, rim: .2, conga: .22, congamute: .2, quinto: .2, tumba: .24, bongo: .2, ride: .1, swell: .2, crash: .15, claps: .2};
const REV = {mtrumpet: .32, claps: .3, strings: .45, harp: .4, glock: .5, flute: .35, clarinet: .3, vibes: .35, piano: .28, epiano: .28, upright: .06, ebass: .04, cajon: .08, swell: .5, crash: .35};
const PAN = {claps: -.2, hat: .25, hatopen: .25, hatpedal: .2, shaker: -.3, tamb: .35, conga: -.25, congamute: -.25, quinto: -.35, tumba: -.15, bongo: .3, ride: .3, rim: -.1, crash: .2};
const BRIGHT = new Set(['piano', 'epiano', 'vibes', 'strings', 'guitar', 'harp', 'marimba']);
const MEL_GAIN = 2.2; // la melodía, siempre por delante del acompañamiento
const MIX_GAIN = 2; // ganancia de compensación antes del compresor
const SUSTAIN = new Set(['strings', 'flute', 'clarinet']);
const ALIAS = {bell: 'glock'};
const FALLBACK = {harp: 'pluck', guitar: 'pluck', upright: 'bass', ebass: 'bass', glock: 'bell', hatopen: 'hat', hatpedal: 'hat', ghost: 'snare', cajon: 'kick', cajonslap: 'snare',
  conga: 'rim', congamute: 'rim', quinto: 'rim', tumba: 'rim', bongo: 'rim', tamb: 'shaker', ride: 'hat', claps: 'clap', mtrumpet: 'clarinet'};
const banks = new WeakMap();
function b64buf(s) { const bin = atob(s), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u.buffer; }
function decode(ctx, ab) { return new Promise((res, rej) => { const p = ctx.decodeAudioData(ab, res, rej); if (p && p.then) p.then(res, rej); }); }
/** Inicio real del sonido (el MP3 añade un retardo de codificación que se salta al reproducir). */
function firstSound(buf) {
  const d = buf.getChannelData(0), n = Math.min(d.length, Math.floor(buf.sampleRate * .5));
  let peak = 0; for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(d[i]));
  for (let i = 0; i < n; i++) if (Math.abs(d[i]) > peak * .02) return Math.max(0, i - 24) / buf.sampleRate;
  return 0;
}
/** Decodifica, una sola vez por contexto de audio, los instrumentos que aparecen en `names`. */
export function loadInstruments(ctx, names) {
  if (!ctx?.decodeAudioData || typeof atob !== 'function') return Promise.resolve([]);
  if (!banks.has(ctx)) banks.set(ctx, new Map());
  const bank = banks.get(ctx);
  const wanted = [...new Set(names.map(n => ALIAS[n] || n))].filter(n => SAMPLE_BANK[n]);
  return Promise.all(wanted.map(n => {
    if (!bank.has(n)) {
      const entry = {value: null};
      entry.promise = Promise.all(SAMPLE_BANK[n].data.map(s => decode(ctx, b64buf(s))))
        .then(bufs => (entry.value = {spec: SAMPLE_BANK[n], bufs: bufs.map(b => ({b, off: firstSound(b)})), rr: 0}))
        .catch(() => null);
      bank.set(n, entry);
    }
    return bank.get(n).promise;
  }));
}
function sampled(ctx, bus, t, name, m, dur, v, o) {
  const key = ALIAS[name] || name, inst = banks.get(ctx)?.get(key)?.value;
  if (!inst) return false;
  const {spec} = inst, tonal = spec.kind === 'tonal';
  let k = 0, rate = 1;
  if (tonal) { const ns = spec.notes; k = ns.reduce((b, n, i) => (Math.abs(n - m) < Math.abs(ns[b] - m) ? i : b), 0); rate = 2 ** ((m - ns[k]) / 12); }
  else k = inst.rr = (inst.rr + 1) % inst.bufs.length;
  const {b, off} = inst.bufs[k], avail = (b.duration - off) / rate;
  const rel = o.rel ?? (SUSTAIN.has(key) ? .35 : .45);
  const end = tonal ? Math.min(t + avail, t + dur + rel * 3) : t + avail;
  const pan = o.pan ?? (tonal ? Math.max(-.55, Math.min(.55, (m - 64) / 48)) : PAN[key] || 0);
  const g = out(ctx, bus, t, end, v, o.rev ?? REV[key] ?? .22, o.del ?? 0, pan);
  let node = g;
  if (BRIGHT.has(key) || o.lp) { const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = o.lp || 1600 + v * v * 12000; lp.connect(node); node = lp; }
  if (o.trem) { const tg = ctx.createGain(), l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = 4.6; lg.gain.value = .28; l.connect(lg); lg.connect(tg.gain); tg.connect(node); node = tg; l.start(t); l.stop(end + .05); }
  const src = ctx.createBufferSource(); src.buffer = b; src.playbackRate.value = rate * (tonal ? 1 : .97 + Math.random() * .06); src.connect(node);
  const peak = (LEVEL[key] ?? .4) * Math.pow(v, 1.35) * (o.mel ? MEL_GAIN : 1), a = o.attack ?? (SUSTAIN.has(key) ? .05 : .002);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(peak, t + a);
  if (tonal && t + dur < end) g.gain.setTargetAtTime(0, t + Math.max(a, dur), rel / 3);
  src.start(t, off); src.stop(end + .05);
  return true;
}

// ------------------------------------------------------------ estilos de acompañamiento
// Cada estilo recibe un compás (x: acordes, sección, estado, aleatorio…) y añade eventos con add(inst, pulso, midi, pulsos, vel, opciones).
// El estado `st` guarda la última voz de cada instrumento para encadenar los acordes con conducción de voces.
const CAST = {
  bossa: {bass: 'upright', counter: 'strings', fill: 'guitar', roll: 'guitar'},
  swing: {bass: 'upright', counter: 'clarinet', fill: 'vibes', roll: 'piano'},
  waltz: {bass: 'upright', counter: 'strings', fill: 'harp', roll: 'harp'},
  pop: {bass: 'ebass', counter: 'strings', fill: 'guitar', roll: 'piano'},
  rumba: {bass: 'upright', counter: 'strings', fill: 'guitar', roll: 'guitar'},
  ambient: {bass: 'sub', counter: 'strings', fill: 'harp', roll: 'harp'},
  drive: {bass: 'synthbass', counter: 'clarinet', fill: 'harp', roll: 'harp'},
  night: {bass: 'upright', counter: 'clarinet', fill: 'vibes', roll: 'epiano'},
  lounge: {bass: 'upright', counter: 'strings', fill: 'guitar', roll: 'epiano'},
};
function comp(x, inst, beats, low, high, vel, dur, opt = {}) {
  const {chords, add, st} = x;
  for (const p of beats) { const c = at(chords, p); const v = st[inst] = led(c.c, low, high, st[inst]); v.forEach((n, k) => add(inst, p + (opt.strum ? (opt.up ? v.length - 1 - k : k) * opt.strum : 0), n, typeof dur === 'function' ? dur(p) : dur, vel * (k === v.length - 1 ? 1.08 : 1), opt)); }
}
function padLong(x, inst, low, high, vel, opt = {}) { for (const c of x.chords) { const v = x.st[inst] = led(c.c, low, high, x.st[inst], false); v.forEach(n => x.add(inst, c.start, n, c.len, vel, opt)); } }
function arp(x, inst, c, start, len, step, low, vel, up = true, opt = {}) {
  const t = led(c.c, low, low + 14, null, false), seq = up ? [...t, ...t.map(n => n + 12)] : [...t.map(n => n + 12), ...t].reverse();
  for (let p = 0, k = 0; p < len - 1e-6; p += step, k++) x.add(inst, start + p, seq[k % seq.length], step * 2.2, vel * (k % 2 ? .85 : 1), opt);
}
/** Redoble o «fill» de batería en el último compás de la sección. */
function fill(x, kind) {
  const {add, M} = x, s = M - 1;
  if (kind === 'snare') [0, .25, .5, .75].forEach((d, k) => add('snare', s + d, 0, .1, .35 + k * .12));
  if (kind === 'toms') { [0, .25, .5, .75].forEach((d, k) => add(k < 2 ? 'quinto' : 'tumba', s + d, 0, .1, .45 + k * .1)); add('snare', s + .75, 0, .1, .5); }
  if (kind === 'conga') [0, .25, .5, .75].forEach((d, k) => add(k % 2 ? 'conga' : 'quinto', s + d, 0, .1, .4 + k * .08));
  if (kind === 'bongo') [0, .25, .5, .75].forEach((d, k) => add('bongo', s + d, 0, .1, .4 + k * .1));
  if (kind === 'brush') [.0, .33, .67].forEach((d, k) => add('ghost', s + d, 0, .1, .35 + k * .1));
}
function bassLine(x, inst, patt, low = 36) {
  const {chords, add, next, rand} = x;
  chords.forEach((c, ci) => {
    const nextC = chords[ci + 1]?.c || next;
    for (const [p, what, d, v] of patt) {
      if (p >= c.len - 1e-6) continue;
      let n = what === 'r' ? bassNote(c.c, low) : what === '5' ? fifth(c.c, low) : what === '8' ? bassNote(c.c, low) + 12 : what === '3' ? third(c.c, low) : null;
      if (what === 'a') n = rand() < .55 ? approach(bassNote(nextC, low), bassNote(c.c, low)) : fifth(c.c, low);
      if (n !== null) add(inst, c.start + p, n, d, v);
    }
  });
}
/** Escala para los adornos: frigio dominante sobre los acordes de séptima (el giro andaluz), eólica en menores y jónica en mayores. */
function scaleFor(c) {
  const dom = c.iv.includes(4) && c.iv.includes(10), minor = c.iv.includes(3);
  return (dom ? [0, 1, 4, 5, 7, 8, 10] : minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map(k => pcOf(c.root + k));
}
/** «Falseta»: respuesta breve de guitarra que baja por la escala del acorde y acaba en una nota del acorde. */
function falseta(add, c, beat, len, from, vel) {
  while (from > 79) from -= 12; while (from < 60) from += 12;
  const pcs = scaleFor(c), ct = c.iv.map(i => pcOf(c.root + i)), steps = Math.max(3, Math.min(7, Math.round(len / .5))), out = [];
  let n = from + 2;
  for (let k = 0; k < steps; k++) { do n--; while (!pcs.includes(pcOf(n))); out.push(n); }
  while (!ct.includes(pcOf(out.at(-1)))) out[out.length - 1]--;
  out.forEach((m, k) => add('guitar', beat + k * .5 + (k === 1 ? .04 : 0), m, k === out.length - 1 ? 1.2 : .55, vel * (k === 0 ? 1.1 : 1), {rev: .32}));
}
/** Rasgueado: un rasgueo de adorno muy rápido justo antes del acorde. */
function rasgueado(add, c, st, vel) {
  const v = st.rasg = led(c, 50, 71, st.rasg, false).concat([bassNote({...c, bass: c.root}, 40)]).sort((a, b) => a - b);
  v.forEach((n, k) => { add('guitar', -.14 + (v.length - 1 - k) * .012, n, .2, vel * .45); add('guitar', k * .028, n, 1.2, vel); });
}
const STYLES = {
  bossa(x) {
    const {i, sec, add, cast} = x, alt = i % 2;
    comp(x, sec.comp || 'guitar', alt ? [.5, 2, 3.5] : [0, 1.5, 3], 52, 70, .42, .5, {strum: .02});
    if ((sec.key === 'B' || sec.pad) && sec.comp !== 'epiano') padLong(x, 'epiano', 53, 69, .2, {rev: .35});
    if ((sec.key === 'B' || sec.pad) && sec.comp === 'epiano') for (const p of [.5, 1.5, 2.5, 3.5]) add('guitar', p, led(at(x.chords, p).c, 58, 70, null)[1], .2, .2);
    bassLine(x, cast.bass, [[0, 'r', 1.4, .8], [1.5, '5', .45, .6], [2, 'r', 1.4, .75], [3.5, 'a', .45, .55]]);
    if (!sec.light) {
      (alt ? [1, 2.5] : [0, 1.5, 3]).forEach(p => add('rim', p, 0, .1, .5));
      for (let p = 0; p < 4; p += .5) add('shaker', p, 0, .1, p % 1 ? .55 : .3);
      add('cajon', 0, 0, .1, .4); add('cajon', 2, 0, .1, .34); [1, 3].forEach(p => add('hatpedal', p, 0, .1, .35));
      if (sec.pad) { add('congamute', 0, 0, .1, .35); add('conga', 3, 0, .1, .45); add('conga', 3.5, 0, .1, .4); if (alt) add('quinto', 1.5, 0, .1, .35); }
      if (x.last) fill(x, 'bongo');
    }
    if (sec.pad) padLong(x, 'strings', 60, 76, .3, {attack: .5});
  },
  swing(x) {
    const {chords, add, sec, next, rand, st, cast} = x;
    const push = rand() < .3 && !x.last;
    comp(x, 'piano', push ? [0, 1.5] : [0, 1.5, 2.5], 50, 68, .34, p => (p ? .35 : .6));
    if (push) { const v = st.piano = led(next, 50, 68, st.piano); v.forEach(n => add('piano', 3.5, n, .5, .36)); }
    const beats = [];
    for (const c of chords) for (let b = 0; b < c.len; b++) beats.push({c: c.c, b, last: b === c.len - 1});
    beats.forEach((y, k) => {
      const nextRoot = k + 1 < beats.length ? beats[k + 1].c : next || y.c, cur = bassNote(y.c, 34);
      const n = y.b === 0 ? cur : y.last ? approach(bassNote(nextRoot, 34), cur) : y.b === 1 ? third(y.c, 34) : fifth(y.c, 34);
      add(cast.bass, k, n, .9, k % 2 ? .7 : .8);
      if (rand() < .12 && !y.last) add(cast.bass, k + .67, n, .2, .35);
    });
    if (!sec.light) {
      [0, 1, 1.67, 2, 3, 3.67].forEach(p => add('ride', p, 0, .4, p % 1 ? .3 : p % 2 ? .55 : .42));
      [1, 3].forEach(p => add('hatpedal', p, 0, .05, .45)); [0, 1, 2, 3].forEach(p => add('brush', p, 0, .2, .25));
      if (rand() < .3) add('ghost', rand() < .5 ? 2.67 : 3.67, 0, .1, .3);
      if (x.first && (sec.key === 'B' || sec.pad)) add('crash', 0, 0, 1, .3);
      if (x.last) fill(x, 'brush');
    }
    if (sec.pad) padLong(x, 'strings', 60, 74, .22, {attack: .5});
  },
  waltz(x) {
    const {chords, add, sec, rand, next, st, cast} = x, c = chords[0];
    const root = x.i % 2 ? fifth(c.c, 36) : bassNote(c.c, 36);
    add(cast.bass, 0, root, .9, .8);
    if (chords.length === 1 && rand() < .45) add(cast.bass, 2, approach(bassNote(next, 36), root), .45, .5);
    comp(x, 'piano', [1, 2], 55, 72, .3, .5);
    if (sec.pad) { const t = led(at(chords, 0).c, 55, 70, null, false), s = [...t, ...t.map(n => n + 12)]; [0, .5, 1, 1.5, 2, 2.5].forEach((p, k) => add('harp', p, s[k % s.length], 1, .3)); }
    if (!sec.light) {
      [1, 2].forEach(p => add('brush', p, 0, .05, .22)); [1, 2].forEach(p => add('hatpedal', p, 0, .05, .26));
      if (x.last && !sec.pad) add('swell', 3 - 2 / x.spb, 0, 2, .32);
    }
    if (sec.pad) padLong(x, 'strings', 62, 76, .25, {attack: .4});
  },
  pop(x) {
    const {add, sec, rand, cast} = x;
    comp(x, 'piano', [0, 1, 1.5, 2.5, 3], 55, 72, .3, .4);
    if (sec.key === 'B' || sec.pad) comp(x, 'guitar', [0, 1.5, 2, 3, 3.5], 52, 69, .32, .35, {strum: .03});
    bassLine(x, cast.bass, [[0, 'r', .9, .8], [1.5, 'r', .45, .6], [2, '5', .9, .7], [3, '8', .45, .6], [3.5, 'a', .45, .55]]);
    if (!sec.light) {
      add('cajon', 0, 0, .1, .7); add('cajon', 2.5, 0, .1, .5); if (sec.pad) add('cajon', 1.5, 0, .1, .35);
      [1, 3].forEach(p => add('snare', p, 0, .1, .5)); if (rand() < .4) add('ghost', 3.75, 0, .1, .28);
      for (let p = 0; p < 4; p += .5) add(p === 3.5 && x.i % 2 ? 'hatopen' : 'hat', p, 0, .05, p % 1 ? .45 : .28);
      if (x.first && sec.pad) add('crash', 0, 0, 1, .35);
      if (x.last) fill(x, sec.pad ? 'toms' : 'snare');
    }
    if (sec.pad) padLong(x, 'strings', 64, 79, .26, {attack: .3});
  },
  ambient(x) {
    const {chords, add, sec, st, cast} = x;
    for (const c of chords) {
      st.pad = led(c.c, 48, 64, st.pad, false); st.pad.forEach(n => add('pad', c.start, n, c.len, .09));
      add(cast.bass, c.start, bassNote(c.c, 33), c.len, .09);
      if (sec.key === 'A' || sec.pad) arp(x, 'piano', c, c.start, c.len, .5, 60, .11, x.i % 2 === 0, {del: .3, rev: .45});
      if (sec.key === 'B' || sec.pad) arp(x, 'harp', c, c.start + .25, Math.min(2, c.len), .25, 55, .15, true);
    }
    if (sec.pad) padLong(x, 'strings', 62, 78, .2, {attack: 1.2});
    if (!sec.light) { add('kick', 0, 0, .1, .1); for (let p = .5; p < 4; p += 1) add('hat', p, 0, .05, .16); if (sec.pad) for (let p = .25; p < 4; p += .5) add('shaker', p, 0, .1, .2); }
    if (x.last && !sec.light) add('swell', 4 - 2 / x.spb, 0, 2, .3);
  },
  drive(x) {
    const {chords, add, sec, st, cast} = x;
    for (const c of chords) {
      const r = bassNote(c.c, 48) + 12, f = r + 7, t = voicing(c.c, r, false)[0] || r + 4, seq = [r, f, r + 12, f, t, f, r + 12, f];
      for (let p = 0; p < c.len; p += .5) { const k = Math.round(p * 2) % 8; add('guitar', c.start + p, seq[k], .6, k % 2 ? .24 : .3, {del: .18}); if (sec.key === 'B' && k % 4 === 0) add('harp', c.start + p, seq[k] + 12, .8, .18); }
      st.pad = led(c.c, 52, 67, st.pad, false); st.pad.forEach(n => add('pad', c.start, n, c.len, .22, {attack: .4, bright: true}));
      for (let p = 0; p < c.len; p += .5) add(cast.bass, c.start + p, bassNote(c.c, 36) + (sec.pad && p % 1 ? 12 : 0), .4, p % 1 ? .11 : .15);
    }
    if (sec.pad) padLong(x, 'strings', 60, 76, .3, {attack: .25});
    if (!sec.light) {
      (sec.pad || sec.key === 'B' ? [0, 1, 2, 3] : [0, 2]).forEach(p => add('kick', p, 0, .1, .22));
      if (sec.key === 'B' || sec.pad) [1, 3].forEach(p => add('snare', p, 0, .1, .42));
      for (let p = 0; p < 4; p += .25) add(sec.pad && p % 1 === .5 ? 'hatopen' : 'hat', p, 0, .05, p % 1 === .5 ? .4 : p % .5 ? .18 : .26);
      if (x.first && (sec.key === 'B' || sec.pad)) add('crash', 0, 0, 1, .32);
      if (x.last) fill(x, 'toms');
    }
  },
  night(x) {
    const {chords, add, sec, st, cast} = x;
    for (const c of chords) {
      st.epiano = led(c.c, 52, 68, st.epiano); st.epiano.forEach(n => add('epiano', c.start, n, c.len * .95, .36, {trem: true, del: .2}));
      add(cast.bass, c.start, bassNote(c.c, 33), Math.min(c.len, 2), .55); add('sub', c.start, bassNote(c.c, 33), c.len, .12);
      if (sec.pad) { padLong(x, 'pad', 60, 74, .3, {attack: 2}); const t = led(c.c, 64, 78, null, false); t.forEach((n, k) => add('vibes', c.start + 1 + k * .5, n, 1.5, .2, {del: .2})); }
    }
    if (!sec.light) {
      add('cajon', 0, 0, .1, .32); add('cajon', 2.5, 0, .1, .22); [1, 3].forEach(p => add('rim', p, 0, .1, .4));
      for (let p = 0; p < 4; p += .5) add('hat', p + (p % 1 ? .08 : 0), 0, .05, p % 1 ? .2 : .14);
      if (sec.pad) { add('tumba', 3.5, 0, .1, .3); add('congamute', 1.5, 0, .1, .25); }
      if (x.last) add('swell', 4 - 2 / x.spb, 0, 2, .26);
    }
  },
  rumba(x) {
    const {add, sec, cast} = x;
    // rasgueo de rumba: abajo en los tiempos, arriba en los contratiempos, con acentos en 1, 2-y y 4
    [[0, .46, false], [.5, .24, true], [1, .32, false], [1.5, .4, true], [2, .3, false], [2.5, .26, true], [3, .38, false], [3.5, .3, true]]
      .forEach(([p, v, up]) => comp(x, 'guitar', [p], 50, 69, v, .3, {strum: .018, up}));
    bassLine(x, cast.bass, [[0, 'r', .9, .8], [1.5, '5', .45, .55], [2, 'r', .9, .7], [3.5, 'a', .45, .5]]);
    if (!sec.light) {
      add('cajon', 0, 0, .1, .5); add('cajon', 2.5, 0, .1, .4); [1, 3].forEach(p => add('cajonslap', p, 0, .1, .36));
      if (sec.key === 'B' || sec.pad) [.5, 1.5, 2.5, 3.5].forEach(p => add('claps', p, 0, .1, .26, {lp: 2200}));
      if (sec.pad) [1, 3].forEach(p => add('claps', p, 0, .1, .3));
      if (x.last) [0, .25, .5, .75].forEach((d, k) => add('cajonslap', 3 + d, 0, .1, .3 + k * .1));
    }
    if (sec.pad) padLong(x, 'strings', 60, 76, .24, {attack: .5});
  },
  lounge(x) {
    const {add, sec, cast} = x;
    comp(x, 'epiano', [0, 1.5, 2.5, 3.5], 53, 69, .32, p => (p % 1 ? .4 : .8));
    for (const p of [.5, 1.5, 2.5, 3.5]) { const c = at(x.chords, p).c; add('guitar', p, led(c, 60, 72, null)[1], .2, .22); }
    bassLine(x, cast.bass, [[0, 'r', 1.4, .8], [1.5, '5', .45, .6], [2.5, '8', .45, .55], [3.5, 'a', .45, .5]]);
    if (!sec.light) {
      add('cajon', 0, 0, .1, .5); add('cajon', 2.5, 0, .1, .38); [1, 3].forEach(p => add('rim', p, 0, .1, .42));
      for (let p = 0; p < 4; p += .25) add('shaker', p, 0, .1, p % .5 ? .18 : p % 1 ? .4 : .28);
      if (sec.key === 'B' || sec.pad) [0, .5, 1, 1.5, 2, 2.5, 3].forEach((p, k) => add('bongo', p, 0, .1, k % 2 ? .22 : .3));
      if (sec.pad) add('hatopen', 3.5, 0, .1, .25);
      if (x.last) fill(x, 'conga');
    }
    if (sec.pad) padLong(x, 'strings', 62, 76, .22, {attack: .8});
  },
};
function at(chords, p) { return chords.reduce((best, c) => (c.start <= p ? c : best), chords[0]); }

// ------------------------------------------------------------ las doce piezas
// Melodía: «nota:pulsos», «-:pulsos» para silencio. Acordes por compás («Gm7 C9» divide el compás).
export const SONGS = [
  {id: 'anden1', title: 'Andén 1', family: 'estacion', mood: 'any', style: 'bossa', bpm: 108, meter: 4, lead: ['guitar', 'clarinet'], leads: {A: 'guitar', B: 'guitar', A2: 'clarinet', B2: 'clarinet'},
    A: {chords: ['Fmaj7', 'Gm7 C9', 'Fmaj7', 'Am7 D7b9', 'Gm7', 'C9', 'Fmaj7', 'Gm7 C7'],
      mel: 'A4:1.5 C5:.5 E5:1 D5:1 D5:1.5 Bb4:.5 G4:1 E5:1 F5:2 E5:.5 D5:.5 C5:1 E5:1.5 C5:.5 F#5:1 Eb5:1 D5:1.5 Bb4:.5 A4:.5 G4:.5 F4:1 G4:1 A4:.5 Bb4:.5 D5:2 C5:3 -:1 Bb4:1 A4:1 G4:1 E4:1'},
    B: {chords: ['Bbmaj7', 'Bbm6 Eb9', 'Am7', 'D9', 'Gm7', 'C13', 'Fmaj9', 'Gm7 C7'],
      mel: 'D5:1 F5:1 A5:2 G5:1.5 F5:.5 Db5:2 C5:1 E5:1 G5:1.5 E5:.5 F#5:2 E5:1 D5:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 D5:1 Bb4:1 A4:1 G4:1 A4:2 -:2 C5:1 E5:1'}},
  {id: 'primera', title: 'Primera salida', family: 'red', mood: 'day', style: 'ambient', bpm: 74, meter: 4, lead: ['piano', 'strings'], leads: {A: 'piano', B: 'piano', A2: 'strings', B2: 'piano'},
    A: {chords: ['Dmaj9', 'Bm11', 'Gmaj7', 'A6', 'Dmaj9', 'F#m7', 'Gmaj9', 'Asus4 A'],
      mel: 'F#5:2 A5:1 E5:1 D5:3 -:1 B4:1 D5:1 F#5:2 E5:3 C#5:1 F#5:2 A5:1 B5:1 A5:2 C#6:1 A5:1 B5:2 F#5:2 E5:4'},
    B: {chords: ['Bm9', 'Gmaj7', 'Dmaj7/F#', 'Em9', 'Bm9', 'Gmaj9', 'Em7', 'Asus4'],
      mel: 'D6:2 C#6:1 B5:1 A5:3 -:1 A5:1 F#5:1 D5:2 E5:2 G5:1 F#5:1 D6:2 E6:1 F#6:1 E6:2 D6:1 B5:1 G5:2 B5:1 A5:1 A5:3 -:1'}},
  {id: 'verano', title: 'Horario de verano', family: 'estacion', mood: 'any', style: 'pop', bpm: 92, meter: 4, lead: ['piano', 'strings'], leads: {A: 'piano', B: 'guitar', A2: 'strings', B2: 'clarinet'},
    A: {chords: ['C', 'G/B', 'Am7', 'F', 'C/E', 'Dm7', 'F G', 'C'],
      mel: 'E5:.5 G5:.5 C6:1 B5:.5 A5:.5 G5:1 G5:.5 D5:.5 G5:1 F5:.5 E5:.5 D5:1 C5:.5 E5:.5 A5:1 G5:.5 E5:.5 C5:1 A4:.5 C5:.5 F5:1.5 E5:.5 D5:1 E5:.5 G5:.5 C6:1 D6:.5 C6:.5 G5:1 F5:1 A5:1 D5:1.5 E5:.5 F5:1 A5:1 G5:1 B5:1 C6:3 -:1'},
    B: {chords: ['Am', 'Em', 'F', 'C', 'Dm7', 'G', 'Em7 A7', 'Dm7 G7'],
      mel: 'A5:1.5 G5:.5 E5:2 G5:1.5 F5:.5 E5:2 F5:1 A5:1 C6:1 A5:1 G5:3 E5:1 F5:1.5 E5:.5 D5:1 C5:1 B4:1 D5:1 G5:2 G5:1 E5:1 C#5:1 E5:1 F5:1 D5:1 B4:1 G4:1'}},
  {id: 'vialibre', title: 'Vía libre', family: 'red', mood: 'day', style: 'drive', bpm: 104, meter: 4, lead: ['guitar', 'strings'], leads: {A: 'guitar', B: 'strings', A2: 'clarinet', B2: 'strings'},
    A: {chords: ['Em9', 'Cmaj7', 'G', 'D/F#', 'Em9', 'Cmaj9', 'Am7', 'Dsus4 D'],
      mel: 'B4:3 G4:1 E5:4 D5:3 B4:1 A4:4 B4:2 E5:2 G5:3 F#5:1 E5:2 C5:2 D5:4'},
    B: {chords: ['Cmaj7', 'G/B', 'Am7', 'Em7', 'Cmaj7', 'D', 'Bm7', 'Em'],
      mel: 'G5:2 E5:1 G5:1 D6:3 B5:1 C6:2 B5:1 A5:1 G5:4 E5:2 G5:2 A5:2 F#5:1 D5:1 B5:2 A5:1 F#5:1 E5:4'}},
  {id: 'tarifa', title: 'Tarifa reducida', family: 'estacion', mood: 'any', style: 'swing', swing: true, bpm: 112, meter: 4, lead: ['piano', 'vibes'], leads: {A: 'piano', B: 'piano', A2: 'vibes', B2: 'vibes'}, cast: {counter: 'mtrumpet'},
    A: {chords: ['Bbmaj7', 'G7', 'Cm7', 'F7', 'Dm7 G7', 'Cm7 F7', 'Bbmaj7 G7', 'Cm7 F7'],
      mel: 'D5:1 F5:.5 G5:.5 A5:1 F5:1 B5:1.5 A5:.5 G5:1 F5:1 Eb5:1 G5:.5 Bb5:.5 C6:1 Bb5:1 A5:2 F5:1 -:1 F5:.5 G5:.5 A5:1 B5:1 D6:1 C6:.5 Bb5:.5 G5:1 A5:1 Eb5:1 D5:2 B4:1 D5:1 C5:1 Eb5:1 A4:1 -:1'},
    B: {chords: ['D7', 'D7', 'G7', 'G7', 'C7', 'C7', 'F7', 'F7'],
      mel: 'F#5:1 A5:1 C6:2 A5:.5 F#5:.5 D5:1 -:2 B4:1 D5:1 F5:2 G5:.5 F5:.5 D5:1 -:2 E5:1 G5:1 Bb5:2 G5:.5 E5:.5 C5:1 -:2 A4:1 C5:1 Eb5:2 F5:2 -:2'}},
  {id: 'medianoche', title: 'Talgo a medianoche', family: 'red', mood: 'night', style: 'night', bpm: 64, meter: 4, lead: ['guitar', 'vibes'], leads: {A: 'guitar', B: 'guitar', A2: 'vibes', B2: 'clarinet'}, spanish: {falseta: true}, intro: ['Am', 'G', 'F', 'E7'], outro: ['Dm9', 'Fmaj7', 'E7b9', 'Am9'],
    A: {chords: ['Am9', 'Fmaj7', 'Dm9', 'E7sus4 E7', 'Am9', 'Cmaj7', 'Fmaj7', 'E7sus4 E7'],
      mel: 'E5:2 C5:1 B4:1 A4:3 -:1 F5:2 E5:1 D5:1 E5:3 -:1 G5:2 E5:1 C5:1 D5:1 E5:1 G5:2 A5:2 C6:1 A5:1 G#5:3 -:1'},
    B: {chords: ['Dm9', 'G13', 'Cmaj9', 'Fmaj7', 'Bm7b5', 'E7b9', 'Am9', 'Am9'],
      mel: 'A5:2 F5:1 E5:1 F5:3 -:1 E5:1 G5:1 B5:2 A5:3 -:1 D5:2 F5:1 A5:1 G#5:2 F5:1 D5:1 C5:2 B4:1 A4:1 A4:3 -:1'}},
  {id: 'norte', title: 'Estación del Norte', family: 'estacion', mood: 'any', style: 'waltz', bpm: 126, meter: 3, lead: ['strings', 'clarinet'], leads: {A: 'strings', B: 'clarinet', A2: 'strings', B2: 'clarinet'}, form: ['intro', 'A', 'A2', 'B', 'A', 'B2', 'A2', 'B', 'A', 'B2', 'A2', 'outro'],
    A: {chords: ['G', 'Em', 'Am7', 'D7', 'G', 'B7', 'Em', 'A7 D7'],
      mel: 'D5:2 B4:1 G5:2 E5:1 C5:2 E5:1 F#5:2 D5:1 B5:2 G5:1 F#5:1 D#5:1 B4:1 E5:2 G5:1 C#5:1.5 F#5:1.5'},
    B: {chords: ['C', 'G', 'Am', 'D', 'C', 'G/B', 'Am7 D7', 'G'],
      mel: 'E5:1 G5:1 C6:1 B5:2 D5:1 C5:1 E5:1 A5:1 F#5:2 A5:1 G5:1 E5:1 C5:1 D5:2 G5:1 A5:1.5 F#5:1.5 G5:3'}},
  {id: 'mediterraneo', title: 'Corredor Mediterráneo', family: 'red', mood: 'day', style: 'drive', bpm: 96, meter: 4, lead: ['guitar', 'strings'], leads: {A: 'guitar', B: 'strings', A2: 'guitar', B2: 'strings'}, spanish: {falseta: true, rasgueo: true, palmas: true}, intro: ['Gm', 'F', 'Ebmaj7', 'Cm7 F'], outro: ['Gm', 'F', 'Ebmaj7', 'Bb'],
    A: {chords: ['Bb', 'F/A', 'Gm7', 'Ebmaj7', 'Bb/D', 'Ebmaj9', 'Cm7', 'F'],
      mel: 'D5:2 F5:2 C5:3 F4:1 Bb4:2 D5:2 G5:3 -:1 F5:2 Bb5:2 G5:2 F5:1 Eb5:1 Eb5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Gm', 'Ebmaj7', 'Bb', 'F', 'Gm', 'Eb', 'Cm7', 'F'],
      mel: 'Bb5:2 A5:1 G5:1 G5:3 Bb5:1 F5:2 D5:2 C5:4 D5:1 Eb5:1 F5:1 G5:1 G5:2 Bb5:2 Eb6:2 D6:1 C6:1 C6:4'}},
  {id: 'ancho', title: 'Cambio de ancho', family: 'estacion', mood: 'any', style: 'lounge', bpm: 84, meter: 4, lead: ['vibes', 'epiano'], leads: {A: 'vibes', B: 'vibes', A2: 'epiano', B2: 'clarinet'},
    A: {chords: ['Ebmaj7', 'Cm7', 'Fm7', 'Bb7', 'Gm7', 'C7b9', 'Fm7', 'Bb7sus4 Bb7'],
      mel: 'G5:1.5 Bb5:.5 D6:1 C6:1 Bb5:1.5 G5:.5 Eb5:2 Ab5:1 G5:.5 F5:.5 C5:1 Ab4:1 D5:2 F5:1 -:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 Db5:1 Bb4:1 Ab4:1 C5:1 Eb5:1 Ab5:1 G5:2 F5:2'},
    B: {chords: ['Abmaj7', 'Gm7', 'Fm7', 'Ebmaj7', 'Dm7b5', 'G7b9', 'Cm7', 'F7 Bb7'],
      mel: 'C6:1.5 Bb5:.5 G5:2 Bb5:1.5 F5:.5 D5:2 Ab5:1 G5:1 F5:1 Eb5:1 G5:3 -:1 F5:1 Ab5:1 C6:2 B5:1.5 Ab5:.5 F5:2 Eb5:1 G5:1 Bb5:1 G5:1 A5:2 Ab5:2'}},
  {id: 'meseta', title: 'Atardecer en la meseta', family: 'red', mood: 'dusk', style: 'ambient', bpm: 68, meter: 4, lead: ['piano', 'strings'], leads: {A: 'piano', B: 'piano', A2: 'strings', B2: 'piano'},
    A: {chords: ['Fmaj7#11', 'C/E', 'Dm9', 'Bbmaj7', 'Fmaj7', 'Am7', 'Bbmaj9', 'Csus4 C'],
      mel: 'A5:2 C6:1 B5:1 G5:4 F5:2 A5:1 E5:1 D5:4 C5:1 F5:1 A5:2 G5:2 E5:2 F5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Dm7', 'Bbmaj7', 'F/A', 'Gm9', 'Dm9', 'Bbmaj7#11', 'Gm7', 'Csus4'],
      mel: 'F6:2 E6:1 D6:1 D6:3 -:1 C6:2 A5:1 F5:1 G5:3 -:1 A5:2 C6:1 E6:1 D6:2 E6:1 F6:1 D6:2 Bb5:1 G5:1 G5:4'}},
  {id: 'pasajeros', title: 'Pasajeros al tren', family: 'estacion', mood: 'any', style: 'rumba', bpm: 116, meter: 4, lead: ['guitar', 'clarinet'], leads: {A: 'guitar', B: 'guitar', A2: 'clarinet', B2: 'guitar'}, spanish: {falseta: true, rasgueo: true, palmas: true}, intro: ['Em', 'D', 'C', 'D7'], outro: ['C', 'B7', 'Em', 'Gmaj7'],
    A: {chords: ['Gmaj7', 'Am7 D9', 'Bm7 E7', 'Am7 D7', 'Gmaj7', 'Em7', 'A9', 'Am7 D7'],
      mel: 'B4:1 D5:.5 F#5:.5 A5:2 G5:1 E5:1 C5:1 F#5:1 D5:1.5 B4:.5 G#5:1 D5:1 C5:1 E5:1 F#5:2 B5:1.5 A5:.5 F#5:1 D5:1 E5:2 G5:1 B5:1 C#6:1.5 B5:.5 G5:1 E5:1 A5:2 F#5:2'},
    B: {chords: ['Cmaj7', 'Cm6 F9', 'Bm7', 'E7', 'Am7', 'D9', 'Gmaj7', 'Am7 D7'],
      mel: 'E5:1 G5:1 B5:2 A5:1.5 G5:.5 Eb5:2 D5:1 F#5:1 A5:2 G#5:2 E5:2 C5:1 E5:1 G5:1 B5:1 A5:1.5 F#5:.5 E5:2 D5:4 -:2 C5:1 F#5:1'}},
  {id: 'obras', title: 'Obras nocturnas', family: 'red', mood: 'night', style: 'night', bpm: 78, meter: 4, lead: ['piano', 'vibes'], leads: {A: 'piano', B: 'piano', A2: 'vibes', B2: 'strings'}, spanish: {falseta: true}, intro: ['Dm', 'C', 'Bbmaj7', 'A7'], outro: ['Gm9', 'Bbmaj7', 'A7b9', 'Dm9'],
    A: {chords: ['Dm9', 'Bbmaj7', 'Gm9', 'A7sus4', 'Dm9', 'Fmaj7', 'Gm7', 'Asus4 A7'],
      mel: 'A5:1 F5:1 E5:1 D5:1 D5:3 -:1 Bb5:1 A5:1 F5:1 D5:1 E5:3 -:1 A5:1 C6:1 E6:1 D6:1 C6:3 -:1 Bb5:1 A5:1 G5:1 F5:1 E5:2 C#5:2'},
    B: {chords: ['Gm9', 'C9', 'Fmaj7', 'Bbmaj7', 'Em7b5', 'A7b9', 'Dm9', 'Dm9'],
      mel: 'Bb5:2 D6:2 E6:2 Bb5:2 A5:2 C6:1 A5:1 F5:4 G5:2 Bb5:1 E5:1 C#5:2 E5:1 G5:1 F5:2 E5:1 D5:1 D5:4'}},
];
export const FAMILY_LABEL = {estacion: 'Estilo «Estación»: bossa, rumba, jazz, vals y pop', red: 'Estilo «Red»: ambiental orquestal'};
export const STYLE_LABEL = {rumba: 'Rumba suave', bossa: 'Bossa nova', swing: 'Jazz ligero', waltz: 'Vals', pop: 'Pop alegre', lounge: 'Lounge', ambient: 'Ambiental', drive: 'Ambiental rítmica', night: 'Nocturna'};

function parseMel(str) {
  const out = []; let beat = 0;
  for (const tok of str.trim().split(/\s+/)) { const [n, d] = tok.split(':'); out.push({beat, midi: n === '-' ? null : midi(n), dur: +d}); beat += +d; }
  return {notes: out, beats: beat};
}
/** Comprueba que cada sección tiene la duración exacta de sus compases. */
export function validate(song) {
  for (const k of ['A', 'B']) { const {beats} = parseMel(song[k].mel), want = song[k].chords.length * song.meter; if (Math.abs(beats - want) > 1e-6) throw Error(`${song.title} ${k}: ${beats} pulsos, se esperaban ${want}`); song[k].chords.forEach(b => b.split(' ').forEach(chord)); }
  return true;
}

// ------------------------------------------------------------ composición de eventos
function rng(seed) { let x = 0; for (const c of seed) x = (x * 31 + c.charCodeAt(0)) >>> 0; return () => ((x = (Math.imul(x, 1664525) + 1013904223) >>> 0) / 4294967296); }
/** Convierte una pieza en una lista de eventos {t (s), inst, midi, dur (s), vel, opt}.
 *  La melodía de cada sección se toca tal cual está escrita (marcada con opt.mel); el arreglo añade conducción de
 *  voces, segunda voz en las secciones «2», respuestas en los silencios de la melodía, redobles, crescendos de
 *  platillo y una subida de tono de un semitono en la última vuelta de las piezas animadas. */
export function arrange(song) {
  const spb = 60 / song.bpm, M = song.meter, rand = rng(song.id), events = [], st = {};
  const form = song.form || ['intro', 'A', 'B', 'A2', 'B2', 'A', 'B', 'A2', 'outro'];
  const cast = {...CAST[song.style], ...(song.cast || {})};
  const lift = !!song.lift, sp = song.spanish || {};
  const liftFrom = lift ? form.lastIndexOf('A2') : -1;
  const DYN = {intro: .78, A: .92, B: 1, A2: 1.04, B2: 1.08, outro: .8};
  const swing = b => { if (!song.swing) return b; const f = b - Math.floor(b); return Math.abs(f - .5) < 1e-6 ? Math.floor(b) + .67 : b; };
  let bar0 = 0;
  form.forEach((part, si) => {
    const key = part[0] === 'B' ? 'B' : 'A', sec = song[key], tr = liftFrom >= 0 && si >= liftFrom ? 1 : 0;
    let bars = sec.chords;
    if (part === 'intro') bars = song.intro || sec.chords.slice(0, 4);
    if (part === 'outro') bars = song.outro || sec.chords.slice(-4, -1).concat([sec.chords[0].split(' ')[0]]);
    const info = {key, part, light: part === 'intro' || part === 'outro', pad: part.endsWith('2'), comp: song.style === 'bossa' && song.id === 'pasajeros' ? 'guitar' : song.style === 'bossa' ? 'epiano' : null};
    const dyn = DYN[part] ?? DYN[key];
    const spans = [];
    const mk = base => (inst, beat, m, dur, vel, opt = {}) => {
      const tight = ['kick', 'snare', 'clap', 'hat', 'hatopen', 'hatpedal', 'shaker', 'rim', 'brush', 'ghost', 'cajon', 'cajonslap', 'conga', 'congamute', 'quinto', 'tumba', 'bongo', 'tamb', 'ride', 'swell', 'crash'].includes(inst);
      events.push({t: Math.max(0, swing(base + beat) * spb + (rand() - .5) * (tight ? .006 : .012)), inst, midi: tight ? m : m + tr, dur: dur * spb, vel: Math.min(1, vel * (.88 + rand() * .2) * dyn), opt});
    };
    bars.forEach((spec, i) => {
      const syms = spec.split(' '), len = M / syms.length;
      const chords = syms.map((s, k) => ({c: chord(s), start: k * len, len}));
      const nextSpec = bars[i + 1] || sec.chords[0], next = chord(nextSpec.split(' ')[0]);
      const base = (bar0 + i) * M, add = mk(base);
      chords.forEach(c => spans.push({start: base + c.start, end: base + c.start + c.len, c: c.c}));
      STYLES[song.style]({i, n: bars.length, first: i === 0, last: i === bars.length - 1, chords, add, sec: info, next, st, rand, cast, M, spb, spanish: sp});
      if (sp.rasgueo && i % 2 === 0 && part !== 'outro') rasgueado(add, chords[0].c, st, info.light ? .3 : .42);
      if (sp.palmas && song.style !== 'rumba' && !info.light && info.pad) for (let p = .5; p < M; p += 1) add('claps', p, 0, .1, .2, {lp: 2200});
      if (part === 'intro') { const c = chords[0]; arp({add, st}, cast.roll, c, 0, Math.min(2, M), .25, 55, .22, true); if (i === bars.length - 1) add('swell', M - 2 / spb, 0, 2, .26); }
      if (part === 'outro' && i === bars.length - 1) {
        chords.forEach(c => { voicing(c.c, 55, false).forEach((n, k) => add(cast.roll, M + k * .12, n, M * 1.5, .34)); add(cast.bass === 'synthbass' ? 'sub' : cast.bass, M, bassNote(c.c, 33), M * 1.5, cast.bass === 'upright' || cast.bass === 'ebass' ? .5 : .2); });
        add('crash', M, 0, 2, .16);
      }
    });
    if (!info.light) {
      const {notes} = parseMel(sec.mel), lead = song.leads?.[info.pad ? key + '2' : key] || song.lead[info.pad ? 1 : 0], other = song.lead[info.pad ? 0 : 1];
      const counter = cast.counter === lead ? (lead === 'strings' ? 'clarinet' : 'strings') : cast.counter;
      const chordAt = beat => (spans.find(s => beat >= s.start - 1e-6 && beat < s.end - 1e-6) || spans.at(-1)).c;
      const melodic = notes.filter(n => n.midi !== null), hi = Math.max(...melodic.map(n => n.midi)), lo = Math.min(...melodic.map(n => n.midi));
      const add = mk(0);
      notes.forEach((n, k) => {
        const beat = bar0 * M + n.beat;
        if (n.midi === null) {
          if (n.dur >= 1 && rand() < .8) {
            const c = chordAt(beat), prev = notes.slice(0, k).reverse().find(q => q.midi !== null);
            if (sp.falseta && lead !== 'guitar') falseta(add, c, beat, Math.min(n.dur, 2), prev ? prev.midi : 72, .34);
            else arp({add, st}, cast.fill === lead ? 'harp' : cast.fill, {c}, beat, Math.min(n.dur, 2), .5, 62, .3, false);
          }
          return;
        }
        const shape = (n.midi - lo) / Math.max(1, hi - lo);
        const vel = .55 + rand() * .1 + shape * .1 + (n.dur >= 2 ? .05 : 0);
        add(lead, beat, n.midi + (lead === 'bell' ? 12 : 0), n.dur * .95, vel, {mel: true});
        if (tr && si === liftFrom && n.dur >= .5) add(other, beat, n.midi + (other === 'bell' ? 12 : n.midi > 76 ? -12 : 0), n.dur * .9, vel * .45, {});
        if (info.pad && n.dur >= 1) { const u = under(n.midi, chordAt(beat)); if (u !== null) add(counter, beat, u, n.dur * .95, .32, {}); }
        if (n.dur >= 3 && rand() < .7) {
          const c = chordAt(beat + 1.5);
          if (sp.falseta && lead !== 'guitar') falseta(add, c, beat + 1.5, Math.min(n.dur - 1.5, 2), n.midi - 3, .3);
          else arp({add, st}, cast.fill === lead ? 'harp' : cast.fill, {c}, beat + 1.5, Math.min(n.dur - 1.5, 2), .5, 62, .26, false);
        }
      });
    }
    bar0 += bars.length;
  });
  events.sort((a, b) => a.t - b.t);
  return {events, length: bar0 * M * spb + 4};
}

// ------------------------------------------------------------ mezcla y reproducción
/** Impulso de reverberación estéreo: sala cálida con predelay y agudos amortiguados. */
function impulse(ctx, seconds = 3) {
  const len = Math.floor(ctx.sampleRate * seconds), pre = Math.floor(ctx.sampleRate * .018), buf = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch); let last = 0;
    for (let i = pre; i < len; i++) { const k = (i - pre) / (len - pre), damp = .35 + .5 * k; const x = (Math.random() * 2 - 1) * Math.pow(1 - k, 3.4); last = last * damp + x * (1 - damp); d[i] = last; }
  }
  return buf;
}
/** Cadena de mezcla: seco + reverberación (sin graves) + eco, a una salida común. */
export function makeBus(ctx, dest) {
  const dry = ctx.createGain(), rev = ctx.createConvolver(), revIn = ctx.createGain(), hp = ctx.createBiquadFilter(), del = ctx.createDelay(1), delIn = ctx.createGain(), fb = ctx.createGain(), delOut = ctx.createGain(), dlp = ctx.createBiquadFilter();
  hp.type = 'highpass'; hp.frequency.value = 240; rev.buffer = impulse(ctx); revIn.connect(hp); hp.connect(rev); rev.connect(dest); revIn.gain.value = .85;
  dlp.type = 'lowpass'; dlp.frequency.value = 3500;
  del.delayTime.value = .36; fb.gain.value = .3; delOut.gain.value = .45; delIn.connect(del); del.connect(dlp); dlp.connect(fb); fb.connect(del); dlp.connect(delOut); delOut.connect(dest);
  dry.connect(dest);
  return {dry, rev: revIn, del: delIn};
}
function play(ctx, bus, e, t0) {
  const o = e.opt || {};
  if (sampled(ctx, bus, t0 + e.t, e.inst, e.midi, e.dur, e.vel, o)) return;
  const fn = SYNTH[e.inst] || SYNTH[FALLBACK[e.inst]];
  if (fn) fn(ctx, bus, t0 + e.t, e.midi, e.dur, e.vel, o);
}
/** Instrumentos que usa una lista de eventos (para decodificarlos antes de tocar). */
export const instrumentsOf = events => [...new Set(events.map(e => e.inst))];

/** Renderiza una pieza completa en un búfer (para exportar a audio). */
export async function renderSong(song, sampleRate = 44100, keep = null) {
  const {events: all, length} = arrange(song), events = keep ? all.filter(keep) : all;
  const ctx = new OfflineAudioContext(2, Math.ceil(length * sampleRate), sampleRate);
  await loadInstruments(ctx, instrumentsOf(events));
  const master = ctx.createGain(); master.gain.value = .8 * MIX_GAIN;
  const comp = ctx.createDynamicsCompressor(); comp.threshold.value = -14; comp.ratio.value = 3; master.connect(comp); comp.connect(ctx.destination);
  const bus = makeBus(ctx, master);
  for (const e of events) play(ctx, bus, e, .05);
  return ctx.startRendering();
}

/** Reproductor en tiempo real con programación anticipada y fundidos entre piezas. */
export class Soundtrack {
  constructor(getMood) {
    this.getMood = getMood; this.ctx = null; this.current = null; this.timer = null; this.mode = 'auto'; this.listeners = new Set();
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('iberia-musica') || '{}'); } catch {}
    this.volume = saved.volume ?? .55; this.enabled = saved.enabled ?? true; this.mode = saved.mode || 'auto';
  }
  save() { try { localStorage.setItem('iberia-musica', JSON.stringify({volume: this.volume, enabled: this.enabled, mode: this.mode})); } catch {} }
  on(fn) { this.listeners.add(fn); }
  emit() { for (const fn of this.listeners) fn(this); }
  init() {
    if (this.ctx) { if (this.ctx.state === 'suspended') this.ctx.resume(); return; }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    this.ctx = new AC();
    this.master = this.ctx.createGain(); this.master.gain.value = this.volume;
    const makeup = this.ctx.createGain(); makeup.gain.value = MIX_GAIN;
    const comp = this.ctx.createDynamicsCompressor(); comp.threshold.value = -16; comp.ratio.value = 3;
    this.master.connect(makeup); makeup.connect(comp); comp.connect(this.ctx.destination);
  }
  start() { this.init(); if (this.enabled && !this.current) this.next(); }
  setVolume(v) { this.volume = v; if (this.master) this.master.gain.setTargetAtTime(v, this.ctx.currentTime, .1); this.save(); this.emit(); }
  toggle() { this.enabled = !this.enabled; this.save(); if (this.enabled) { this.init(); this.next(); } else this.stop(); this.emit(); }
  setMode(m) { this.mode = m; this.save(); this.emit(); }
  pick() {
    const mood = this.getMood?.() || 'estacion', last = this.current?.song.id;
    let pool = SONGS;
    if (this.mode === 'auto') pool = SONGS.filter(s => mood === 'estacion' ? s.family === 'estacion' : mood === 'night' ? s.mood === 'night' : s.family === 'red' && s.mood !== 'night');
    if (this.mode === 'repeat' && this.current) return this.current.song;
    const list = pool.filter(s => s.id !== last);
    if (this.mode === 'list' && this.current) { const i = SONGS.indexOf(this.current.song); return SONGS[(i + 1) % SONGS.length]; }
    return (list.length ? list : pool)[Math.floor(Math.random() * (list.length || pool.length))];
  }
  stop(fade = 1.5) {
    const cur = this.current; this.current = null; clearInterval(this.timer);
    if (cur && this.ctx) { cur.gain.gain.setTargetAtTime(0, this.ctx.currentTime, fade / 4); setTimeout(() => { try { cur.gain.disconnect(); } catch {} }, fade * 1000 + 4000); }
    this.emit();
  }
  play(song) {
    this.init();
    if (!this.ctx) return;
    this.stop(1.2);
    this.enabled = true; this.save();
    const gain = this.ctx.createGain(); gain.gain.value = 0; gain.connect(this.master);
    const bus = makeBus(this.ctx, gain), {events, length} = arrange(song);
    const cur = this.current = {song, gain, bus, events, length, t0: 0, i: 0, ready: false};
    // las muestras se decodifican la primera vez; mientras, la pieza ya figura como «sonando»
    loadInstruments(this.ctx, instrumentsOf(events)).then(() => {
      if (this.current !== cur) return;
      cur.t0 = this.ctx.currentTime + .15; cur.ready = true;
      gain.gain.setTargetAtTime(1, this.ctx.currentTime, .4);
      clearInterval(this.timer);
      this.timer = setInterval(() => {
        if (this.current !== cur) return;
        const now = this.ctx.currentTime;
        while (cur.i < events.length && cur.t0 + events[cur.i].t < now + .3) { play(this.ctx, bus, events[cur.i], cur.t0); cur.i++; }
        if (now > cur.t0 + length) this.next();
      }, 60);
    });
    this.emit();
  }
  next() { if (this.enabled) this.play(this.pick()); }
  get position() { return this.current?.ready && this.ctx ? Math.max(0, this.ctx.currentTime - this.current.t0) : 0; }
}
