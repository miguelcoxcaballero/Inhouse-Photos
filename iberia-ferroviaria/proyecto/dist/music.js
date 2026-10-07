// Banda sonora original de Iberia Ferroviaria, tocada en tiempo real con Web Audio.
// Instrumentos muestreados reales, casi todos con dos capas dinámicas (piano y forte): secciones de violines, violas,
// violonchelos y contrabajos (sostenido, spiccato, pizzicato y trémolo), violín solista, arpa, flauta, oboe,
// clarinete, fagot, trompa, trompeta, trombón, tuba, timbales, piano de cola, Rhodes, vibráfono, guitarra española,
// contrabajo de jazz, saxo alto, batería y percusión (cajón, palmas, castañuelas, caja y bombo de banda…).
// Las notas sostenidas se encadenan con fundidos para durar lo que pida la partitura, las melodías se tocan ligadas
// y cada familia pasa por su propio bus (ecualización, sala de concierto o sala pequeña) antes del máster.
// Los sintetizadores, analógicos y discretos, solo aparecen en «Vía libre» y «Primera salida».
// Catorce piezas en dos familias de estilo:
//  · «Estación» (preparación y menús): bossa nova, jazz, vals, pop, lounge, rumba y pasodoble.
//  · «Red» (jornadas): orquestal de día, nocturnas y una bulería.
// Melodías, armonías y arreglos son composiciones originales de este proyecto.
import {SAMPLE_INDEX} from './assets/samples-index.js';

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
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
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
/** Un tono del acorde (quinta, tercera o séptima, por ese orden) dentro de [lo, hi]. */
function toneIn(c, lo, hi) {
  for (const i of [7, 4, 3, 10, 11, 9]) if (c.iv.includes(i)) { let n = c.root + i; while (n < lo) n += 12; while (n > hi) n -= 12; if (n >= lo) return n; }
  return null;
}
/** Escala para los adornos: frigio dominante sobre los acordes de séptima (el giro andaluz), eólica en menores y jónica en mayores. */
function scaleFor(c) {
  const dom = c.iv.includes(4) && c.iv.includes(10), minor = c.iv.includes(3);
  return (dom ? [0, 1, 4, 5, 7, 8, 10] : minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map(k => pcOf(c.root + k));
}

// ------------------------------------------------------------ sintetizadores
// Solo dos se usan a propósito, con mesura: un pad analógico (sierras desafinadas en estéreo, subarmónico y doble
// filtro con apertura lenta) por debajo de las cuerdas reales y un bajo analógico con filtro de 24 dB y saturación.
// El resto son sustitutos por si una muestra no se puede cargar.
let noiseBuf = null;
function noise(ctx) {
  if (noiseBuf && noiseBuf.sampleRate === ctx.sampleRate) return noiseBuf;
  noiseBuf = ctx.createBuffer(1, ctx.sampleRate * 1.5, ctx.sampleRate);
  const d = noiseBuf.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  return noiseBuf;
}
let clipCurve = null;
function softClip(ctx) {
  if (!clipCurve) { clipCurve = new Float32Array(1024); for (let i = 0; i < 1024; i++) { const x = i / 1023 * 2 - 1; clipCurve[i] = Math.tanh(x * 1.8) / Math.tanh(1.8); } }
  const s = ctx.createWaveShaper(); s.curve = clipCurve; s.oversample = '2x'; return s;
}
function vout(ctx, dest, pan = 0) {
  const g = ctx.createGain(); g.gain.value = 0;
  if (pan && ctx.createStereoPanner) { const p = ctx.createStereoPanner(); p.pan.value = pan; g.connect(p); p.connect(dest); } else g.connect(dest);
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
function perc(ctx, dest, t, v, type, f, q, decay, attack = .001) {
  const g = vout(ctx, dest), n = ctx.createBufferSource(), bf = ctx.createBiquadFilter();
  n.buffer = noise(ctx); n.playbackRate.value = .8 + Math.random() * .4; bf.type = type; bf.frequency.value = f; bf.Q.value = q;
  n.connect(bf); bf.connect(g); n.start(t, Math.random()); n.stop(t + decay * 6);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v, t + attack); g.gain.setTargetAtTime(0, t + attack, decay);
}
const SYNTH = {
  pad(ctx, dest, t, m, dur, v, o) {
    const f = hz(m), atk = o.attack ?? 1.4, rel = o.rel ?? 2.4, end = t + dur + rel * 1.6;
    const env = vout(ctx, dest), lp1 = ctx.createBiquadFilter(), lp2 = ctx.createBiquadFilter();
    lp1.type = lp2.type = 'lowpass'; lp1.Q.value = .7; lp2.Q.value = .5;
    const cut = (o.bright ? 2300 : 1250) * (.75 + v * .5);
    lp1.frequency.setValueAtTime(cut * .4, t); lp1.frequency.linearRampToValueAtTime(cut, t + atk * 1.3); lp1.frequency.setTargetAtTime(cut * .75, t + atk * 1.3, 2.5);
    lp2.frequency.value = cut * 1.8; lp1.connect(lp2); lp2.connect(env);
    [-.6, .6].forEach((p, k) => {
      let node = lp1;
      if (ctx.createStereoPanner) { node = ctx.createStereoPanner(); node.pan.value = p; node.connect(lp1); }
      [k ? 6 : -6, k ? -2 : 2].forEach(d => { const g = ctx.createGain(); g.gain.value = .4; g.connect(node); osc(ctx, 'sawtooth', f, t, end, g, d + (Math.random() - .5) * 3); });
    });
    const sg = ctx.createGain(); sg.gain.value = .22; sg.connect(lp1); osc(ctx, 'square', f / 2, t, end, sg);
    const lfo = ctx.createOscillator(), lg = ctx.createGain(); lfo.frequency.value = .13 + Math.random() * .12; lg.gain.value = cut * .1; lfo.connect(lg); lg.connect(lp1.frequency); lfo.start(t); lfo.stop(end);
    const peak = v * .05;
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(peak, t + atk); env.gain.setTargetAtTime(peak * .85, t + atk, 2); env.gain.setTargetAtTime(0, t + Math.max(atk, dur), rel / 3);
  },
  synthbass(ctx, dest, t, m, dur, v) {
    const f = hz(m), end = t + dur + .3, env = vout(ctx, dest), lp1 = ctx.createBiquadFilter(), lp2 = ctx.createBiquadFilter(), sh = softClip(ctx);
    lp1.type = lp2.type = 'lowpass'; lp1.Q.value = 1.6; lp2.Q.value = .6;
    const cut = 240 + v * 700;
    lp1.frequency.setValueAtTime(cut * 3.5, t); lp1.frequency.setTargetAtTime(cut, t, .08); lp2.frequency.value = cut * 2.2;
    lp1.connect(lp2); lp2.connect(sh); sh.connect(env);
    [-5, 5].forEach(d => { const g = ctx.createGain(); g.gain.value = .35; g.connect(lp1); osc(ctx, 'sawtooth', f, t, end, g, d); });
    const sq = ctx.createGain(); sq.gain.value = .4; sq.connect(lp1); osc(ctx, 'square', f / 2 >= 40 ? f / 2 : f, t, end, sq);
    env.gain.setValueAtTime(0, t); env.gain.linearRampToValueAtTime(v * .3, t + .006); env.gain.setTargetAtTime(v * .22, t + .01, .25); env.gain.setTargetAtTime(0, t + dur, .05);
  },
  // ---- sustitutos
  piano(ctx, dest, t, m, dur, v) {
    const f = hz(m), decay = Math.max(.6, 3.2 - (m - 48) * .045), end = t + Math.min(dur + .4, decay + .3), g = vout(ctx, dest, (m - 64) / 60);
    const lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1800 + v * 4500; lp.connect(g);
    [[1, 1], [2, .42], [3, .2], [4, .11]].forEach(([k, a]) => { const pg = ctx.createGain(); pg.gain.value = a; pg.connect(lp); osc(ctx, 'sine', f * k * (1 + k * .0004), t, end, pg); });
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .3, t + .006); g.gain.setTargetAtTime(v * .1, t + .006, decay / 5); g.gain.setTargetAtTime(0, t + dur, .12);
  },
  epiano(ctx, dest, t, m, dur, v) {
    const f = hz(m), end = t + dur + .9, g = vout(ctx, dest, (m - 62) / 50), car = ctx.createOscillator(), mod = ctx.createOscillator(), mg = ctx.createGain();
    car.frequency.value = f; mod.frequency.value = f; mg.gain.setValueAtTime(f * (1.4 + v * 2), t); mg.gain.setTargetAtTime(f * .25, t, .25);
    mod.connect(mg); mg.connect(car.frequency); car.connect(g); [car, mod].forEach(x => { x.start(t); x.stop(end); });
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .28, t + .004); g.gain.setTargetAtTime(v * .12, t + .01, .5); g.gain.setTargetAtTime(0, t + dur, .25);
  },
  strings(ctx, dest, t, m, dur, v, o) {
    const f = hz(m), end = t + dur + 1.5, g = vout(ctx, dest, ((m * 5) % 9 - 4) / 10), lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 2600; lp.connect(g);
    const vib = ctx.createOscillator(), vg = ctx.createGain(); vib.frequency.value = 5.2; vg.gain.value = 6; vib.connect(vg); vib.start(t); vib.stop(end);
    [-6, 5].forEach(dt => { const x = osc(ctx, 'sawtooth', f, t, end, lp, dt); vg.connect(x.detune); });
    adsr(g.gain, t, v * .08, o.attack ?? .35, .8, .9, dur, .9);
  },
  wind(ctx, dest, t, m, dur, v) {
    const f = hz(m), end = t + dur + .4, g = vout(ctx, dest), lp = ctx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 1900; lp.connect(g);
    osc(ctx, 'triangle', f, t, end, lp); const h = ctx.createGain(); h.gain.value = .25; h.connect(lp); osc(ctx, 'square', f, t, end, h);
    adsr(g.gain, t, v * .12, .05, .4, .85, dur, .12);
  },
  pluck(ctx, dest, t, m, dur, v) {
    const f = hz(m), end = t + Math.min(dur, .6) + .3, g = vout(ctx, dest, (m % 7 - 3) / 8), lp = ctx.createBiquadFilter();
    lp.type = 'lowpass'; lp.frequency.setValueAtTime(4200, t); lp.frequency.setTargetAtTime(700, t, .08); lp.connect(g);
    osc(ctx, 'triangle', f, t, end, lp); osc(ctx, 'sawtooth', f * 1.002, t, end, lp);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .15, t + .003); g.gain.setTargetAtTime(0, t + .01, .18);
  },
  bass(ctx, dest, t, m, dur, v) {
    const f = hz(m), end = t + dur + .3, g = vout(ctx, dest), lp = ctx.createBiquadFilter();
    lp.type = 'lowpass'; lp.frequency.setValueAtTime(900, t); lp.frequency.setTargetAtTime(300, t, .15); lp.connect(g);
    osc(ctx, 'sine', f, t, end, g); osc(ctx, 'triangle', f, t, end, lp);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(v * .4, t + .008); g.gain.setTargetAtTime(v * .2, t + .01, .3); g.gain.setTargetAtTime(0, t + dur, .06);
  },
  kick(ctx, dest, t, m, dur, v) {
    const g = vout(ctx, dest), o = ctx.createOscillator();
    o.frequency.setValueAtTime(130, t); o.frequency.exponentialRampToValueAtTime(42, t + .12); o.connect(g); o.start(t); o.stop(t + .5);
    g.gain.setValueAtTime(v * .6, t); g.gain.setTargetAtTime(0, t + .01, .09);
  },
  snare(ctx, dest, t, m, dur, v) { perc(ctx, dest, t, v * .4, 'bandpass', 2200, .7, .09); },
  hat(ctx, dest, t, m, dur, v) { perc(ctx, dest, t, v * .2, 'highpass', 7500, .7, .035); },
  click(ctx, dest, t, m, dur, v) { perc(ctx, dest, t, v * .3, 'bandpass', 1600, 2, .03); },
};
const FALLBACK = {
  vln: 'strings', vla: 'strings', vc: 'strings', cb: 'strings', svln: 'strings', vln_trem: 'strings', vc_trem: 'strings',
  vln_spic: 'pluck', vc_spic: 'pluck', vln_pizz: 'pluck', vc_pizz: 'pluck', harp: 'pluck', guitar: 'pluck',
  flute: 'wind', oboe: 'wind', clarinet: 'wind', bassoon: 'wind', horn: 'wind', trumpet: 'wind', trombone: 'wind', mtrumpet: 'wind', sax: 'wind',
  tuba: 'bass', upright: 'bass', ebass: 'bass', piano: 'piano', rhodes: 'epiano', vibes: 'epiano', timp: 'kick',
  kick: 'kick', bassdrum: 'kick', cajon: 'kick', snare: 'snare', msnare: 'snare', rimshot: 'snare', ghost: 'snare', cajonslap: 'snare', claps: 'snare',
  hat: 'hat', hatopen: 'hat', hatpedal: 'hat', ride: 'hat', ridebell: 'hat', shaker: 'hat', tamb: 'hat', triangle: 'hat',
  xstick: 'click', castanets: 'click', conga: 'click', congamute: 'click', quinto: 'click', tumba: 'click', bongo: 'click', darbuka: 'click', darbukatek: 'click', frame: 'click', tomh: 'click', toml: 'click',
};

// ------------------------------------------------------------ instrumentos muestreados
// Las muestras (assets/muestras-<grupo>.js: orquesta, teclas, percusion) rellenan globalThis.IBERIA_SAMPLES. En la
// versión autónoma ya vienen dentro de la página; en la versión web se piden la primera vez que una pieza las necesita.
// Cada instrumento se decodifica una vez, a la frecuencia de muestreo original, y se libera al cambiar de pieza.
//  fam: bus de mezcla · pan: posición en el escenario · lvl: nivel · sus: sostenido (encadena tramos y admite legato)
//  rel: apagado (s) · split: velocidad a partir de la que suena la capa forte · tone: filtro según la velocidad
//  spread: abre el panorama según la altura · curve: curva de velocidad
const INST = {
  vln: {fam: 'str', pan: -.4, lvl: .42, sus: 1, rel: .5, split: .64}, vla: {fam: 'str', pan: .12, lvl: .4, sus: 1, rel: .5, split: .64},
  vc: {fam: 'str', pan: .34, lvl: .44, sus: 1, rel: .5, split: .64}, cb: {fam: 'str', pan: .46, lvl: .62, sus: 1, rel: .45, split: .64},
  vln_spic: {fam: 'str', pan: -.34, lvl: .4, rel: .12}, vc_spic: {fam: 'str', pan: .3, lvl: .44, rel: .12},
  vln_pizz: {fam: 'str', pan: -.34, lvl: .44, rel: .3, tone: 9000}, vc_pizz: {fam: 'str', pan: .3, lvl: .5, rel: .3, tone: 6000},
  vln_trem: {fam: 'str', pan: -.32, lvl: .34, sus: 1, rel: .45}, vc_trem: {fam: 'str', pan: .3, lvl: .38, sus: 1, rel: .45},
  svln: {fam: 'solo', pan: -.1, lvl: .44, sus: 1, rel: .35, split: .58},
  harp: {fam: 'harp', pan: -.45, lvl: .44, rel: .9, spread: 1, tone: 12000},
  flute: {fam: 'ww', pan: -.2, lvl: .4, sus: 1, rel: .25, tone: 14000}, oboe: {fam: 'ww', pan: .1, lvl: .38, sus: 1, rel: .22, split: .62},
  clarinet: {fam: 'ww', pan: -.05, lvl: .4, sus: 1, rel: .22, split: .62}, bassoon: {fam: 'ww', pan: .2, lvl: .42, sus: 1, rel: .22, split: .62},
  horn: {fam: 'br', pan: -.28, lvl: .42, sus: 1, rel: .4, split: .64}, trumpet: {fam: 'br', pan: .15, lvl: .36, sus: 1, rel: .3, split: .64},
  trombone: {fam: 'br', pan: .3, lvl: .38, sus: 1, rel: .3, split: .64}, tuba: {fam: 'br', pan: .38, lvl: .6, sus: 1, rel: .25, split: .64},
  mtrumpet: {fam: 'solo', pan: .14, lvl: .38, sus: 1, rel: .25, tone: 12000}, sax: {fam: 'solo', pan: .12, lvl: .4, sus: 1, rel: .2, split: .6},
  timp: {fam: 'timp', pan: .04, lvl: .55, rel: 1.2, split: .62}, timproll: {fam: 'timp', pan: .04, lvl: .45, sus: 1, rel: .6, tone: 9000},
  piano: {fam: 'keys', pan: 0, lvl: .5, rel: .4, split: .56}, rhodes: {fam: 'keys', pan: -.06, lvl: .5, rel: .35, split: .6, spread: 1},
  vibes: {fam: 'keys', pan: .22, lvl: .44, rel: 1.4, split: .55, spread: 1}, guitar: {fam: 'gtr', pan: .16, lvl: .5, rel: .35, tone: 11000},
  upright: {fam: 'bass', pan: 0, lvl: .6, rel: .12, split: .62}, ebass: {fam: 'bass', pan: 0, lvl: .5, rel: .1, tone: 5000},
  kick: {fam: 'kit', lvl: .62}, snare: {fam: 'kit', pan: .05, lvl: .42}, ghost: {fam: 'kit', pan: .05, lvl: .3}, xstick: {fam: 'kit', pan: .05, lvl: .36}, rimshot: {fam: 'kit', pan: .05, lvl: .4},
  hat: {fam: 'kit', pan: .28, lvl: .25}, hatopen: {fam: 'kit', pan: .28, lvl: .2}, hatpedal: {fam: 'kit', pan: .25, lvl: .3}, ride: {fam: 'kit', pan: -.25, lvl: .4}, ridebell: {fam: 'kit', pan: -.25, lvl: .18},
  crash: {fam: 'kit', pan: .35, lvl: .22}, tomh: {fam: 'kit', pan: .15, lvl: .4}, toml: {fam: 'kit', pan: -.15, lvl: .42},
  shaker: {fam: 'perc', pan: -.35, lvl: .2}, tamb: {fam: 'perc', pan: .4, lvl: .2}, triangle: {fam: 'perc', pan: .45, lvl: .16},
  cajon: {fam: 'perc', pan: 0, lvl: .7}, cajonslap: {fam: 'perc', pan: 0, lvl: .5}, claps: {fam: 'perc', pan: -.15, lvl: .42}, castanets: {fam: 'perc', pan: .25, lvl: .3},
  conga: {fam: 'perc', pan: -.3, lvl: .35}, congamute: {fam: 'perc', pan: -.3, lvl: .3}, quinto: {fam: 'perc', pan: -.4, lvl: .3}, tumba: {fam: 'perc', pan: -.2, lvl: .35}, bongo: {fam: 'perc', pan: .3, lvl: .3},
  darbuka: {fam: 'perc', pan: .2, lvl: .35}, darbukatek: {fam: 'perc', pan: .2, lvl: .3}, frame: {fam: 'perc', pan: -.2, lvl: .35},
  bassdrum: {fam: 'band', pan: 0, lvl: .26}, msnare: {fam: 'band', pan: -.1, lvl: .35}, clash: {fam: 'band', pan: .25, lvl: .22}, swell: {fam: 'band', pan: -.2, lvl: .25},
  pad: {fam: 'syn', lvl: .3, sus: 1, rel: 2, curve: 1.2}, synthbass: {fam: 'bass', lvl: .8, rel: .08},
};
const MEL_GAIN = 1.9; // la melodía, siempre por delante del acompañamiento
const MEL_BOOST = {guitar: 1.8, vibes: 1.6, rhodes: 1.4, harp: 1.5, flute: 1.3, clarinet: 1.2, sax: 1.2, oboe: 1.1}; // instrumentos de caída rápida o timbre suave
const MIX_GAIN = 1.6; // ganancia de compensación antes de la cadena del máster
const bank = () => globalThis.IBERIA_SAMPLES || {};
const groups = new Map(), decoded = new Map(), decoders = new Map();
function loadGroup(g) {
  if (!groups.has(g)) groups.set(g, new Promise(res => {
    if (typeof document === 'undefined') return res(false);
    const s = document.createElement('script');
    s.src = (globalThis.IBERIA_SAMPLE_BASE ?? '') + `muestras-${g}.js`;
    s.onload = () => res(true); s.onerror = () => { groups.delete(g); res(false); };
    document.head.appendChild(s);
  }));
  return groups.get(g);
}
/** Decodificar a la frecuencia de la muestra evita remuestrearla y gastar más memoria; el reproductor la convierte al vuelo. */
function decoderFor(ctx, sr) {
  if (!sr || sr === ctx.sampleRate || typeof OfflineAudioContext === 'undefined') return ctx;
  if (!decoders.has(sr)) { try { decoders.set(sr, new OfflineAudioContext(1, 1, sr)); } catch { decoders.set(sr, ctx); } }
  return decoders.get(sr);
}
function b64buf(s) { const bin = atob(s), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u.buffer; }
function decode(ctx, ab) { return new Promise((res, rej) => { const p = ctx.decodeAudioData(ab, res, rej); if (p && p.then) p.then(res, rej); }); }
/** Inicio real del sonido (el MP3 añade un retardo), nivel eficaz para igualar capas y notas, y fin de la zona estable. */
function analyse(buf) {
  const d = buf.getChannelData(0), sr = buf.sampleRate, n = Math.min(d.length, Math.floor(sr * .5));
  let peak = 0; for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(d[i]));
  let a = 0; for (let i = 0; i < n; i++) if (Math.abs(d[i]) > peak * .02) { a = Math.max(0, i - 24); break; }
  const b = Math.min(d.length, a + Math.floor(sr * .4)); let e = 0; for (let i = a; i < b; i++) e += d[i] * d[i];
  const off = a / sr;
  return {buf, off, rms: Math.sqrt(e / Math.max(1, b - a)) || 1e-4, dur: buf.duration, full: off + (buf.duration - off) * .66, loop: off + Math.min(.6, (buf.duration - off) * .2)};
}
// Sintetizadores «muestreados»: cada nota se toca una vez, con todo su circuito, en un contexto fuera de línea y
// después se reproduce como una muestra más; así su coste en tiempo real es el de un instrumento muestreado.
const SYNTH_BANK = {pad: {notes: [43, 48, 53, 58, 63, 68, 73], len: 7, stable: 1.5, opt: {attack: 1.2, rel: .05}}, synthbass: {notes: [33, 38, 43, 48, 53], len: 1.4, stable: 0, opt: {}}};
async function renderSynth(name) {
  const spec = SYNTH_BANK[name], sr = 44100, out = [];
  for (const m of spec.notes) {
    const ctx = new OfflineAudioContext(2, Math.ceil(sr * spec.len), sr);
    SYNTH[name](ctx, ctx.destination, 0, m, spec.len, .8, spec.opt);
    const buf = await ctx.startRendering(), n = buf.length, f = Math.floor(n * .3);
    for (let ch = 0; ch < 2; ch++) { const d = buf.getChannelData(ch); for (let i = 0; i < f; i++) d[n - f + i] *= Math.cos(i / f * Math.PI / 2) ** 2; }
    const a = analyse(buf);
    if (spec.stable) {
      const d = buf.getChannelData(0), i0 = Math.floor(sr * spec.stable), i1 = Math.floor(sr * (spec.stable + 1)); let e = 0;
      for (let i = i0; i < i1; i++) e += d[i] * d[i];
      a.rms = Math.sqrt(e / (i1 - i0)); a.loop = spec.stable;
    }
    out.push(a);
  }
  return {kind: 'tonal', notes: spec.notes, layers: [out], rr: 0};
}
/** Carga (si hace falta) y decodifica los instrumentos que aparecen en `names`. */
export function loadInstruments(ctx, names) {
  if (!ctx?.decodeAudioData || typeof atob !== 'function') return Promise.resolve([]);
  const synths = typeof OfflineAudioContext === 'undefined' ? [] : [...new Set(names)].filter(n => SYNTH_BANK[n]).map(n => {
    if (!decoded.has(n)) { const entry = {value: null}; entry.promise = renderSynth(n).then(v => (entry.value = v)).catch(() => { decoded.delete(n); return null; }); decoded.set(n, entry); }
    return decoded.get(n).promise;
  });
  const want = [...new Set(names)].filter(n => SAMPLE_INDEX[n]);
  const missing = [...new Set(want.filter(n => !bank()[n]).map(n => SAMPLE_INDEX[n]))];
  return Promise.all(missing.map(loadGroup)).then(() => Promise.all([...synths, ...want.filter(n => bank()[n]).map(n => {
    if (!decoded.has(n)) {
      const spec = bank()[n], dec = decoderFor(ctx, spec.sr), entry = {value: null};
      const lists = spec.kind === 'tonal' ? spec.layers : [spec.data];
      entry.promise = Promise.all(lists.map(list => Promise.all(list.map(s => decode(dec, b64buf(s)).then(analyse)))))
        .then(layers => (entry.value = {kind: spec.kind, notes: spec.notes, tune: spec.tune, layers, rr: 0}))
        .catch(() => { decoded.delete(n); return null; });
      decoded.set(n, entry);
    }
    return decoded.get(n).promise;
  })]));
}
/** Libera los instrumentos ya decodificados que no estén en `keep`. */
export function releaseInstruments(keep) { for (const [n, e] of [...decoded]) if (e.value && !keep.has(n) && !SYNTH_BANK[n] && !n.startsWith('ui_')) decoded.delete(n); }
/** Instrumento ya decodificado (para los efectos de la interfaz) o null. */
export const instrument = name => decoded.get(name)?.value || null;
/** Pide al servidor, sin decodificarlos, los ficheros de muestras de estos instrumentos (versión web). */
export function prefetchInstruments(names) { return Promise.all([...new Set(names.filter(n => SAMPLE_INDEX[n] && !bank()[n]).map(n => SAMPLE_INDEX[n]))].map(loadGroup)); }
function hash(a, b) {
  let x = (Math.floor(a * 9973) ^ Math.imul(b | 0, 2654435761)) >>> 0;
  x = Math.imul(x ^ (x >>> 16), 2246822519) >>> 0; x = Math.imul(x ^ (x >>> 13), 3266489917) >>> 0;
  return ((x ^ (x >>> 16)) >>> 0) / 4294967296;
}
/** Un tramo de muestra con su envolvente: ataque, mantenimiento y apagado (o fundido de salida desde `fadeAt`). */
function segment(ctx, dest, buf, rate, t, from, peak, atk, off, rel, end, fadeAt = null) {
  const g = ctx.createGain(), src = ctx.createBufferSource();
  src.buffer = buf; src.playbackRate.value = rate; src.connect(g); g.connect(dest);
  g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(peak, t + atk);
  if (fadeAt !== null) { g.gain.setValueAtTime(peak, Math.max(t + atk, fadeAt)); g.gain.linearRampToValueAtTime(0, end); }
  else if (off !== null) g.gain.setTargetAtTime(0, Math.max(t + atk, off), Math.max(.01, rel / 3));
  src.start(t, from); src.stop(end + .05);
}
/** Expresión de la nota: crescendo, diminuendo o, en las notas largas sostenidas, un leve «messa di voce». */
function expression(p, t, dur, o, I) {
  if (o.cresc) { p.setValueAtTime(.3, t); p.linearRampToValueAtTime(1.15, t + dur); return; }
  if (o.dim) { p.setValueAtTime(1, t); p.linearRampToValueAtTime(.45, t + dur); return; }
  if (I.sus && dur > 1.4) { p.setValueAtTime(.86, t); p.linearRampToValueAtTime(1, t + dur * .45); p.linearRampToValueAtTime(.9, t + dur); return; }
  p.value = 1;
}
function sampled(ctx, mix, t, name, m, dur, v, o) {
  const inst = decoded.get(name)?.value;
  if (!inst) return false;
  const I = INST[name] || {};
  if (inst.kind === 'drum') { hit(ctx, mix, t, name, inst, v, o, I); return true; }
  const ns = inst.notes; let k = 0;
  for (let j = 1; j < ns.length; j++) if (Math.abs(ns[j] - m) < Math.abs(ns[k] - m)) k = j;
  const rate = 2 ** ((m - ns[k] - (inst.tune?.[k] || 0)) / 12), L = inst.layers.length;
  const s = inst.layers[L > 1 && v + (hash(t, m) - .5) * .14 >= (I.split ?? .6) ? 1 : 0][k];
  const peak = (I.lvl ?? .45) * Math.pow(v, I.curve ?? 1.5) * (.12 / s.rms) * (o.mel ? MEL_GAIN * (MEL_BOOST[name] ?? 1) : 1) * (o.g ?? 1);
  // destino: el sub-bus del instrumento (ya panoramizado) o, si la posición depende de la altura, un panorama propio
  let node;
  if ((I.spread || o.pan !== undefined) && ctx.createStereoPanner) {
    node = ctx.createStereoPanner(); node.pan.value = o.pan ?? clamp((I.pan ?? 0) + (m - 64) / 80, -.85, .85); node.connect(mix.bus(I.fam || 'keys'));
  } else node = mix.inst(name);
  const cut = o.lp || (I.tone ? 900 + v * v * I.tone : 0);
  if (cut && cut < 9000) { const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = cut; f.Q.value = .5; f.connect(node); node = f; }
  const off = t + dur, rel = o.rel ?? I.rel ?? .3;
  if (o.cresc || o.dim || o.trem || (I.sus && dur > 1.4)) {
    const ex = ctx.createGain(); ex.connect(node); node = ex;
    expression(ex.gain, t, dur, o, I);
    if (o.trem) { const l = ctx.createOscillator(), lg = ctx.createGain(); l.frequency.value = 4.8; lg.gain.value = o.trem; l.connect(lg); lg.connect(ex.gain); l.start(t); l.stop(off + rel * 3 + .1); }
  }
  if (!I.sus) {
    const natural = t + (s.dur - s.off) / rate;
    segment(ctx, node, s.buf, rate, t, s.off, peak, o.attack ?? I.atk ?? .003, off < natural ? off : null, rel, Math.min(natural, off + rel * 3));
    return true;
  }
  // sostenido: si la nota dura más que la muestra se encadenan tramos (sin el ataque) con fundido cruzado; en legato
  // la nota entra sin el golpe de arco o de lengua, como una nota ligada
  const leg = !!o.leg, start = s.off + (leg ? .07 : 0), atk = o.attack ?? (leg ? .07 : .03), X = .32;
  let t0 = t, from = start, first = true;
  for (let guard = 0; guard < 16; guard++) {
    const stable = t0 + (s.full - from) / rate, cut2 = stable - X;
    if (off + rel <= stable || cut2 >= off - .05 || (s.full - s.loop) / rate < X * 3) {
      segment(ctx, node, s.buf, rate, t0, from, peak, first ? atk : X, off, rel, Math.min(t0 + (s.dur - from) / rate, off + rel * 3.5));
      break;
    }
    segment(ctx, node, s.buf, rate, t0, from, peak, first ? atk : X, null, 0, cut2 + X, cut2);
    t0 = cut2; from = s.loop; first = false;
  }
  return true;
}
/** Golpe de percusión: alterna las tomas, varía un poco la afinación y apaga los golpes suaves. */
function hit(ctx, mix, t, name, inst, v, o, I) {
  const list = inst.layers[0], k = inst.rr = (inst.rr + 1) % list.length, s = list[k];
  const rate = (o.rate || 1) * (.985 + hash(t, k + 7) * .03);
  let node = mix.inst(name);
  if (o.lp || v < .4) { const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = o.lp || 2200 + v * 16000; f.connect(node); node = f; }
  const g = ctx.createGain(); g.connect(node);
  const src = ctx.createBufferSource(); src.buffer = s.buf; src.playbackRate.value = rate; src.connect(g);
  let end = t + (s.dur - s.off) / rate;
  g.gain.setValueAtTime((I.lvl ?? .4) * Math.pow(v, I.curve ?? 1.3) * (o.g ?? 1), t);
  if (o.choke) { g.gain.setTargetAtTime(0, t + o.choke, .03); end = Math.min(end, t + o.choke + .25); }
  src.start(t, s.off); src.stop(end + .02);
}

// ------------------------------------------------------------ mezcla
/** Respuesta de una sala de conciertos: primeras reflexiones distintas en cada canal y cola en tres bandas que se
 *  apagan a distinto ritmo (los agudos antes que los graves), con un breve crecimiento inicial de la densidad. */
export function hallIR(ctx, seconds = 2.9, rt = [2.5, 2.1, 1.0], pre = .024, taps = [11, 17, 23, 29, 37, 43, 53, 61, 71, 83]) {
  const sr = ctx.sampleRate, len = Math.floor(sr * seconds), buf = ctx.createBuffer(2, len, sr), p0 = Math.floor(sr * pre);
  const a1 = 1 - Math.exp(-2 * Math.PI * 450 / sr), a2 = 1 - Math.exp(-2 * Math.PI * 3800 / sr);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch); let l1 = 0, l2 = 0, seed = ch ? 1234567 : 7654321;
    const rnd = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 4294967296) * 2 - 1;
    for (let i = p0; i < len; i++) {
      const tt = (i - p0) / sr, n = rnd(); l1 += a1 * (n - l1); l2 += a2 * (n - l2);
      d[i] = Math.min(1, tt / .07) * (l1 * 1.8 * Math.exp(-6.9 * tt / rt[0]) + (l2 - l1) * Math.exp(-6.9 * tt / rt[1]) + (n - l2) * .45 * Math.exp(-6.9 * tt / rt[2]));
    }
    taps.forEach((ms, k) => { const i = p0 + Math.floor(sr * (ms + (ch ? 2.3 : 0) * (k % 3)) / 1000); if (i < len) d[i] += (k % 2 ? -1 : 1) * .6 * Math.exp(-k * .25); });
  }
  return buf;
}
// Buses por familia: ecualización [tipo, frecuencia, ganancia, Q] y envíos a la sala grande, a la pequeña y al eco.
const FAM = {
  str: {hall: .5, eq: [['highpass', 35], ['peaking', 2800, -2, 1], ['highshelf', 9000, -1.5]]},
  solo: {hall: .34, eq: [['peaking', 3200, -1, 1]]},
  ww: {hall: .42, eq: [['highshelf', 8000, -1]]},
  br: {hall: .5, eq: [['peaking', 2400, -2, .9], ['lowshelf', 200, -1]]},
  timp: {hall: .62, eq: [['highpass', 30]]},
  harp: {hall: .45},
  keys: {hall: .28, room: .08},
  gtr: {hall: .22, room: .12, delay: .1},
  bass: {hall: .05, eq: [['highpass', 30], ['peaking', 220, -1.5, 1]]},
  kit: {room: .3, hall: .06},
  perc: {room: .26, hall: .12},
  band: {room: .1, hall: .4, eq: [['highpass', 55]]},
  syn: {hall: .4, delay: .14, chorus: true},
};
function chorus(ctx, input, stops) {
  const out = ctx.createGain(), dry = ctx.createGain(); dry.gain.value = .7; input.connect(dry); dry.connect(out);
  [[.011, .6, -1], [.014, .45, 1]].forEach(([base, rate, side]) => {
    const d = ctx.createDelay(.05), l = ctx.createOscillator(), lg = ctx.createGain(), g = ctx.createGain();
    d.delayTime.value = base; l.frequency.value = rate; lg.gain.value = .0025; l.connect(lg); lg.connect(d.delayTime); l.start(); stops.push(l);
    g.gain.value = .45; input.connect(d); d.connect(g);
    if (ctx.createStereoPanner) { const p = ctx.createStereoPanner(); p.pan.value = side * .7; g.connect(p); p.connect(out); } else g.connect(out);
  });
  return out;
}
/** Mezcla de una pieza: buses por familia (se crean al primer uso), sala de conciertos, sala pequeña y eco a corchea con puntillo. */
export function makeMix(ctx, dest, bpm = 100) {
  const hall = ctx.createConvolver(), hallIn = ctx.createGain(), hp = ctx.createBiquadFilter(), lp = ctx.createBiquadFilter(), hallOut = ctx.createGain();
  hall.buffer = hallIR(ctx); hp.type = 'highpass'; hp.frequency.value = 220; lp.type = 'lowpass'; lp.frequency.value = 7500;
  hallIn.connect(hp); hp.connect(lp); lp.connect(hall); hall.connect(hallOut); hallOut.gain.value = .9; hallOut.connect(dest);
  const room = ctx.createConvolver(), roomIn = ctx.createGain(), roomOut = ctx.createGain();
  room.buffer = hallIR(ctx, 1.1, [.8, .65, .35], .008, [5, 7, 11, 13, 17, 19, 23, 29]); roomIn.connect(room); room.connect(roomOut); roomOut.gain.value = .7; roomOut.connect(dest);
  const del = ctx.createDelay(2), delIn = ctx.createGain(), fb = ctx.createGain(), dlp = ctx.createBiquadFilter(), delOut = ctx.createGain();
  del.delayTime.value = Math.min(1.5, .75 * 60 / bpm); dlp.type = 'lowpass'; dlp.frequency.value = 3200; fb.gain.value = .28; delOut.gain.value = .4;
  delIn.connect(del); del.connect(dlp); dlp.connect(fb); fb.connect(del); dlp.connect(delOut); delOut.connect(dest);
  const sends = {hall: hallIn, room: roomIn, delay: delIn}, buses = {}, insts = {}, stops = [];
  const mix = {
    inst(name) {
      if (insts[name]) return insts[name];
      const I = INST[name] || {}, g = ctx.createGain();
      if (I.pan && ctx.createStereoPanner) { const p = ctx.createStereoPanner(); p.pan.value = I.pan; g.connect(p); p.connect(mix.bus(I.fam || 'keys')); } else g.connect(mix.bus(I.fam || 'keys'));
      return (insts[name] = g);
    },
    bus(name) {
      if (buses[name]) return buses[name];
      const spec = FAM[name] || FAM.keys, input = ctx.createGain();
      let node = input;
      for (const [type, f, gain = 0, q = .8] of spec.eq || []) {
        const b = ctx.createBiquadFilter(); b.type = type; b.frequency.value = f;
        if (type !== 'highpass' && type !== 'lowpass') b.gain.value = gain;
        if (type === 'peaking') b.Q.value = q;
        node.connect(b); node = b;
      }
      if (spec.chorus) node = chorus(ctx, node, stops);
      node.connect(dest);
      for (const k of ['hall', 'room', 'delay']) if (spec[k]) { const s = ctx.createGain(); s.gain.value = spec[k]; node.connect(s); s.connect(sends[k]); }
      return (buses[name] = input);
    },
    dispose() { for (const o of stops) try { o.stop(); } catch {} },
  };
  return mix;
}
/** Máster: filtro de subgraves, un punto de aire en los agudos, compresión suave de «pegamento» y limitador. */
export function masterChain(ctx, dest) {
  const hp = ctx.createBiquadFilter(), glue = ctx.createDynamicsCompressor(), lim = ctx.createDynamicsCompressor();
  hp.type = 'highpass'; hp.frequency.value = 28; hp.Q.value = .6;
  const air = ctx.createBiquadFilter(); air.type = 'highshelf'; air.frequency.value = 8000; air.gain.value = 1.5;
  glue.threshold.value = -20; glue.knee.value = 10; glue.ratio.value = 2.2; glue.attack.value = .03; glue.release.value = .3;
  lim.threshold.value = -3; lim.knee.value = 0; lim.ratio.value = 20; lim.attack.value = .002; lim.release.value = .12;
  hp.connect(air); air.connect(glue); glue.connect(lim); lim.connect(dest);
  return hp;
}

// ------------------------------------------------------------ arreglos: piezas de construcción
// Cada estilo recibe un compás (x: acordes, sección, intensidad lv de 0 a 3, estado, aleatorio…) y añade eventos con
// add(instrumento, pulso, midi, pulsos, velocidad, opciones). El estado `st` guarda la última voz de cada parte para
// encadenar los acordes con conducción de voces. `x.top` es la nota más aguda libre por debajo de la melodía.
const DRUMS = new Set(['kick', 'snare', 'ghost', 'xstick', 'rimshot', 'hat', 'hatopen', 'hatpedal', 'ride', 'ridebell', 'crash', 'tomh', 'toml', 'shaker', 'tamb', 'triangle',
  'cajon', 'cajonslap', 'claps', 'castanets', 'conga', 'congamute', 'quinto', 'tumba', 'bongo', 'darbuka', 'darbukatek', 'frame', 'bassdrum', 'msnare', 'clash', 'swell']);
export const isDrum = n => DRUMS.has(n);
// registro cómodo de cada instrumento (para doblar la melodía) y de los contracantos
const RANGE = {vln: [55, 93], vla: [48, 79], vc: [36, 72], cb: [28, 55], svln: [55, 96], flute: [60, 96], oboe: [58, 89], clarinet: [50, 89], bassoon: [36, 72], horn: [41, 63],
  trumpet: [55, 84], trombone: [40, 65], tuba: [28, 53], mtrumpet: [58, 81], sax: [49, 80], piano: [36, 96], rhodes: [40, 86], vibes: [53, 89], guitar: [40, 84], harp: [36, 89]};
const COUNTER = {vc: [50, 64], horn: [50, 63], clarinet: [58, 72], bassoon: [43, 57], trombone: [46, 62], sax: [56, 70], vla: [55, 67], flute: [74, 88], oboe: [64, 77]};
const BASS = new Set(['upright', 'ebass', 'synthbass', 'cb', 'tuba']);
const SUS_LEAD = new Set(['vln', 'vla', 'vc', 'svln', 'flute', 'oboe', 'clarinet', 'bassoon', 'horn', 'trumpet', 'trombone', 'mtrumpet', 'sax']);
const at = (chords, p) => chords.reduce((best, c) => (c.start <= p + 1e-6 ? c : best), chords[0]);
const tn = c => { let n = c.root; while (n < 38) n += 12; return n; }; // timbal: fundamental entre Re2 y Do#3
function comp(x, inst, beats, low, high, vel, dur, opt = {}) {
  const {chords, add, st} = x;
  for (const p of beats) {
    const c = opt.anticipate && p >= x.M - .5 && x.next ? {c: x.next} : at(chords, p), v = st[inst] = led(c.c, low, high, st[inst]);
    v.forEach((n, k) => add(inst, p + (opt.strum ? (opt.up ? v.length - 1 - k : k) * opt.strum : 0), n, typeof dur === 'function' ? dur(p) : dur, vel * (k === v.length - 1 ? 1.08 : 1), opt));
  }
}
function padLong(x, inst, low, high, vel, opt = {}) { for (const c of x.chords) { const v = x.st[inst] = led(c.c, low, high, x.st[inst], false); v.forEach(n => x.add(inst, c.start, n, c.len, vel, opt)); } }
function arp(x, inst, c, start, len, step, low, vel, up = true, opt = {}) {
  const t = led(c.c, low, low + 14, null, false), seq = up ? [...t, ...t.map(n => n + 12)] : [...t.map(n => n + 12), ...t].reverse();
  for (let p = 0, k = 0; p < len - 1e-6; p += step, k++) x.add(inst, start + p, seq[k % seq.length], step * 2.2, vel * (k % 2 ? .85 : 1), opt);
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
/** Piano con pedal: arpegio abierto (fundamental, quinta y el acorde en la octava siguiente) que sube y baja. */
function pianoFlow(x, c, vel) {
  const r = bassNote(c.c, 36), up = led(c.c, r + 12, Math.min(r + 26, x.top), null, false), f = toneIn(c.c, r + 5, r + 11) ?? r + 7;
  const seq = [r, f, ...up, ...up.slice(1, -1).reverse()];
  for (let p = 0, k = 0; p < c.len - 1e-6; p += .5, k++) x.add('piano', c.start + p, seq[k % seq.length], c.len - p + .05, vel * (k === 0 ? 1.12 : k % 2 ? .82 : .92));
}
/** Cuerda: violonchelos (y contrabajos) en el bajo; violas y violines repartidos en el acorde, bajo la melodía. */
function strings(x, o = {}) {
  const {chords, add, st, lv} = x, top = Math.min(o.top ?? x.top, 83), vel = o.vel ?? .4, trem = o.art === 'trem';
  for (const c of chords) {
    const len = (o.len ?? c.len) + .06;
    if (o.upper !== false) {
      const v = st.str = led(c.c, top - 13, top, st.str, false);
      v.forEach((n, k) => add(trem ? 'vln_trem' : k === 0 && n < 70 ? 'vla' : 'vln', c.start, n, len, vel * (k === v.length - 1 ? 1.05 : .95)));
    }
    if (o.low !== false) {
      const b = bassNote(c.c, 40);
      add(trem ? 'vc_trem' : 'vc', c.start, b, len, vel);
      if ((o.cb ?? lv >= 2) && !trem) add('cb', c.start, b - 12, len, vel * .9);
      if (o.inner ?? lv >= 2.5) { const f = toneIn(c.c, b + 5, b + 12); if (f !== null) add('vc', c.start, f, len, vel * .75); }
    }
  }
}
/** Spiccato: corcheas (o el paso dado) con acentos; violines en dos notas del acorde y violonchelos en el bajo. */
function pulse(x, o = {}) {
  const {chords, add, st, M} = x, step = o.step ?? .5, accent = o.accent || (p => p % 2 === 0), vel = o.vel ?? .45;
  for (let p = 0; p < M - 1e-6; p += step) {
    const c = at(chords, p).c, a = accent(p) ? 1 : .68;
    if (o.upper !== false) (st.spic = led(c, 62, Math.min(x.top, 79), st.spic, false)).slice(-2).forEach(n => add('vln_spic', p, n, step * .8, vel * a));
    add('vc_spic', p, bassNote(c, 36) + (o.up ? 12 : 0), step * .8, vel * a * 1.05);
  }
}
function horns(x, o = {}) {
  for (const c of x.chords) (x.st.hn = led(c.c, 49, 63, x.st.hn, true)).slice(0, o.n ?? 3).forEach(n => x.add('horn', c.start, n, c.len + .06, o.vel ?? .36, {cresc: o.cresc}));
}
/** Arpa: arpegio rápido que sube dos octavas y media y llega al tiempo `beat + len`. */
function harpSweep(add, c, beat, len, lo, vel) {
  const t = led(c, lo, lo + 12, null, false), seq = [...t, ...t.map(n => n + 12), ...t.map(n => n + 24)].filter(n => n <= 89), step = len / seq.length;
  seq.forEach((n, k) => add('harp', beat + k * step, n, 1.6, vel * (.7 + .3 * k / seq.length)));
}
/** Redobles y remates de percusión en el último compás de la sección. */
function fill(x, kind) {
  const {add, M} = x, s = M - 1;
  if (kind === 'snare') [0, .25, .5, .75].forEach((d, k) => add('snare', s + d, 0, .1, .3 + k * .1));
  if (kind === 'toms') [[0, 'tomh'], [.25, 'tomh'], [.5, 'toml'], [.75, 'toml']].forEach(([d, n], k) => add(n, s + d, 0, .1, .45 + k * .08));
  if (kind === 'ghost') [0, .33, .67].forEach((d, k) => add('ghost', s + d, 0, .1, .3 + k * .1));
  if (kind === 'conga') [0, .25, .5, .75].forEach((d, k) => add(k % 2 ? 'conga' : 'quinto', s + d, 0, .1, .4 + k * .08));
  if (kind === 'cajon') [0, .25, .5, .75].forEach((d, k) => add('cajonslap', s + d, 0, .1, .3 + k * .1));
  if (kind === 'msnare') for (let d = 0; d < 1 - 1e-6; d += .125) add('msnare', s + d, 0, .1, .22 + d * .45);
}
/** «Falseta»: respuesta breve de guitarra que baja por la escala del acorde y acaba en una nota del acorde. */
function falseta(add, c, beat, len, from, vel) {
  while (from > 79) from -= 12; while (from < 60) from += 12;
  const pcs = scaleFor(c), ct = c.iv.map(i => pcOf(c.root + i)), steps = Math.max(3, Math.min(7, Math.round(len / .5))), out = [];
  let n = from + 2;
  for (let k = 0; k < steps; k++) { do n--; while (!pcs.includes(pcOf(n))); out.push(n); }
  while (!ct.includes(pcOf(out.at(-1)))) out[out.length - 1]--;
  out.forEach((m, k) => add('guitar', beat + k * .5 + (k === 1 ? .04 : 0), m, k === out.length - 1 ? 1.2 : .55, vel * (k === 0 ? 1.1 : 1)));
}
/** Rasgueado: un rasgueo de adorno muy rápido justo antes del acorde (en el pulso `p`). */
function rasgueado(add, c, st, vel, p = 0) {
  const v = st.rasg = led(c, 50, 71, st.rasg, false).concat([bassNote({...c, bass: c.root}, 40)]).sort((a, b) => a - b);
  v.forEach((n, k) => { add('guitar', Math.max(0, p - .14) + (v.length - 1 - k) * .012, n, .2, vel * .45); add('guitar', p + k * .028, n, 1.2, vel); });
}
/** Respuesta en los huecos de la melodía: falseta, motivo breve de viento o arpegio. */
function answer(x, c, beat, len, from, vel, lead) {
  const {add, cast, sp, st} = x;
  if (sp.falseta && lead !== 'guitar') return falseta(add, c, beat, len, from, vel);
  const inst = sp.falseta ? 'svln' : cast.fill === lead ? (lead === 'harp' ? 'piano' : 'harp') : cast.fill;
  if (SUS_LEAD.has(inst)) {
    const [lo, hi] = RANGE[inst], t = led(c, Math.max(lo, from - 9), Math.min(hi, from + 3), null, false).reverse().slice(0, 3);
    t.forEach((n, k) => add(inst, beat + k * .5, n, k === t.length - 1 ? Math.max(.5, len - k * .5) : .5, vel, {leg: k > 0}));
    return;
  }
  arp({add, st}, inst, {c}, beat, len, .5, 62, vel, false);
}
/** Contracanto con notas guía (terceras y séptimas), notas de paso hacia el acorde siguiente y sin pisar la melodía. */
function counterLine(add, spans, inst, notes, base) {
  const [lo, hi] = COUNTER[inst] || [50, 64], line = [];
  const melAt = b => { let m = null; for (const n of notes) if (n.midi !== null && base + n.beat <= b + 1e-6 && b < base + n.beat + n.dur - 1e-6) m = n.midi; return m; };
  let prev = null;
  for (const s of spans) {
    const pcs = [s.c.iv[1], s.c.iv.length > 3 ? s.c.iv[3] : s.c.iv[2]].map(i => pcOf(s.c.root + i));
    let best = null;
    for (let n = lo; n <= hi; n++) if (pcs.includes(pcOf(n))) { const d = prev === null ? Math.abs(n - (lo + hi) / 2) : Math.abs(n - prev); if (!best || d < best.d) best = {n, d}; }
    if (best) prev = best.n;
    if (prev !== null) line.push({beat: s.start, len: s.end - s.start, m: prev, c: s.c});
  }
  line.forEach((g, k) => {
    const nxt = line[k + 1], mm = melAt(g.beat);
    let len = g.len;
    if (nxt && g.len >= 2 && Math.abs(nxt.m - g.m) >= 2) {
      const sc = scaleFor(g.c), dir = Math.sign(nxt.m - g.m); let p = g.m + dir;
      while (!sc.includes(pcOf(p))) p += dir;
      if (p !== nxt.m) { add(inst, g.beat + g.len - 1, p, .95, .34, {leg: true}); len = g.len - 1; }
    }
    if (mm !== null && Math.abs(mm - g.m) <= 2) return;
    add(inst, g.beat, g.m, len - .04, .36, {leg: k > 0});
  });
}

// ------------------------------------------------------------ estilos
const CAST = {
  bossa: {bass: 'upright', counter: 'vc', harm: 'clarinet', fill: 'rhodes', roll: 'guitar'},
  swing: {bass: 'upright', counter: 'trombone', harm: 'sax', fill: 'vibes', roll: 'piano'},
  waltz: {bass: 'cb', counter: 'vc', harm: 'clarinet', fill: 'harp', roll: 'harp', orch: 1},
  pop: {bass: 'ebass', counter: 'vc', harm: 'clarinet', fill: 'piano', roll: 'piano'},
  rumba: {bass: 'ebass', counter: 'vc', harm: 'guitar', fill: 'guitar', roll: 'guitar'},
  ambient: {bass: 'cb', counter: 'horn', harm: 'clarinet', fill: 'harp', roll: 'harp', orch: 1},
  drive: {bass: 'cb', counter: 'horn', harm: 'vla', fill: 'harp', roll: 'harp', orch: 1},
  night: {bass: 'upright', counter: 'vc', harm: 'clarinet', fill: 'vibes', roll: 'rhodes'},
  lounge: {bass: 'upright', counter: 'vc', harm: 'flute', fill: 'vibes', roll: 'rhodes'},
  buleria: {bass: 'cb', counter: 'vc', harm: 'vla', fill: 'guitar', roll: 'guitar', orch: 1},
  pasodoble: {bass: 'tuba', counter: 'trombone', harm: 'clarinet', fill: 'trumpet', roll: 'harp', orch: 1},
};
const STYLES = {
  // guitarra con el pulgar en 1 y 3 y acordes sincopados; contrabajo, aro cruzado con la clave de bossa; Rhodes y
  // cuerdas suaves a lo Ogerman en las secciones intensas
  bossa(x) {
    const {i, add, chords, lv, cast} = x, alt = i % 2;
    comp(x, 'guitar', alt ? [.5, 2, 3.5] : [0, 1.5, 3], 52, 67, lv < 1 ? .34 : .38, .6, {strum: .012, anticipate: true});
    add('guitar', 0, bassNote(chords[0].c, 40), 1.4, .24); add('guitar', 2, fifth(at(chords, 2).c, 40), 1.4, .2);
    if (lv >= 1) {
      bassLine(x, cast.bass, [[0, 'r', 1.4, .75], [1.5, '5', .45, .5], [2, 'r', 1.4, .7], [3.5, 'a', .45, .48]]);
      (alt ? [1, 2.5] : [0, 1.5, 3]).forEach(p => add('xstick', p, 0, .1, .46));
      [[0, .45], [1.5, .28], [2, .4], [3.5, .28]].forEach(([p, v]) => add('kick', p, 0, .1, v));
      [1, 3].forEach(p => add('hatpedal', p, 0, .1, .28));
      for (let p = 0; p < 4; p += .5) if (lv >= 2) add('hat', p, 0, .1, p % 1 ? .28 : .18); else add('shaker', p, 0, .1, p % 1 ? .36 : .24);
      if (x.last && x.rise) fill(x, 'ghost');
    }
    if (lv >= 2 && lv < 2.5) padLong(x, 'rhodes', 53, Math.min(67, x.top), .22);
    if (lv >= 2.5) strings(x, {vel: .28, cb: false});
  },
  // orquestal: piano con pedal, cuerdas que crecen con la forma, arpa en las B, trompas y timbales en los clímax
  ambient(x) {
    const {chords, add, lv, cast, sec} = x;
    for (const c of chords) pianoFlow(x, c, lv >= 2.5 ? .22 : .3);
    if (lv >= 1) strings(x, {vel: .22 + lv * .07});
    if (lv >= 1 && cast.synth) padLong(x, 'pad', 48, 62, .3, {attack: 1.6});
    if (lv >= 2 && sec.key === 'B') for (const c of chords) arp(x, 'harp', c, c.start + .5, Math.min(c.len - .5, 2), .25, 57, .22, true);
    if (lv >= 2.5) horns(x, {vel: .28 + (lv - 2.5) * .16});
    if (lv >= 3 && x.first) add('timp', 0, tn(chords[0].c), 2, .5);
  },
  // pop orquestal: piano rítmico, bajo eléctrico, batería con notas fantasma, guitarra en las B y cuerdas y trompas al final
  pop(x) {
    const {add, lv, cast, chords, rand} = x;
    comp(x, 'piano', [0, 1, 1.5, 2.5, 3], 55, Math.min(72, x.top), lv < 1 ? .3 : .34, .45);
    if (lv < 1) for (const c of chords) { add('piano', c.start, bassNote(c.c, 36), c.len, .32); add('piano', c.start, bassNote(c.c, 36) + 12, c.len, .26); }
    if (lv >= 1) {
      bassLine(x, cast.bass, [[0, 'r', .9, .75], [1.5, 'r', .45, .55], [2, '5', .9, .65], [3, '8', .45, .55], [3.5, 'a', .45, .5]]);
      add('kick', 0, 0, .1, .62); add('kick', 2.5, 0, .1, .45); if (lv >= 2) add('kick', 1.75, 0, .1, .3);
      [1, 3].forEach(p => add('snare', p, 0, .1, .5)); add('ghost', 1.75, 0, .1, .18); if (rand() < .5) add('ghost', 3.75, 0, .1, .25);
      for (let p = 0; p < 4; p += .5) add(lv >= 2.5 ? 'ride' : p === 3.5 && x.i % 4 === 3 ? 'hatopen' : 'hat', p, 0, .1, p % 1 ? .4 : .28);
      if (x.first && lv >= 2) add('crash', 0, 0, 1, .4);
      if (x.last && x.rise) fill(x, 'toms');
    }
    if (lv >= 2) { comp(x, 'guitar', [0, 1.5, 2, 3, 3.5], 52, 69, .28, .35, {strum: .025}); strings(x, {vel: .3, cb: false}); }
    if (lv >= 2.5) horns(x, {vel: .3});
    if (lv >= 3) pulse(x, {vel: .3, upper: false});
  },
  // orquestal rítmica: ostinato de guitarra con eco, spiccato 3+3+2, bajo (analógico en «Vía libre») y percusión
  drive(x) {
    const {chords, add, lv, cast} = x, cajon = cast.kit === 'cajon';
    for (const c of chords) {
      const r = bassNote(c.c, 48) + 12, f = r + 7, t3 = voicing(c.c, r, false)[0] || r + 4, seq = [r, f, r + 12, f, t3, f, r + 12, f];
      for (let p = 0; p < c.len - 1e-6; p += .5) { const k = Math.round(p * 2) % 8; add('guitar', c.start + p, seq[k], .6, k % 2 ? .22 : .28); }
    }
    if (lv >= 1) pulse(x, {vel: .28 + lv * .06, accent: p => p === 0 || p === 1.5 || p === 3, upper: lv >= 2});
    if (lv >= 1 && cast.bass === 'synthbass') for (const c of chords) for (let p = 0; p < c.len - 1e-6; p += .5) add('synthbass', c.start + p, bassNote(c.c, 36) + (lv >= 2.5 && p % 1 ? 12 : 0), .45, p % 1 ? .5 : .62);
    if (lv >= 1 && cast.bass !== 'synthbass') for (const c of chords) add('cb', c.start, bassNote(c.c, 28), c.len + .05, .4);
    if (lv >= 2) strings(x, {vel: .24 + lv * .05, cb: false});
    if (lv >= 2 && cast.synth) padLong(x, 'pad', 52, 66, .26, {bright: true, attack: .8});
    if (lv >= 2.5) horns(x, {vel: .38});
    if (lv >= 1 && cajon) {
      [[0, .6], [1.75, .32], [2.5, .5]].forEach(([p, v]) => add('cajon', p, 0, .1, v)); [[1, .5], [3, .5], [3.75, .28]].forEach(([p, v]) => add('cajonslap', p, 0, .1, v));
      if (lv >= 2) [0, 2].forEach(p => add('darbuka', p, 0, .1, .3));
      if (lv >= 2.5) for (let p = .25; p < 4; p += .5) add('darbukatek', p, 0, .1, .2);
      if (x.last && x.rise) fill(x, 'cajon');
    } else if (lv >= 1) {
      [0, 2].forEach(p => add('kick', p, 0, .1, .6)); if (lv >= 2) add('kick', 1.5, 0, .1, .4); if (lv >= 2.5) add('kick', 3.5, 0, .1, .35);
      [1, 3].forEach(p => add(lv >= 2 ? 'snare' : 'xstick', p, 0, .1, lv >= 2 ? .46 : .38));
      for (let p = 0; p < 4; p += .25) add('hat', p, 0, .1, p % 1 === .5 ? .32 : p % .5 ? .13 : .22);
      if (lv >= 2.5) [[2.5, 'tomh'], [3.25, 'toml']].forEach(([p, n]) => add(n, p, 0, .1, .32));
      if (x.first && lv >= 2) add('crash', 0, 0, 1, .36);
      if (x.last && x.rise) fill(x, 'toms');
    }
    if (lv >= 3) add('timp', 0, tn(chords[0].c), 1.5, .5);
  },
  // jazz: piano con voces sin fundamental, contrabajo a dos y luego caminando, ride; en las secciones intensas,
  // trombón, saxo y trompeta con sordina de fondo
  swing(x) {
    const {chords, add, lv, next, rand, st, cast} = x, push = rand() < .3 && !x.last;
    comp(x, 'piano', push ? [0, 1.5] : [0, 1.5, 2.5], 50, Math.min(68, x.top), .32, p => (p ? .35 : .6));
    if (push) (st.piano = led(next, 50, 68, st.piano)).forEach(n => add('piano', 3.5, n, .5, .34));
    if (lv >= 1 && lv < 1.5) chords.forEach(c => { add(cast.bass, c.start, bassNote(c.c, 34), Math.min(2, c.len) * .95, .75); if (c.len >= 4) add(cast.bass, c.start + 2, fifth(c.c, 34), 1.9, .62); });
    if (lv >= 1.5) {
      const beats = []; for (const c of chords) for (let b = 0; b < c.len; b++) beats.push({c: c.c, b, last: b === c.len - 1});
      beats.forEach((y, k) => {
        const nx = k + 1 < beats.length ? beats[k + 1].c : next || y.c, cur = bassNote(y.c, 34);
        add(cast.bass, k, y.b === 0 ? cur : y.last ? approach(bassNote(nx, 34), cur) : y.b === 1 ? third(y.c, 34) : fifth(y.c, 34), .9, k % 2 ? .66 : .76);
        if (rand() < .1 && !y.last) add(cast.bass, k + .5, cur, .2, .3);
      });
    }
    if (lv >= 1) {
      [0, 1, 1.5, 2, 3, 3.5].forEach(p => add('ride', p, 0, .4, p % 1 ? .24 : p % 2 ? .48 : .36));
      [1, 3].forEach(p => add('hatpedal', p, 0, .05, .4));
      if (lv < 2) add('xstick', 3, 0, .1, .28);
      else { if (rand() < .4) add('ghost', rand() < .5 ? 2.5 : 1.5, 0, .1, .24); [0, 1, 2, 3].forEach(p => add('kick', p, 0, .1, .12)); }
      if (x.first && lv >= 2.5) add('crash', 0, 0, 1, .28);
      if (x.last && x.rise) fill(x, 'ghost');
    }
    if (lv >= 2 && lv < 2.5) for (const c of chords) (st.vib = led(c.c, 60, Math.min(74, x.top), st.vib)).forEach(n => add('vibes', c.start, n, c.len, .18));
    if (lv >= 2.5) for (const c of chords) { const v = st.bk = led(c.c, 55, 70, st.bk, true); ['trombone', 'sax', 'mtrumpet'].forEach((ins, k) => v[k] !== undefined && add(ins, c.start, v[k], c.len * .95, .28, {cresc: c.len >= 4})); }
  },
  // nocturna: Rhodes con trémolo, contrabajo, aro cruzado y charles; cuerdas en trémolo cuando crece la tensión
  night(x) {
    const {chords, add, lv, st, cast, next} = x;
    for (const c of chords) (st.rh = led(c.c, 52, Math.min(68, x.top), st.rh)).forEach(n => add('rhodes', c.start, n, c.len * .97, .32, {trem: .16}));
    if (lv >= 1) chords.forEach((c, ci) => {
      add(cast.bass, c.start, bassNote(c.c, 33), Math.min(c.len, 2) * .95, .62);
      if (c.len >= 4) { add(cast.bass, c.start + 2.5, fifth(c.c, 33), .9, .45); add(cast.bass, c.start + 3.5, approach(bassNote(chords[ci + 1]?.c || next, 33), bassNote(c.c, 33)), .45, .4); }
    });
    if (lv >= 1) {
      [1, 3].forEach(p => add('xstick', p, 0, .1, .36)); add('kick', 0, 0, .1, .34); add('kick', 2.5, 0, .1, .24);
      for (let p = 0; p < 4; p += .5) add(lv >= 2.5 ? 'ride' : 'hat', p + (p % 1 ? .06 : 0), 0, .1, p % 1 ? .2 : .14);
      if (lv >= 2) add('ghost', 3.67, 0, .1, .2);
    }
    if (lv >= 2) strings(x, {vel: .18 + lv * .05, art: 'trem', cb: false, top: Math.min(x.top, 79)});
    if (lv >= 2.5) for (const c of chords) add('cb', c.start, bassNote(c.c, 28), c.len, .3);
  },
  // vals: «um-pa-pa» (violonchelo en pizzicato y arpa al principio; contrabajos, violonchelos y spiccato después),
  // arpa en las B, trompas, triángulo y timbal en los clímax
  waltz(x) {
    const {chords, add, lv, st, i, sec} = x, c = chords[0].c, root = i % 2 ? fifth(c, 36) : bassNote(c, 36);
    if (lv < 2) add('vc_pizz', 0, root + (root < 40 ? 12 : 0), .9, .6); else { add('cb', 0, root - 12 < 28 ? root : root - 12, 1.2, .48); add('vc', 0, root, 1.2, .46); }
    const v = st.pa = led(at(chords, 1).c, 60, Math.min(74, x.top), st.pa);
    [1, 2].forEach(p => v.forEach(n => (lv < 2 ? add('harp', p, n, .9, .24) : add('vln_spic', p, n, .5, .32))));
    if (lv >= 1 && lv < 2.5 && sec.key === 'B') { const t = led(c, 55, 70, null, false), s = [...t, ...t.map(n => n + 12)]; [0, .5, 1, 1.5, 2, 2.5].forEach((p, k) => add('harp', p, s[k % s.length], 1, .22)); }
    if (lv >= 2.5) horns(x, {vel: .3});
    if (lv >= 2.5 && i % 2 === 0) add('triangle', 0, 0, .1, .2);
    if (lv >= 3 && i % 2 === 0) add('timp', 0, tn(c), 1.5, .38);
  },
  // lounge: Rhodes sincopado, contrabajo, guitarra a contratiempo, aro cruzado y charles; cuerdas al final
  lounge(x) {
    const {add, lv, cast, chords} = x;
    comp(x, 'rhodes', [0, 1.5, 2.5, 3.5], 53, Math.min(69, x.top), .3, p => (p % 1 ? .45 : .9), {anticipate: true});
    if (lv >= 1) bassLine(x, cast.bass, [[0, 'r', 1.4, .75], [1.5, '5', .45, .55], [2.5, '8', .45, .5], [3.5, 'a', .45, .48]]);
    if (lv >= 1.5) for (const p of [.5, 2.5]) add('guitar', p, led(at(chords, p).c, 60, 72, null)[1], .25, .24);
    if (lv >= 1) {
      [1, 3].forEach(p => add('xstick', p, 0, .1, .4)); add('kick', 0, 0, .1, .42); add('kick', 2.5, 0, .1, .3);
      for (let p = 0; p < 4; p += .5) add('hat', p, 0, .1, p % 1 ? .26 : .16);
      if (lv >= 2) for (let p = 0; p < 4; p += .25) add('shaker', p, 0, .1, p % .5 ? .14 : .24);
      if (x.last && x.rise) fill(x, 'conga');
    }
    if (lv >= 2.5) strings(x, {vel: .26, cb: false});
  },
  // rumba flamenca: rasgueo con acentos en 1, 2-y y 4, palmas, cajón, bajo eléctrico; cuerdas y bongós al final
  rumba(x) {
    const {add, lv, cast} = x;
    [[0, .46, false], [.5, .24, true], [1, .32, false], [1.5, .4, true], [2, .3, false], [2.5, .26, true], [3, .38, false], [3.5, .3, true]]
      .forEach(([p, v, up]) => comp(x, 'guitar', [p], 50, 69, v, .3, {strum: .018, up}));
    if (lv >= 1) {
      bassLine(x, cast.bass, [[0, 'r', .9, .8], [1.5, '5', .45, .55], [2, 'r', .9, .7], [3.5, 'a', .45, .5]]);
      add('cajon', 0, 0, .1, .55); add('cajon', 2.5, 0, .1, .42); [1, 3].forEach(p => add('cajonslap', p, 0, .1, .4));
      [1, 3].forEach(p => add('claps', p, 0, .1, .4));
      if (lv >= 2) [.5, 1.5, 2.5, 3.5].forEach(p => add('claps', p, 0, .1, .22, {rate: .82, lp: 1800}));
      if (lv >= 2.5) { [.75, 1.75, 3.25].forEach(p => add('cajonslap', p, 0, .1, .2)); [[0, .3], [.5, .22], [2, .26], [2.5, .2]].forEach(([p, v]) => add('bongo', p, 0, .1, v)); }
      if (x.last && x.rise) fill(x, 'cajon');
    }
    if (lv >= 2.5) strings(x, {vel: .26, cb: false});
  },
  // bulería: doce tiempos en dos compases (6/8 + 3/4) con acentos en 12, 3, 6, 8 y 10; guitarra rasgueada, palmas
  // claras y sordas, cajón; la orquesta entra en la copla y responde en spiccato a los acentos
  buleria(x) {
    const {i, add, chords, lv, st, sec} = x, half = i % 2, acc = half ? [0, 2, 4] : [0, 3];
    acc.forEach((p, k) => { const c = at(chords, p).c; if (k === 0 && !half) rasgueado(add, c, st, .5, p); else comp(x, 'guitar', [p], 50, 69, half && p === 4 ? .5 : .42, .9, {strum: .02}); });
    for (let p = 0; p < 6; p++) if (!acc.includes(p) && !(half && p === 5)) comp(x, 'guitar', [p], 52, 67, .18, .4, {strum: .015, up: true});
    acc.forEach(p => add('claps', p, 0, .1, .5));
    if (lv >= 1) {
      for (let p = 0; p < 6; p++) if (!(half && p === 5)) add('claps', p + .5, 0, .1, .24, {rate: .8, lp: 1600});
      add('cajon', 0, 0, .1, .6); acc.slice(1).forEach(p => add('cajonslap', p, 0, .1, .5));
      if (lv >= 2) [1.5, 2.5].forEach(p => !acc.includes(p) && add('cajonslap', p, 0, .1, .2));
    }
    if (lv >= 1.5) acc.forEach(p => add('vc_pizz', p, bassNote(at(chords, p).c, 36), .9, .5));
    if (lv >= 2) strings(x, {vel: .26 + lv * .05, low: lv >= 2.5});
    if (lv >= 2.5 && sec.key === 'A') acc.forEach(p => { (st.sp = led(at(chords, p).c, 62, Math.min(77, x.top), st.sp, false)).forEach(n => add('vln_spic', p, n, .5, .55)); add('vc_spic', p, bassNote(at(chords, p).c, 36), .5, .6); });
    if (lv >= 3) { horns(x, {vel: .34}); acc.forEach(p => add('timp', p, tn(at(chords, p).c), 1, p ? .38 : .48)); }
  },
  // pasodoble: tuba y contrabajos en los tiempos, trompas y spiccato a contratiempo, caja de banda con su ritmo con
  // puntillo, bombo y platos; castañuelas y cuerdas en el trío, trombón en el contracanto
  pasodoble(x) {
    const {chords, add, lv, st, sec} = x;
    [0, 2].forEach(p => { const c = at(chords, p).c, n = p === 0 || chords.length > 1 ? bassNote(c, 31) : fifth(c, 31); add('tuba', p, n, .8, .58); if (lv >= 1.5) add('cb', p, n, .7, .46); });
    [1, 3].forEach(p => {
      const c = at(chords, p).c;
      (st.pa = led(c, 51, 63, st.pa, true)).slice(0, 3).forEach(n => add('horn', p, n, .5, .4));
      if (lv >= 1) led(c, 64, Math.min(77, x.top), null, false).slice(-2).forEach(n => add('vln_spic', p, n, .4, .46));
    });
    if (lv >= 1) {
      [[0, .5], [.75, .28], [1, .42], [2, .48], [2.75, .28], [3, .42]].forEach(([p, v]) => add('msnare', p, 0, .1, v));
      add('bassdrum', 0, 0, .1, .6); add('bassdrum', 2, 0, .1, .5);
      if (lv >= 2) [1, 3].forEach(p => add('clash', p, 0, .1, .22, {choke: .25}));
      if (x.last && x.rise) fill(x, 'msnare');
    }
    if ((sec.key === 'B' && lv >= 2) || lv >= 2.5) {
      [0, .5, .75, 1, 2, 2.5, 2.75, 3].forEach((p, k) => add('castanets', p, 0, .1, k % 4 === 0 ? .55 : .34));
      if (x.i % 4 === 3) [3.5, 3.625, 3.75, 3.875].forEach((p, k) => add('castanets', p, 0, .1, .3 + k * .08));
    }
    if (sec.key === 'B' && lv >= 2) strings(x, {vel: .3, low: false});
    if (lv >= 3 && x.first) add('timp', 0, tn(chords[0].c), 1.5, .5);
  },
};
/** Final de la pieza tras el último compás de la coda. */
function ending(x, kind) {
  const {chords, add, M, cast, st, song} = x, c = chords.at(-1).c;
  if (kind === 'tachan') { // «ta-chán»: dominante y tónica, cortas, con bombo y platos
    [[M, chord(song.cadence || 'A7')], [M + 1, c]].forEach(([p, cc], k) => {
      led(cc, 55, 70, null, false).forEach(n => { add('trumpet', p, n + 12 > 84 ? n : n + 12, .4, .72); add('horn', p, n > 63 ? n - 12 : n, .4, .64); });
      led(cc, 62, 79, null, false).forEach(n => add('vln_spic', p, n, .4, .72));
      add('tuba', p, bassNote(cc, 31), .45, .72); add('cb', p, bassNote(cc, 31), .45, .6); add('timp', p, tn(cc), .8, .7);
      add('bassdrum', p, 0, .1, .8); add('clash', p, 0, .1, k ? .62 : .42, {choke: k ? 1.4 : .3});
    });
    return;
  }
  if (kind === 'remate') { // la bulería acaba en el 10 del compás, con toda la orquesta
    const p = 4;
    rasgueado(add, c, st, .62, p);
    led(c, 60, 79, null, false).forEach(n => add('vln', p, n, 1.6, .62)); add('vc', p, bassNote(c, 40), 1.6, .6); add('cb', p, bassNote(c, 28), 1.6, .55);
    led(c, 49, 63, null, true).forEach(n => add('horn', p, n, 1.6, .5));
    add('timp', p, tn(c), 1.5, .7); add('claps', p, 0, .1, .7); add('cajon', p, 0, .1, .7);
    return;
  }
  voicing(c, 55, false).forEach((n, k) => add(cast.roll, M + k * .12, n, M * 1.5, .32));
  add(cast.bass === 'synthbass' || cast.bass === 'tuba' ? 'cb' : cast.bass, M, bassNote(c, 33), M * 1.5, .3);
  if (cast.orch) { led(c, 60, 76, null, false).forEach(n => add('vln', M, n, M * 1.5, .3)); add('vc', M, bassNote(c, 40), M * 1.5, .3); add('timproll', M, tn(c), M, .2, {dim: 1}); }
  add(cast.orch ? 'swell' : 'crash', cast.orch ? M - 2 / x.spb : M, 0, 2, .16);
}

// ------------------------------------------------------------ las catorce piezas
// Melodía: «nota:pulsos», «-:pulsos» para silencio. Acordes por compás («Gm7 C9» divide el compás).
// leads: instrumento de la melodía en cada sección · dbl: doblaje [instrumento, transporte, nivel] · cast: cambios de reparto
// mix: ajuste de mezcla (dB) del acompañamiento armónico, del bajo y de la percusión respecto a la melodía
export const SONGS = [
  {id: 'anden1', title: 'Andén 1', family: 'estacion', mood: 'any', style: 'bossa', bpm: 108, meter: 4, lead: ['guitar', 'flute'], leads: {A: 'guitar', B: 'flute', A2: 'guitar', B2: 'flute'}, dbl: {B2: ['vln', -12, .42]},
    A: {chords: ['Fmaj7', 'Gm7 C9', 'Fmaj7', 'Am7 D7b9', 'Gm7', 'C9', 'Fmaj7', 'Gm7 C7'],
      mel: 'A4:1.5 C5:.5 E5:1 D5:1 D5:1.5 Bb4:.5 G4:1 E5:1 F5:2 E5:.5 D5:.5 C5:1 E5:1.5 C5:.5 F#5:1 Eb5:1 D5:1.5 Bb4:.5 A4:.5 G4:.5 F4:1 G4:1 A4:.5 Bb4:.5 D5:2 C5:3 -:1 Bb4:1 A4:1 G4:1 E4:1'},
    B: {chords: ['Bbmaj7', 'Bbm6 Eb9', 'Am7', 'D9', 'Gm7', 'C13', 'Fmaj9', 'Gm7 C7'],
      mel: 'D5:1 F5:1 A5:2 G5:1.5 F5:.5 Db5:2 C5:1 E5:1 G5:1.5 E5:.5 F#5:2 E5:1 D5:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 D5:1 Bb4:1 A4:1 G4:1 A4:2 -:2 C5:1 E5:1'}},
  {id: 'primera', title: 'Primera salida', family: 'red', mood: 'day', style: 'ambient', bpm: 74, meter: 4, mix: {harm: -6, bass: 9, drums: 6}, lead: ['piano', 'vln'], leads: {A: 'piano', B: 'flute', A2: 'vln', B2: 'vln'}, dbl: {B2: ['vc', -24, .5]}, cast: {synth: 1},
    A: {chords: ['Dmaj9', 'Bm11', 'Gmaj7', 'A6', 'Dmaj9', 'F#m7', 'Gmaj9', 'Asus4 A'],
      mel: 'F#5:2 A5:1 E5:1 D5:3 -:1 B4:1 D5:1 F#5:2 E5:3 C#5:1 F#5:2 A5:1 B5:1 A5:2 C#6:1 A5:1 B5:2 F#5:2 E5:4'},
    B: {chords: ['Bm9', 'Gmaj7', 'Dmaj7/F#', 'Em9', 'Bm9', 'Gmaj9', 'Em7', 'Asus4'],
      mel: 'D6:2 C#6:1 B5:1 A5:3 -:1 A5:1 F#5:1 D5:2 E5:2 G5:1 F#5:1 D6:2 E6:1 F#6:1 E6:2 D6:1 B5:1 G5:2 B5:1 A5:1 A5:3 -:1'}},
  {id: 'verano', title: 'Horario de verano', family: 'estacion', mood: 'any', style: 'pop', bpm: 92, meter: 4, mix: {bass: 3}, lead: ['piano', 'clarinet'], leads: {A: 'piano', B: 'guitar', A2: 'vln', B2: 'clarinet'}, dbl: {B2: ['flute', 12, .36]},
    A: {chords: ['C', 'G/B', 'Am7', 'F', 'C/E', 'Dm7', 'F G', 'C'],
      mel: 'E5:.5 G5:.5 C6:1 B5:.5 A5:.5 G5:1 G5:.5 D5:.5 G5:1 F5:.5 E5:.5 D5:1 C5:.5 E5:.5 A5:1 G5:.5 E5:.5 C5:1 A4:.5 C5:.5 F5:1.5 E5:.5 D5:1 E5:.5 G5:.5 C6:1 D6:.5 C6:.5 G5:1 F5:1 A5:1 D5:1.5 E5:.5 F5:1 A5:1 G5:1 B5:1 C6:3 -:1'},
    B: {chords: ['Am', 'Em', 'F', 'C', 'Dm7', 'G', 'Em7 A7', 'Dm7 G7'],
      mel: 'A5:1.5 G5:.5 E5:2 G5:1.5 F5:.5 E5:2 F5:1 A5:1 C6:1 A5:1 G5:3 E5:1 F5:1.5 E5:.5 D5:1 C5:1 B4:1 D5:1 G5:2 G5:1 E5:1 C#5:1 E5:1 F5:1 D5:1 B4:1 G4:1'}},
  {id: 'vialibre', title: 'Vía libre', family: 'red', mood: 'day', style: 'drive', bpm: 104, meter: 4, mix: {harm: -5}, lead: ['guitar', 'vln'], leads: {A: 'guitar', B: 'vln', A2: 'trumpet', B2: 'vln'}, dbl: {B2: ['vc', -24, .5]}, cast: {bass: 'synthbass', synth: 1},
    A: {chords: ['Em9', 'Cmaj7', 'G', 'D/F#', 'Em9', 'Cmaj9', 'Am7', 'Dsus4 D'],
      mel: 'B4:3 G4:1 E5:4 D5:3 B4:1 A4:4 B4:2 E5:2 G5:3 F#5:1 E5:2 C5:2 D5:4'},
    B: {chords: ['Cmaj7', 'G/B', 'Am7', 'Em7', 'Cmaj7', 'D', 'Bm7', 'Em'],
      mel: 'G5:2 E5:1 G5:1 D6:3 B5:1 C6:2 B5:1 A5:1 G5:4 E5:2 G5:2 A5:2 F#5:1 D5:1 B5:2 A5:1 F#5:1 E5:4'}},
  {id: 'tarifa', title: 'Tarifa reducida', family: 'estacion', mood: 'any', style: 'swing', swing: true, bpm: 112, meter: 4, mix: {harm: 7, drums: 8}, lead: ['piano', 'vibes'], leads: {A: 'piano', B: 'mtrumpet', A2: 'vibes', B2: 'clarinet'}, dbl: {B2: ['sax', -12, .5]},
    A: {chords: ['Bbmaj7', 'G7', 'Cm7', 'F7', 'Dm7 G7', 'Cm7 F7', 'Bbmaj7 G7', 'Cm7 F7'],
      mel: 'D5:1 F5:.5 G5:.5 A5:1 F5:1 B5:1.5 A5:.5 G5:1 F5:1 Eb5:1 G5:.5 Bb5:.5 C6:1 Bb5:1 A5:2 F5:1 -:1 F5:.5 G5:.5 A5:1 B5:1 D6:1 C6:.5 Bb5:.5 G5:1 A5:1 Eb5:1 D5:2 B4:1 D5:1 C5:1 Eb5:1 A4:1 -:1'},
    B: {chords: ['D7', 'D7', 'G7', 'G7', 'C7', 'C7', 'F7', 'F7'],
      mel: 'F#5:1 A5:1 C6:2 A5:.5 F#5:.5 D5:1 -:2 B4:1 D5:1 F5:2 G5:.5 F5:.5 D5:1 -:2 E5:1 G5:1 Bb5:2 G5:.5 E5:.5 C5:1 -:2 A4:1 C5:1 Eb5:2 F5:2 -:2'}},
  {id: 'medianoche', title: 'Talgo a medianoche', family: 'red', mood: 'night', style: 'night', bpm: 64, meter: 4, mix: {harm: 5, bass: 3, drums: 4}, lead: ['guitar', 'sax'], leads: {A: 'guitar', B: 'clarinet', A2: 'vibes', B2: 'sax'}, spanish: {falseta: true}, intro: ['Am', 'G', 'F', 'E7'], outro: ['Dm9', 'Fmaj7', 'E7b9', 'Am9'],
    A: {chords: ['Am9', 'Fmaj7', 'Dm9', 'E7sus4 E7', 'Am9', 'Cmaj7', 'Fmaj7', 'E7sus4 E7'],
      mel: 'E5:2 C5:1 B4:1 A4:3 -:1 F5:2 E5:1 D5:1 E5:3 -:1 G5:2 E5:1 C5:1 D5:1 E5:1 G5:2 A5:2 C6:1 A5:1 G#5:3 -:1'},
    B: {chords: ['Dm9', 'G13', 'Cmaj9', 'Fmaj7', 'Bm7b5', 'E7b9', 'Am9', 'Am9'],
      mel: 'A5:2 F5:1 E5:1 F5:3 -:1 E5:1 G5:1 B5:2 A5:3 -:1 D5:2 F5:1 A5:1 G#5:2 F5:1 D5:1 C5:2 B4:1 A4:1 A4:3 -:1'}},
  {id: 'norte', title: 'Estación del Norte', family: 'estacion', mood: 'any', style: 'waltz', bpm: 126, meter: 3, mix: {harm: 5, bass: 4, drums: 5}, lead: ['vln', 'clarinet'], leads: {A: 'vln', B: 'clarinet', A2: 'vln', B2: 'oboe'}, dbl: {A2: ['flute', 12, .36], B2: ['clarinet', -12, .42]}, cast: {counter: 'bassoon'}, form: ['intro', 'A', 'A2', 'B', 'A', 'B2', 'A2', 'B', 'A', 'B2', 'A2', 'outro'],
    A: {chords: ['G', 'Em', 'Am7', 'D7', 'G', 'B7', 'Em', 'A7 D7'],
      mel: 'D5:2 B4:1 G5:2 E5:1 C5:2 E5:1 F#5:2 D5:1 B5:2 G5:1 F#5:1 D#5:1 B4:1 E5:2 G5:1 C#5:1.5 F#5:1.5'},
    B: {chords: ['C', 'G', 'Am', 'D', 'C', 'G/B', 'Am7 D7', 'G'],
      mel: 'E5:1 G5:1 C6:1 B5:2 D5:1 C5:1 E5:1 A5:1 F#5:2 A5:1 G5:1 E5:1 C5:1 D5:2 G5:1 A5:1.5 F#5:1.5 G5:3'}},
  {id: 'mediterraneo', title: 'Corredor Mediterráneo', family: 'red', mood: 'day', style: 'drive', bpm: 96, meter: 4, mix: {harm: -6, bass: 6, drums: 5}, lead: ['guitar', 'svln'], leads: {A: 'guitar', B: 'vln', A2: 'guitar', B2: 'svln'}, dbl: {B2: ['vln', -12, .42]}, cast: {kit: 'cajon'}, spanish: {falseta: true, rasgueo: true, palmas: true}, intro: ['Gm', 'F', 'Ebmaj7', 'Cm7 F'], outro: ['Gm', 'F', 'Ebmaj7', 'Bb'],
    A: {chords: ['Bb', 'F/A', 'Gm7', 'Ebmaj7', 'Bb/D', 'Ebmaj9', 'Cm7', 'F'],
      mel: 'D5:2 F5:2 C5:3 F4:1 Bb4:2 D5:2 G5:3 -:1 F5:2 Bb5:2 G5:2 F5:1 Eb5:1 Eb5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Gm', 'Ebmaj7', 'Bb', 'F', 'Gm', 'Eb', 'Cm7', 'F'],
      mel: 'Bb5:2 A5:1 G5:1 G5:3 Bb5:1 F5:2 D5:2 C5:4 D5:1 Eb5:1 F5:1 G5:1 G5:2 Bb5:2 Eb6:2 D6:1 C6:1 C6:4'}},
  {id: 'ancho', title: 'Cambio de ancho', family: 'estacion', mood: 'any', style: 'lounge', bpm: 84, meter: 4, mix: {harm: -4}, lead: ['vibes', 'svln'], leads: {A: 'vibes', B: 'flute', A2: 'rhodes', B2: 'svln'}, dbl: {B2: ['vc', -24, .42]},
    A: {chords: ['Ebmaj7', 'Cm7', 'Fm7', 'Bb7', 'Gm7', 'C7b9', 'Fm7', 'Bb7sus4 Bb7'],
      mel: 'G5:1.5 Bb5:.5 D6:1 C6:1 Bb5:1.5 G5:.5 Eb5:2 Ab5:1 G5:.5 F5:.5 C5:1 Ab4:1 D5:2 F5:1 -:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 Db5:1 Bb4:1 Ab4:1 C5:1 Eb5:1 Ab5:1 G5:2 F5:2'},
    B: {chords: ['Abmaj7', 'Gm7', 'Fm7', 'Ebmaj7', 'Dm7b5', 'G7b9', 'Cm7', 'F7 Bb7'],
      mel: 'C6:1.5 Bb5:.5 G5:2 Bb5:1.5 F5:.5 D5:2 Ab5:1 G5:1 F5:1 Eb5:1 G5:3 -:1 F5:1 Ab5:1 C6:2 B5:1.5 Ab5:.5 F5:2 Eb5:1 G5:1 Bb5:1 G5:1 A5:2 Ab5:2'}},
  {id: 'meseta', title: 'Atardecer en la meseta', family: 'red', mood: 'dusk', style: 'ambient', bpm: 68, meter: 4, mix: {harm: -2, bass: 9, drums: 6}, lead: ['piano', 'vln'], leads: {A: 'piano', B: 'vln', A2: 'oboe', B2: 'vln'}, dbl: {B2: ['vc', -24, .5]},
    A: {chords: ['Fmaj7#11', 'C/E', 'Dm9', 'Bbmaj7', 'Fmaj7', 'Am7', 'Bbmaj9', 'Csus4 C'],
      mel: 'A5:2 C6:1 B5:1 G5:4 F5:2 A5:1 E5:1 D5:4 C5:1 F5:1 A5:2 G5:2 E5:2 F5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Dm7', 'Bbmaj7', 'F/A', 'Gm9', 'Dm9', 'Bbmaj7#11', 'Gm7', 'Csus4'],
      mel: 'F6:2 E6:1 D6:1 D6:3 -:1 C6:2 A5:1 F5:1 G5:3 -:1 A5:2 C6:1 E6:1 D6:2 E6:1 F6:1 D6:2 Bb5:1 G5:1 G5:4'}},
  {id: 'pasajeros', title: 'Pasajeros al tren', family: 'estacion', mood: 'any', style: 'rumba', bpm: 116, meter: 4, mix: {drums: 5}, lead: ['guitar', 'svln'], leads: {A: 'guitar', B: 'guitar', A2: 'svln', B2: 'guitar'}, dbl: {B2: ['svln', 0, .4]}, spanish: {falseta: true, rasgueo: true, palmas: true}, intro: ['Em', 'D', 'C', 'D7'], outro: ['C', 'B7', 'Em', 'Gmaj7'],
    A: {chords: ['Gmaj7', 'Am7 D9', 'Bm7 E7', 'Am7 D7', 'Gmaj7', 'Em7', 'A9', 'Am7 D7'],
      mel: 'B4:1 D5:.5 F#5:.5 A5:2 G5:1 E5:1 C5:1 F#5:1 D5:1.5 B4:.5 G#5:1 D5:1 C5:1 E5:1 F#5:2 B5:1.5 A5:.5 F#5:1 D5:1 E5:2 G5:1 B5:1 C#6:1.5 B5:.5 G5:1 E5:1 A5:2 F#5:2'},
    B: {chords: ['Cmaj7', 'Cm6 F9', 'Bm7', 'E7', 'Am7', 'D9', 'Gmaj7', 'Am7 D7'],
      mel: 'E5:1 G5:1 B5:2 A5:1.5 G5:.5 Eb5:2 D5:1 F#5:1 A5:2 G#5:2 E5:2 C5:1 E5:1 G5:1 B5:1 A5:1.5 F#5:.5 E5:2 D5:4 -:2 C5:1 F#5:1'}},
  {id: 'obras', title: 'Obras nocturnas', family: 'red', mood: 'night', style: 'night', bpm: 78, meter: 4, mix: {harm: 6, bass: 4, drums: 5}, lead: ['piano', 'svln'], leads: {A: 'piano', B: 'flute', A2: 'vibes', B2: 'svln'}, spanish: {falseta: true}, intro: ['Dm', 'C', 'Bbmaj7', 'A7'], outro: ['Gm9', 'Bbmaj7', 'A7b9', 'Dm9'],
    A: {chords: ['Dm9', 'Bbmaj7', 'Gm9', 'A7sus4', 'Dm9', 'Fmaj7', 'Gm7', 'Asus4 A7'],
      mel: 'A5:1 F5:1 E5:1 D5:1 D5:3 -:1 Bb5:1 A5:1 F5:1 D5:1 E5:3 -:1 A5:1 C6:1 E6:1 D6:1 C6:3 -:1 Bb5:1 A5:1 G5:1 F5:1 E5:2 C#5:2'},
    B: {chords: ['Gm9', 'C9', 'Fmaj7', 'Bbmaj7', 'Em7b5', 'A7b9', 'Dm9', 'Dm9'],
      mel: 'Bb5:2 D6:2 E6:2 Bb5:2 A5:2 C6:1 A5:1 F5:4 G5:2 Bb5:1 E5:1 C#5:2 E5:1 G5:1 F5:2 E5:1 D5:1 D5:4'}},
  // Bulería en La frigio (cadencia andaluza Rem–Do–Sib–La): el compás de doce tiempos se reparte en dos compases de seis.
  {id: 'despenaperros', title: 'Despeñaperros', family: 'red', mood: 'day', style: 'buleria', bpm: 176, meter: 6, mix: {harm: -7, bass: 5, drums: 4}, lead: ['guitar', 'svln'], leads: {A: 'guitar', B: 'svln', A2: 'vln', B2: 'svln'}, dbl: {B2: ['vc', -12, .45]},
    spanish: {falseta: true}, intro: ['A', 'Bb', 'A', 'A7b9'], outro: ['Dm', 'C', 'Bb', 'A'], ending: 'remate', form: ['intro', 'A', 'B', 'A2', 'B2', 'A', 'B2', 'outro'],
    A: {chords: ['Dm', 'C', 'Bb', 'A', 'Dm', 'C', 'Gm7', 'A7b9'],
      mel: 'A5:2 Bb5:1 A5:1 G5:1 F5:1 E5:2 G5:2 F5:1 E5:1 D5:3 F5:1 E5:1 D5:1 C#5:4 -:2 F5:2 A5:1 D6:3 C6:2 Bb5:1 A5:1 G5:2 A5:1 Bb5:1 A5:1 G5:1 F5:1 E5:1 D5:1 C#5:1 Bb4:1 A4:3'},
    B: {chords: ['F', 'C7', 'C7', 'F', 'Bb', 'F', 'Gm7', 'A7'],
      mel: 'C5:2 F5:1 A5:3 G5:2 E5:2 C5:2 Bb5:3 A5:1 G5:1 Bb5:1 A5:4 -:2 D6:2 C6:1 Bb5:3 A5:2 C6:2 A5:1 F5:1 Bb5:2 A5:1 G5:2 F5:1 E5:1 F5:1 E5:1 D5:1 C#5:2'}},
  // Pasodoble en Re menor con trío en Fa mayor, introducción de fanfarria y final «ta-chán».
  {id: 'expreso', title: 'Expreso de Andalucía', family: 'estacion', mood: 'any', style: 'pasodoble', bpm: 118, meter: 4, mix: {bass: 2}, lead: ['trumpet', 'vln'], leads: {A: 'trumpet', B: 'vln', A2: 'trumpet', B2: 'vln'}, dbl: {A2: ['clarinet', 0, .42], B2: ['vc', -12, .48]},
    intro: ['Dm', 'A7', 'Dm', 'A7'], outro: ['Dm', 'Gm', 'A7', 'Dm'], ending: 'tachan', cadence: 'A7', form: ['intro', 'A', 'A2', 'B', 'B2', 'A', 'A2', 'outro'],
    A: {chords: ['Dm', 'Dm A7', 'A7', 'Dm', 'Gm', 'Dm', 'E7', 'A7'],
      mel: 'A4:.75 D5:.25 F5:.75 E5:.25 D5:1 A5:1 Bb5:.75 A5:.25 G5:.75 F5:.25 E5:2 C#5:.75 E5:.25 G5:.75 F5:.25 E5:1 Bb5:1 A5:3 -:1 Bb5:.75 A5:.25 G5:.75 Bb5:.25 D6:1 C6:1 A5:.75 G5:.25 F5:.75 E5:.25 D5:1 F5:1 E5:.75 F5:.25 G#5:.75 A5:.25 B5:1 G#5:1 A5:2 G5:.5 F5:.5 E5:1'},
    B: {chords: ['F', 'C7', 'C7', 'F', 'Bb', 'F', 'G7 C7', 'F A7'],
      mel: 'C5:1 F5:1.5 G5:.5 A5:1 Bb5:2 G5:1 E5:1 C5:1 E5:1.5 F5:.5 G5:1 A5:3 -:1 D6:1.5 C6:.5 Bb5:1 D6:1 C6:1.5 A5:.5 F5:1 A5:1 G5:1 B5:1 Bb5:1 E5:1 F5:2 E5:1 C#5:1'}},
];
export const FAMILY_LABEL = {estacion: 'Estilo «Estación»: bossa, rumba, pasodoble, jazz, vals y pop', red: 'Estilo «Red»: orquestal, nocturnas y bulería'};
export const STYLE_LABEL = {rumba: 'Rumba flamenca', bossa: 'Bossa nova', swing: 'Jazz', waltz: 'Vals', pop: 'Pop orquestal', lounge: 'Lounge', ambient: 'Orquestal', drive: 'Orquestal rítmica', night: 'Nocturna', buleria: 'Bulería', pasodoble: 'Pasodoble'};

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
// intensidad de cada parte de la forma (la segunda vez que aparece, medio punto más) y dinámica general
const LV = {intro: 1, A: 1, B: 2, A2: 2.5, B2: 3, outro: 1};
const DYN = {intro: .95, A: .92, B: 1, A2: 1.04, B2: 1.08, outro: .95};
/** Convierte una pieza en una lista de eventos {t (s), inst, midi, dur (s), vel, opt}.
 *  La melodía de cada sección se toca tal cual está escrita (marcada con opt.mel) y ligada en los instrumentos de
 *  arco y viento; el arreglo añade la orquestación por capas según la intensidad de cada parte, doblajes de la
 *  melodía, segundas voces, contracantos con notas guía, respuestas en los silencios, transiciones (redobles de
 *  timbal, platillo, arpa o batería) y el final propio de cada estilo. */
export function arrange(song) {
  const spb = 60 / song.bpm, M = song.meter, rand = rng(song.id), events = [], st = {};
  const form = song.form || ['intro', 'A', 'B', 'A2', 'B2', 'A', 'B', 'A2', 'outro'];
  const cast = {...CAST[song.style], ...(song.cast || {})}, sp = song.spanish || {};
  const liftFrom = song.lift ? form.lastIndexOf('A2') : -1;
  const seen = {}, level = form.map(p => { seen[p] = (seen[p] || 0) + 1; return Math.min(3, LV[p] + (seen[p] > 1 && p !== 'outro' ? .5 : 0)); });
  const swing = b => { if (!song.swing) return b; const f = b - Math.floor(b); return Math.abs(f - .5) < 1e-6 ? Math.floor(b) + .67 : b; };
  const barsOf = p => (p === 'intro' ? (song.intro || [0, 0, 0, 0]).length : p === 'outro' ? (song.outro || [0, 0, 0, 0]).length : song[p[0] === 'B' ? 'B' : 'A'].chords.length);
  const melAll = [];
  form.reduce((b0, p) => { if (p !== 'intro' && p !== 'outro') for (const n of parseMel(song[p[0] === 'B' ? 'B' : 'A'].mel).notes) if (n.midi !== null) melAll.push({a: b0 * M + n.beat, b: b0 * M + n.beat + n.dur, m: n.midi}); return b0 + barsOf(p); }, 0);
  // una nota del acompañamiento a un semitono (o novena menor) de una nota de la melodía que suena a la vez se omite
  const rubs = (a, d, m) => melAll.some(n => n.a < a + d && n.b > a && Math.min(a + d, n.b) - Math.max(a, n.a) >= Math.min(.6, d * .5) && Math.abs(n.m - m) <= 13 && (pcOf(n.m - m) === 1 || pcOf(m - n.m) === 1));
  // ritardando en los dos últimos compases de la coda (el tiempo se estira hasta un 25 %)
  const total = form.reduce((n, p) => n + barsOf(p), 0) * M;
  const ritFrom = song.ending ? Infinity : total - 2 * M, when = b => b + (b > ritFrom ? .25 * (b - ritFrom) ** 2 / (4 * M) : 0);
  let bar0 = 0;
  form.forEach((part, si) => {
    const key = part[0] === 'B' ? 'B' : 'A', sec = song[key], tr = liftFrom >= 0 && si >= liftFrom ? 1 : 0, lv = level[si];
    let bars = sec.chords;
    if (part === 'intro') bars = song.intro || sec.chords.slice(0, 4);
    if (part === 'outro') bars = song.outro || sec.chords.slice(-4, -1).concat([sec.chords[0].split(' ')[0]]);
    const info = {key, part, light: part === 'intro' || part === 'outro', pad: part.endsWith('2')};
    const dyn = DYN[part] ?? DYN[key], rise = si + 1 < form.length && form[si + 1] !== 'outro' && level[si + 1] > lv + .3;
    const melNotes = info.light ? [] : parseMel(sec.mel).notes.filter(n => n.midi !== null).map(n => n.midi);
    const top = melNotes.length ? Math.max(64, Math.min(...melNotes) - 1) : 76;
    const spans = [];
    const mk = (base, bi = 0) => (inst, beat, m, dur, vel, opt = {}) => {
      const drum = DRUMS.has(inst), phr = opt.mel ? 1 : 1 + .05 * Math.sin(Math.PI * (bi + .5) / bars.length);
      if (!opt.mel && !drum && !BASS.has(inst) && rubs(base + beat, dur, m)) return;
      const db = opt.mel ? 0 : (song.mix?.[drum ? 'drums' : BASS.has(inst) ? 'bass' : 'harm'] ?? 0);
      if (db) opt = {...opt, g: 10 ** (db / 20)};
      events.push({t: Math.max(0, when(swing(base + beat)) * spb + (rand() - .5) * (drum ? .006 : .012)), inst, midi: drum ? m : m + tr, dur: dur * spb, vel: clamp(vel * (.9 + rand() * .16) * dyn * phr, .02, 1), opt});
    };
    bars.forEach((spec, i) => {
      const syms = spec.split(' '), len = M / syms.length;
      const chords = syms.map((s, k) => ({c: chord(s), start: k * len, len}));
      const nextSpec = bars[i + 1] || (form[si + 1] && form[si + 1] !== 'outro' ? song[form[si + 1][0] === 'B' ? 'B' : 'A'].chords[0] : sec.chords[0]);
      const next = chord(nextSpec.split(' ')[0]), base = (bar0 + i) * M, add = mk(base, i);
      chords.forEach(c => spans.push({start: base + c.start, end: base + c.start + c.len, c: c.c}));
      const x = {i, n: bars.length, first: i === 0, last: i === bars.length - 1, chords, add, sec: info, next, st, rand, cast, M, spb, sp, lv, top, rise, song};
      STYLES[song.style](x);
      if (sp.rasgueo && i % 2 === 0 && part !== 'outro') rasgueado(add, chords[0].c, st, info.light ? .3 : .42);
      if (sp.palmas && song.style === 'drive' && !info.light && info.pad) for (let p = .5; p < M; p += 1) add('claps', p, 0, .1, .22, {rate: .85, lp: 2200});
      // transición hacia una parte más intensa: redoble de timbal, platillo y arpa (orquesta) o redoble de batería
      if (x.last && rise && cast.orch) { add('timproll', M - 2, tn(next), 2, .32 + lv * .05, {cresc: 1}); add('swell', M - Math.min(M, 2 / spb), 0, 2, .26); if (lv >= 1) harpSweep(add, next, M - 1, 1, 55, .3); }
      if (part === 'intro' && i === 0 && cast.roll !== 'guitar') arp({add, st}, cast.roll, chords[0], 0, Math.min(2, M), .25, 55, .2, true);
      if (part === 'outro' && i === bars.length - 1) ending(x, song.ending);
    });
    if (!info.light) {
      const {notes} = parseMel(sec.mel), slot = info.pad ? key + '2' : key;
      const lead = song.leads?.[slot] || song.lead[info.pad ? 1 : 0], dbl = song.dbl?.[slot];
      const chordAt = beat => (spans.find(s => beat >= s.start - 1e-6 && beat < s.end - 1e-6) || spans.at(-1)).c;
      const melodic = notes.filter(n => n.midi !== null), hi = Math.max(...melodic.map(n => n.midi)), lo = Math.min(...melodic.map(n => n.midi));
      const add = mk(0), xs = {add, cast, sp, st}, sus = SUS_LEAD.has(lead);
      let prevEnd = -1;
      notes.forEach((n, k) => {
        const beat = bar0 * M + n.beat;
        if (n.midi === null) {
          if (n.dur >= 1 && rand() < .85) { const prev = notes.slice(0, k).reverse().find(q => q.midi !== null); answer(xs, chordAt(beat), beat, Math.min(n.dur, 2), prev ? prev.midi : 72, .32, lead); }
          return;
        }
        const shape = (n.midi - lo) / Math.max(1, hi - lo), vel = .56 + rand() * .08 + shape * .12 + (n.dur >= 2 ? .04 : 0);
        const leg = sus && Math.abs(prevEnd - beat) < 1e-6;
        add(lead, beat, n.midi, n.dur * .95, vel, {mel: true, leg});
        if (dbl) {
          const [inst, shift, g = .5] = dbl, [rlo, rhi] = RANGE[inst] || [36, 96]; let m2 = n.midi + shift;
          while (m2 > rhi) m2 -= 12; while (m2 < rlo) m2 += 12;
          add(inst, beat, m2, n.dur * .95, vel * g, {leg: leg && SUS_LEAD.has(inst)});
        }
        if (info.pad && key === 'A' && cast.harm && !dbl && n.dur >= 1) { const u = under(n.midi, chordAt(beat)); if (u !== null && u >= (RANGE[cast.harm]?.[0] ?? 0)) add(cast.harm, beat, u, n.dur * .95, vel * .48); }
        if (n.dur >= 3 && rand() < .7) answer(xs, chordAt(beat + 1.5), beat + 1.5, Math.min(n.dur - 1.5, 2), n.midi - 3, .28, lead);
        prevEnd = beat + n.dur;
      });
      if (cast.counter && cast.counter !== lead && (slot === 'B2' || lv >= 3)) counterLine(add, spans, cast.counter, notes, bar0 * M);
    }
    bar0 += bars.length;
  });
  events.sort((a, b) => a.t - b.t);
  return {events, length: when(bar0 * M) * spb + (song.ending ? 3.5 : 1.5 * M * spb + 4)};
}

// ------------------------------------------------------------ reproducción
/** Instrumentos muestreados que han tenido que sonar con su sustituto sintetizado (para las pruebas). */
export const substituted = {};
function play(ctx, mix, e, t0) {
  const o = e.opt || {};
  if (sampled(ctx, mix, t0 + e.t, e.inst, e.midi, e.dur, e.vel, o)) return;
  if (SAMPLE_INDEX[e.inst]) substituted[e.inst] = (substituted[e.inst] || 0) + 1;
  const fn = SYNTH[e.inst] || SYNTH[FALLBACK[e.inst]];
  if (fn) fn(ctx, mix.inst(e.inst), t0 + e.t, e.midi, e.dur, e.vel, o);
}
/** Instrumentos que usa una lista de eventos (para decodificarlos antes de tocar). */
export const instrumentsOf = events => [...new Set(events.map(e => e.inst))];

/** Renderiza una lista de eventos en un búfer estéreo de `length` segundos. */
export async function renderEvents(events, length, bpm = 100, sampleRate = 44100, raw = false) {
  const ctx = new OfflineAudioContext(2, Math.ceil(length * sampleRate), sampleRate);
  await loadInstruments(ctx, instrumentsOf(events));
  const vol = ctx.createGain(); vol.gain.value = .8 * MIX_GAIN; vol.connect(raw ? ctx.destination : masterChain(ctx, ctx.destination));
  const mix = makeMix(ctx, vol, bpm);
  // se programa por tramos (suspendiendo el render) para que el grafo no acumule miles de nodos a la espera
  let i = 0;
  const schedule = until => { while (i < events.length && events[i].t < until) play(ctx, mix, events[i++], .05); };
  schedule(5);
  for (let t = 4; t < length; t += 4) ctx.suspend(t).then(() => { schedule(t + 5); ctx.resume(); });
  const buf = await ctx.startRendering();
  mix.dispose();
  return buf;
}
/** Renderiza una pieza completa en un búfer (para exportar a audio). */
export function renderSong(song, sampleRate = 44100, keep = null) {
  const {events, length} = arrange(song);
  return renderEvents(keep ? events.filter(keep) : events, length, song.bpm, sampleRate);
}

/** Reproductor en tiempo real con programación anticipada y fundidos entre piezas. */
export class Soundtrack {
  constructor(getMood) {
    this.getMood = getMood; this.ctx = null; this.current = null; this.timer = null; this.mode = 'auto'; this.listeners = new Set();
    this.substituted = substituted; // instrumentos que han sonado con su sustituto sintetizado (debería quedar vacío)
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
    this.master.connect(makeup); makeup.connect(masterChain(this.ctx, this.ctx.destination));
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
    if (cur && this.ctx) { cur.gain.gain.setTargetAtTime(0, this.ctx.currentTime, fade / 4); setTimeout(() => { try { cur.gain.disconnect(); } catch {} cur.mix.dispose(); }, fade * 1000 + 6000); }
    this.emit();
  }
  play(song) {
    this.init();
    if (!this.ctx) return;
    this.stop(1.2);
    this.enabled = true; this.save();
    const gain = this.ctx.createGain(); gain.gain.value = 0; gain.connect(this.master);
    const mix = makeMix(this.ctx, gain, song.bpm), {events, length} = arrange(song), names = instrumentsOf(events);
    const cur = this.current = {song, gain, mix, events, length, t0: 0, i: 0, ready: false};
    // las muestras se cargan y decodifican la primera vez; mientras, la pieza ya figura como «sonando»
    loadInstruments(this.ctx, names).then(() => {
      if (this.current !== cur) return;
      releaseInstruments(new Set(names));
      cur.t0 = this.ctx.currentTime + .15; cur.ready = true;
      gain.gain.setTargetAtTime(1, this.ctx.currentTime, .4);
      clearInterval(this.timer);
      this.timer = setInterval(() => {
        if (this.current !== cur) return;
        const now = this.ctx.currentTime;
        while (cur.i < events.length && cur.t0 + events[cur.i].t < now + .3) { play(this.ctx, mix, events[cur.i], cur.t0); cur.i++; }
        if (now > cur.t0 + length) this.next();
      }, 60);
    });
    this.emit();
  }
  next() { if (this.enabled) this.play(this.pick()); }
  get position() { return this.current?.ready && this.ctx ? Math.max(0, this.ctx.currentTime - this.current.t0) : 0; }
}
