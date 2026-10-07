// Efectos de sonido de la interfaz de Iberia Ferroviaria.
// Cada botón y cada clic tienen su sonido, todos de una misma familia —madera, papel, metal, campanas de mano y
// vibráfono— y escritos en Re mayor pentatónico para que nunca desentonen entre sí; mientras suena una pieza, sus
// notas se transportan a la tonalidad de esa pieza, así que los efectos armonizan siempre con la música. Cada tipo de acción tiene su
// gesto: navegar pasa una hoja con su nota propia, abrir y cerrar paneles mueve el aire, firmar estampa un sello
// seguido de campanas, la jornada empieza con el aviso de megafonía de una estación y una bocina lejana, el panel
// de salidas repiquetea como las paletas de los antiguos indicadores, las palancas de capa suenan a cabina de
// enclavamiento, los + y − suben y bajan con la frecuencia y los errores responden con un «no» suave.
// Las capas son muestras reales (grupo «ui» del banco: VCSL y Virtuosity Drums, CC0) y síntesis muy breve.
import {instrument, loadInstruments, prefetchInstruments, hallIR, chord} from './music.js';

export const UI_SAMPLES = ['ui_wood', 'ui_woodf', 'ui_clave', 'ui_paper', 'ui_tri', 'ui_finger', 'ui_shimmer', 'ui_anvil', 'ui_chime', 'ui_vibe'];
const PENTA = [0, 2, 4, 7, 9];
/** Grado i de Re mayor pentatónico contando desde Re5 (midi 74). */
export const deg = (i, base = 74) => base + PENTA[((i % 5) + 5) % 5] + 12 * Math.floor(i / 5);
const D5 = 74, E5 = 76, FS5 = 78, A5 = 81, D6 = 86, A4 = 69;
const MAKEUP = 2.5; // ganancia del bus de efectos respecto a su volumen (0–1)
/** Transporte (semitonos, de −6 a +5) que lleva el Re pentatónico de los efectos a la tonalidad de una pieza: la mayor
 *  de su primer acorde o, si es menor, su relativo mayor (La menor → Do, cuya pentatónica es la de La menor). */
export function keyOf(song) {
  if (!song) return 0;
  const c = chord(song.A.chords[0].split(' ')[0]), major = c.iv.includes(3) && !c.iv.includes(4) ? (c.root + 3) % 12 : c.root;
  return ((major - 2 + 18) % 12) - 6;
}

const noise = new WeakMap();
/** Ruido blanco (clics) y rosa (barridos de aire) de 1,5 s, uno por contexto. */
function noiseOf(ctx, pink) {
  if (!noise.has(ctx)) {
    const make = p => {
      const b = ctx.createBuffer(1, Math.floor(ctx.sampleRate * 1.5), ctx.sampleRate), d = b.getChannelData(0);
      let b0 = 0, b1 = 0, b2 = 0;
      for (let i = 0; i < d.length; i++) {
        const w = Math.random() * 2 - 1;
        if (!p) { d[i] = w; continue; }
        b0 = .99765 * b0 + w * .099046; b1 = .963 * b1 + w * .2965164; b2 = .57 * b2 + w * 1.0526913; // Paul Kellet
        d[i] = (b0 + b1 + b2 + w * .1848) * .2;
      }
      return b;
    };
    noise.set(ctx, {white: make(false), pink: make(true)});
  }
  return noise.get(ctx)[pink ? 'pink' : 'white'];
}
const reversedBufs = new WeakMap();
function reversed(ctx, buf) {
  if (!reversedBufs.has(buf)) {
    const r = ctx.createBuffer(buf.numberOfChannels, buf.length, buf.sampleRate);
    for (let c = 0; c < buf.numberOfChannels; c++) { const s = buf.getChannelData(c), d = r.getChannelData(c); for (let i = 0; i < s.length; i++) d[i] = s[s.length - 1 - i]; }
    reversedBufs.set(buf, r);
  }
  return reversedBufs.get(buf);
}

/** Capas de un efecto, programadas desde el instante t0 del contexto. */
class Layers {
  constructor(bus, t0, k = 1, tr = 0) { this.bus = bus; this.ctx = bus.ctx; this.t0 = t0; this.k = k; this.tr = tr; }
  dest(pan = 0, wet = 0) {
    let node = this.bus.dry;
    if (pan && this.ctx.createStereoPanner) { const p = this.ctx.createStereoPanner(); p.pan.value = pan; p.connect(node); node = p; }
    if (wet) { const g = this.ctx.createGain(); g.gain.value = wet; node.connect(g); g.connect(this.bus.send); }
    return node;
  }
  /** Muestra real: nota afinada (m; se transporta a la tonalidad de la pieza salvo con fixed) o golpe (variante k), con transporte, filtros, panorama, duración y al revés. */
  smp(name, o = {}) {
    const inst = instrument(name);
    if (!inst) { this.bus.missing[name] = (this.bus.missing[name] || 0) + 1; return o.m ? this.tone({...o, dur: Math.min(o.dur ?? .5, .6)}) : this.click({t: o.t, v: (o.v ?? .2) * .5, f: 2600, q: 2.5}); }
    const ctx = this.ctx, t = this.t0 + (o.t || 0);
    let s, rate = o.rate || 1;
    if (inst.kind === 'tonal') {
      const ns = inst.notes, m = o.m + (o.fixed ? 0 : this.tr); let k = 0;
      for (let j = 1; j < ns.length; j++) if (Math.abs(ns[j] - m) < Math.abs(ns[k] - m)) k = j;
      s = inst.layers[0][k]; rate *= 2 ** ((m - ns[k] - (inst.tune?.[k] || 0)) / 12);
    } else { const list = inst.layers[0]; s = list[o.k ?? (inst.rr = (inst.rr + 1) % list.length)]; }
    const buf = o.reverse ? reversed(ctx, s.buf) : s.buf, from = o.reverse ? 0 : s.off;
    const src = ctx.createBufferSource(); src.buffer = buf; src.playbackRate.value = rate;
    let node = this.dest(o.pan, o.wet);
    if (o.lp) { const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = o.lp; f.connect(node); node = f; }
    if (o.hp) { const f = ctx.createBiquadFilter(); f.type = 'highpass'; f.frequency.value = o.hp; f.connect(node); node = f; }
    const g = ctx.createGain(), len = (buf.duration - from) / rate, d = Math.min(len, o.dur ?? len);
    g.connect(node); src.connect(g);
    g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime((o.v ?? .2) * this.k, t + (o.attack ?? .002));
    if (d < len) g.gain.setTargetAtTime(0, t + d, .025);
    src.start(t, from); src.stop(t + Math.min(len, d + .15));
  }
  /** Clic: ráfaga de ruido de pocos milisegundos filtrada en banda. */
  click({t = 0, v = .2, f = 2000, q = 2, dur = .012, pan = 0} = {}) {
    const ctx = this.ctx, at = this.t0 + t, n = ctx.createBufferSource(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    n.buffer = noiseOf(ctx); bp.type = 'bandpass'; bp.frequency.value = f; bp.Q.value = q;
    n.connect(bp); bp.connect(g); g.connect(this.dest(pan));
    g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v * this.k, at + .0006); g.gain.setTargetAtTime(0, at + .0008, dur / 3);
    n.start(at, Math.random() * 1.2); n.stop(at + dur * 4 + .02);
  }
  /** Golpe grave: seno que cae de f0 a f1 (cuerpo de un sello o de una tecla). */
  thump({t = 0, v = .3, f0 = 120, f1 = 55, dur = .1} = {}) {
    const ctx = this.ctx, at = this.t0 + t, o = ctx.createOscillator(), g = ctx.createGain();
    o.frequency.setValueAtTime(f0, at); o.frequency.exponentialRampToValueAtTime(f1, at + dur);
    o.connect(g); g.connect(this.bus.dry);
    g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v * this.k, at + .004); g.gain.setTargetAtTime(0, at + .006, dur / 3);
    o.start(at); o.stop(at + dur * 2 + .05);
  }
  /** Aire: ruido rosa con un filtro de banda que barre de `from` a `to` Hz. */
  sweep({t = 0, v = .05, from = 400, to = 2600, dur = .18, q = 1.3, pan = 0} = {}) {
    const ctx = this.ctx, at = this.t0 + t, n = ctx.createBufferSource(), bp = ctx.createBiquadFilter(), g = ctx.createGain();
    n.buffer = noiseOf(ctx, true); bp.type = 'bandpass'; bp.Q.value = q;
    bp.frequency.setValueAtTime(from, at); bp.frequency.exponentialRampToValueAtTime(to, at + dur);
    n.connect(bp); bp.connect(g); g.connect(this.dest(pan));
    g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v * this.k, at + dur * .45); g.gain.linearRampToValueAtTime(0, at + dur);
    n.start(at, Math.random() * 1.2); n.stop(at + dur + .05);
  }
  /** Tono suave de respaldo (si las muestras aún no están): seno con un parcial de campana. */
  tone({t = 0, v = .1, m = 74, dur = .4, lp} = {}) {
    const ctx = this.ctx, at = this.t0 + t, f = 440 * 2 ** ((m + this.tr - 69) / 12), g = ctx.createGain();
    let node = this.bus.dry;
    if (lp) { const fl = ctx.createBiquadFilter(); fl.type = 'lowpass'; fl.frequency.value = lp; fl.connect(node); node = fl; }
    g.connect(node);
    [[1, 1], [2.76, .18]].forEach(([k, a]) => { const o = ctx.createOscillator(), og = ctx.createGain(); o.frequency.value = f * k; og.gain.value = a; o.connect(og); og.connect(g); o.start(at); o.stop(at + dur + .3); });
    g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v * .5 * this.k, at + .004); g.gain.setTargetAtTime(0, at + .01, dur / 3);
  }
  /** Bocina de tren lejana: dos bocinas en tercera menor, con formante metálico, filtrada y con mucha sala. */
  horn({t = 0, v = .05, dur = .6} = {}) {
    const ctx = this.ctx, at = this.t0 + t, end = at + dur, lp = ctx.createBiquadFilter(), g = ctx.createGain();
    lp.type = 'lowpass'; lp.frequency.value = 2000; lp.Q.value = .4; lp.connect(g); g.connect(this.dest(-.25, 1.6));
    [[311.1, -.004], [370, .003]].forEach(([f, dt]) => {
      const o = ctx.createOscillator(), bp = ctx.createBiquadFilter(), og = ctx.createGain();
      o.type = 'sawtooth'; o.frequency.setValueAtTime(f * .965, at); o.frequency.linearRampToValueAtTime(f * (1 + dt), at + .07);
      bp.type = 'bandpass'; bp.frequency.value = 880; bp.Q.value = .7; og.gain.value = .5;
      o.connect(bp); bp.connect(og); og.connect(lp); o.start(at); o.stop(end + .3);
    });
    g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v * this.k, at + .05); g.gain.setValueAtTime(v * this.k, end - .08); g.gain.linearRampToValueAtTime(0, end + .14);
  }
  /** Paletas de un indicador de salidas: n chasquidos que se van frenando y un golpe final que asienta. */
  flap({t = 0, n = 14, v = .09, from = .022, to = .05} = {}) {
    let at = t;
    for (let k = 0; k < n; k++) {
      const j = (Math.random() - .5) * .004, a = v * (.75 + Math.random() * .4);
      this.click({t: at + j, v: a, f: 2400 + Math.random() * 900, q: 3, dur: .006});
      this.click({t: at + j + .004, v: a * .55, f: 1200 + Math.random() * 300, q: 2, dur: .01});
      at += from + (to - from) * (k / Math.max(1, n - 1)) ** 2;
    }
    this.smp('ui_clave', {t: at + .012, v: v * 1.5, rate: 1.55, dur: .08});
    return at + .02;
  }
  // ---- gestos compuestos
  chimes(notes, {t = 0, v = .18, step = .09, inst = 'ui_chime', dur} = {}) { notes.forEach((m, k) => this.smp(inst, {m, t: t + k * step, v: v * (1 - k * .04), dur})); }
  stamp({t = 0, v = 1} = {}) {
    this.thump({t, f0: 115, f1: 48, dur: .12, v: .34 * v});
    this.click({t, f: 850, q: .8, dur: .05, v: .22 * v});
    this.smp('ui_paper', {t, v: .1 * v, dur: .07, hp: 1500});
    this.smp('ui_woodf', {t, v: .18 * v, rate: .72});
  }
  tick({t = 0, v = .16, rate = 1.45} = {}) { this.smp('ui_wood', {t, v, rate, hp: 900, dur: .05}); }
  tap({t = 0, v = 1} = {}) { this.smp('ui_wood', {t, v: .22 * v, rate: 1.2}); this.thump({t, f0: 240, f1: 150, dur: .035, v: .1 * v}); }
}

// Recetas: p = prioridad (1 detalle, 2 navegación, 3 acción, 4 hito); gap = separación mínima con otro efecto de igual o
// mayor prioridad. Un efecto que llega justo después de otro más importante se omite, para que nunca se amontonen.
const R = {
  tick: {p: 1, db: 5, gap: .04, fn: (L) => L.tick()},
  tap: {p: 2, db: 3, gap: .05, fn: (L) => L.tap()},
  say: {p: 1, db: 7, fn: (L) => { L.smp('ui_wood', {v: .12, rate: 1.3}); L.click({f: 3500, q: 3, dur: .006, v: .06}); }},
  tab: {p: 1, db: 2, fn: (L, o) => { L.smp('ui_wood', {v: .15, rate: 1.3 + .06 * ((o.i ?? 0) % 6)}); L.smp('ui_paper', {v: .06, hp: 2500, dur: .08}); }},
  page: {p: 1, db: 2, fn: (L) => { L.smp('ui_paper', {v: .1, hp: 1200, dur: .15}); L.tick({t: .01, v: .1}); }},
  nav: {p: 2, fn: (L, o) => { L.smp('ui_paper', {v: .12, hp: 1400, dur: .2}); L.smp('ui_vibe', {m: deg(o.i ?? 0), t: .025, v: .14, dur: .8}); L.tick({v: .1, rate: 1.5}); }},
  drawerClose: {p: 2, fn: (L) => { L.smp('ui_paper', {reverse: true, v: .1, hp: 1400}); L.smp('ui_vibe', {m: A4, t: .08, v: .1, dur: .5}); }},
  open: {p: 2, gap: .14, fn: (L) => { L.sweep({from: 450, to: 2400, dur: .17, v: .045}); L.smp('ui_vibe', {m: D5, t: .03, v: .1, dur: .7}); L.smp('ui_vibe', {m: A5, t: .075, v: .09, dur: .7}); }},
  close: {p: 1, db: 2, gap: .3, fn: (L) => { L.sweep({from: 2200, to: 500, dur: .15, v: .04}); L.smp('ui_vibe', {m: A4, t: .02, v: .08, dur: .45, lp: 3000}); }},
  dismiss: {p: 2, db: 2, gap: .1, fn: (L) => R.close.fn(L)}, // cerrar a propósito (botón o Escape): siempre suena
  focus: {p: 2, db: 4, fn: (L) => { L.sweep({from: 500, to: 1800, dur: .22, v: .04}); L.smp('ui_vibe', {m: E5, t: .1, v: .08, dur: .5}); L.tick({v: .1}); }},
  // confirmaciones y contratos
  confirm: {p: 3, fn: (L) => { L.smp('ui_chime', {m: D5, v: .2}); L.smp('ui_chime', {m: A5, t: .09, v: .16}); L.smp('ui_wood', {v: .14, rate: 1.2}); }},
  contract: {p: 4, db: -2, fn: (L) => { L.stamp(); L.chimes([D5, FS5, A5], {t: .12, step: .08}); }},
  infra: {p: 4, db: -1.5, fn: (L) => { L.stamp(); L.smp('ui_anvil', {t: .05, v: .11, rate: 1.25, hp: 600}); L.chimes([D5, E5, A5], {t: .14, step: .08, v: .16}); }},
  decision: {p: 4, fn: (L) => { L.stamp({v: .8}); L.chimes([A5, D6], {t: .12, step: .1, v: .17}); }},
  plan: {p: 3, fn: (L) => { L.smp('ui_woodf', {v: .16, rate: .9}); L.thump({f0: 140, f1: 70, dur: .08, v: .18}); L.chimes([D5, A5], {t: .06, step: .08, v: .14}); }},
  respond: {p: 3, fn: (L) => { L.smp('ui_woodf', {rate: .85, v: .16}); L.chimes([FS5, D5], {t: .05, step: .09, v: .15}); }},
  request: {p: 4, db: 2, fn: (L) => { L.smp('ui_chime', {m: D5, v: .2}); L.smp('ui_chime', {m: A5, t: .09, v: .17}); L.smp('ui_shimmer', {k: 0, t: .12, v: .07, hp: 2000}); L.tap({v: .7}); }},
  celebrate: {p: 4, gap: .3, fn: (L) => { L.chimes([D5, FS5, A5, D6], {step: .085, v: .2}); L.smp('ui_shimmer', {k: 0, t: .1, v: .09, hp: 1500}); L.smp('ui_finger', {t: .34, v: .07, hp: 1000}); }},
  sell: {p: 3, db: -2, fn: (L) => { L.stamp({v: .7}); L.smp('ui_vibe', {m: A5, t: .1, v: .12}); L.smp('ui_vibe', {m: E5, t: .2, v: .11}); }},
  refurbish: {p: 3, db: 2, fn: (L) => { L.smp('ui_anvil', {v: .1, rate: 1.4, hp: 700}); L.thump({f0: 160, f1: 80, dur: .07, v: .14}); L.smp('ui_chime', {m: D5, t: .1, v: .15}); }},
  borrow: {p: 3, fn: (L) => { L.smp('ui_tri', {k: 1, v: .07, rate: 1.1}); L.chimes([D5, A5], {t: .03, step: .08, v: .15}); L.smp('ui_paper', {t: .02, v: .06, hp: 2000, dur: .12}); }},
  repay: {p: 3, fn: (L) => { L.smp('ui_paper', {v: .07, hp: 2000, dur: .12}); L.chimes([A5, D5], {t: .02, step: .09, v: .14}); L.thump({t: .1, f0: 130, f1: 70, dur: .07, v: .1}); }},
  closeService: {p: 3, db: 2.5, fn: (L) => { L.click({f: 3200, dur: .008, v: .13}); L.click({t: .03, f: 1400, dur: .012, v: .16}); L.smp('ui_vibe', {m: A5, t: .06, v: .1}); L.smp('ui_vibe', {m: D5, t: .15, v: .1, lp: 3500}); }},
  openRoute: {p: 3, db: -1, fn: (L) => { [0, 2, 4].forEach((d, k) => L.smp('ui_vibe', {m: deg(d), t: k * .045, v: .1 + k * .01, dur: .5})); L.smp('ui_chime', {m: D5, t: .14, v: .15}); }},
  // frecuencia: la altura sigue al número de trenes
  plus: {p: 3, gap: .05, fn: (L, o) => { const k = Math.round((o.level ?? .5) * 5); L.smp('ui_vibe', {m: deg(k), v: .14, dur: .5}); L.smp('ui_vibe', {m: deg(k + 1), t: .065, v: .16, dur: .6}); L.tick({v: .1, rate: 1.4}); }},
  minus: {p: 3, gap: .05, fn: (L, o) => { const k = Math.round((o.level ?? .5) * 5); L.smp('ui_vibe', {m: deg(k + 1), v: .14, dur: .5}); L.smp('ui_vibe', {m: deg(k), t: .065, v: .13, dur: .6, lp: 4000}); L.tick({v: .1, rate: 1.2}); }},
  // interruptores y palancas
  toggleOn: {p: 3, db: 4, fn: (L) => { L.click({f: 1700, q: 1.5, dur: .01, v: .18}); L.click({t: .03, f: 3200, dur: .008, v: .13}); L.smp('ui_vibe', {m: A5, t: .035, v: .08, dur: .4}); }},
  toggleOff: {p: 3, db: 6, fn: (L) => { L.click({f: 3200, dur: .008, v: .13}); L.click({t: .03, f: 1400, dur: .012, v: .16}); L.thump({t: .03, f0: 170, f1: 110, dur: .05, v: .07}); }},
  lever: {p: 3, fn: (L, o) => { L.thump({f0: 150, f1: 85, dur: .07, v: .16}); L.click({f: 2400, q: 2.5, dur: .01, v: .1}); L.smp('ui_tri', {k: 0, t: .01, v: .05, rate: .85, hp: 1500}); L.smp('ui_vibe', {m: deg((o.i ?? 0) * 2), t: .05, v: .09, dur: .5}); }},
  speed: {p: 3, db: 4, gap: .05, fn: (L, o) => { const n = (o.i ?? 0) + 1; for (let k = 0; k < n; k++) L.click({t: k * .05, f: 1900 + 350 * k, q: 3, dur: .008, v: .13}); L.smp('ui_vibe', {m: deg(n + 1), t: n * .05, v: .08, dur: .35}); }},
  // la jornada
  departure: {p: 4, db: 2, gap: .5, fn: (L) => { L.chimes([D5, FS5, A5], {step: .3, v: .21, dur: 1.6}); L.horn({t: 1.0, v: .045, dur: .6}); }},
  resume: {p: 3, db: 1, fn: (L) => { L.smp('ui_vibe', {m: D5, v: .12}); L.smp('ui_vibe', {m: A5, t: .06, v: .12}); L.tick({v: .09}); }},
  pause: {p: 3, db: 3, fn: (L) => { L.smp('ui_vibe', {m: A5, v: .1}); L.smp('ui_vibe', {m: D5, t: .06, v: .09, lp: 2500}); L.tick({v: .09, rate: 1.1}); }},
  dayEnd: {p: 4, db: 2.5, gap: .5, fn: (L) => L.chimes([A5, FS5, D5], {step: .26, v: .19, dur: 1.6})},
  dayNext: {p: 4, db: 4.5, fn: (L) => { const end = L.flap({n: 16}); L.chimes([D5, A5], {t: end + .03, step: .08, v: .13}); }},
  skipMonth: {p: 4, db: 3, fn: (L) => { L.smp('ui_paper', {v: .12, hp: 1000}); const end = L.flap({t: .08, n: 28, from: .018, to: .045}); L.chimes([D5, FS5, A5], {t: end + .03, step: .07, v: .14}); }},
  timetable: {p: 2, db: 6, fn: (L) => L.flap({n: 7, v: .08})},
  // mapa
  pickCity: {p: 2, fn: (L, o) => { L.smp('ui_woodf', {v: .14, rate: .95}); L.smp('ui_vibe', {m: deg((o.i ?? 0) % 7), t: .02, v: .12, dur: .6}); }},
  pickTrain: {p: 2, db: 4, fn: (L) => { L.click({f: 2600, q: 3, dur: .008, v: .22}); L.click({t: .022, f: 2600, q: 3, dur: .008, v: .18}); L.smp('ui_tri', {k: 1, t: .02, v: .1, rate: 1.25, hp: 2000, dur: .3}); L.smp('ui_vibe', {m: 88, t: .03, v: .07, dur: .35}); }},
  pickStation: {p: 2, db: 1, fn: (L) => { L.smp('ui_wood', {v: .18, rate: .82}); L.smp('ui_chime', {m: D5, t: .02, v: .1, dur: .7}); }},
  pickRoute: {p: 2, db: -2, fn: (L) => [0, 2, 4].forEach((d, k) => L.smp('ui_vibe', {m: deg(d), t: k * .045, v: .1 + k * .01, dur: .5}))},
  pickWork: {p: 2, db: 7.5, fn: (L) => { L.smp('ui_anvil', {v: .09, rate: 1.5, hp: 800}); L.tick({v: .1, rate: 1.1}); }},
  deselect: {p: 1, db: 7, fn: (L) => L.tick({v: .08, rate: 1.6})},
  zoomIn: {p: 1, db: 8, gap: .06, fn: (L) => { L.sweep({from: 700, to: 2200, dur: .09, v: .035}); L.tick({v: .1, rate: 1.6}); }},
  zoomOut: {p: 1, db: 7, gap: .06, fn: (L) => { L.sweep({from: 2200, to: 700, dur: .09, v: .035}); L.tick({v: .1, rate: 1.15}); }},
  resetMap: {p: 2, db: 3, fn: (L) => { L.sweep({from: 2600, to: 380, dur: .26, v: .045}); L.smp('ui_vibe', {m: A4, t: .12, v: .08}); }},
  scrub: {p: 1, db: 7, gap: .05, fn: (L) => L.smp('ui_wood', {v: .09, rate: 1.8, hp: 1500, dur: .035})},
  // controles de formulario
  slider: {p: 1, db: 6, gap: 0, fn: (L, o) => L.smp('ui_wood', {v: .09, rate: 2 ** (((o.x ?? .5) * 14 - 6) / 12), hp: 700, dur: .04})},
  select: {p: 1, db: 4, fn: (L) => { L.tick(); L.smp('ui_vibe', {m: FS5, t: .01, v: .06, dur: .3}); }},
  // banda sonora, tutorial y partida
  musicPick: {p: 3, db: 2, fn: (L) => { [D5, FS5, A5].forEach((m, k) => L.smp('ui_vibe', {m, t: k * .025, v: .09, dur: .7})); L.tick({v: .08}); }},
  musicNext: {p: 2, db: 5, fn: (L) => { L.tick(); L.tick({t: .05, rate: 1.7}); L.sweep({from: 900, to: 2600, dur: .12, v: .03}); }},
  tutorialNext: {p: 2, db: 2, fn: (L, o) => { L.smp('ui_paper', {v: .07, hp: 2000, dur: .1}); L.smp('ui_vibe', {m: deg((o.i ?? 0) % 7), t: .02, v: .11, dur: .6}); }},
  tutorialStart: {p: 3, db: 4, fn: (L) => { L.sweep({from: 450, to: 2400, dur: .17, v: .045}); L.chimes([D5, A5], {t: .08, step: .1, v: .15}); }},
  begin: {p: 4, gap: .5, fn: (L) => { L.chimes([D5, FS5, A5, D6], {step: .09, v: .2, dur: 1.8}); L.smp('ui_shimmer', {k: 0, t: .15, v: .1, hp: 1500}); L.horn({t: 1.05, v: .04, dur: .7}); }},
  continue: {p: 4, db: 2, gap: .4, fn: (L) => { L.chimes([D5, A5], {step: .12, v: .19}); L.smp('ui_shimmer', {k: 0, t: .1, v: .07, hp: 2000}); }},
  observe: {p: 3, db: 4, fn: (L) => { L.sweep({from: 500, to: 1800, dur: .22, v: .04}); L.smp('ui_chime', {m: A5, t: .1, v: .14}); }},
  punch: {p: 3, db: 5.5, fn: (L) => { L.click({f: 1050, q: 1.2, dur: .016, v: .22}); L.thump({f0: 320, f1: 160, dur: .03, v: .1}); L.click({t: .045, f: 4300, q: 3, dur: .02, v: .15}); L.smp('ui_tri', {k: 0, t: .05, v: .05}); L.smp('ui_chime', {m: D6, t: .13, v: .1, dur: .9}); }},
  export: {p: 3, db: 3, fn: (L) => { L.smp('ui_paper', {v: .12, hp: 1200}); L.smp('ui_paper', {t: .08, v: .1, hp: 1600}); R.punch.fn(new Layers(L.bus, L.t0 + .14, L.k, L.tr), {}); }},
  error: {p: 4, db: 1, gap: .25, fn: (L) => { L.smp('ui_wood', {v: .2, rate: .6}); L.smp('ui_wood', {t: .11, v: .17, rate: .56}); L.smp('ui_vibe', {m: 68, fixed: true, v: .1, lp: 1600, dur: .3}); L.smp('ui_vibe', {m: 67, fixed: true, t: .11, v: .1, lp: 1600, dur: .4}); }}, // segunda menor grave: un «no» suave, sin transportar
};
export const RECIPES = R;

// Qué suena al pulsar cada data-action del juego:
//  'nombre' → ese efecto al pulsar · '=nombre' → ese efecto si la acción sale bien (si falla, «error»)
//  '@open' / '@close' → lo pone el propio diálogo al abrirse o cerrarse · '!…' → depende del estado (se decide en app.js)
export const ACTIONS = {
  navigate: 'nav', 'close-drawer': 'drawerClose', 'close-inspector': 'dismiss', 'close-modal': '@close',
  begin: 'begin', continue: 'continue', observe: 'observe', decision: '=decision', claim: '=celebrate',
  play: '!play', speed: 'speed', 'day-start': '!play', 'day-end': 'dayEnd', 'day-review': '@open', 'day-next': '=dayNext', 'skip-month': '=skipMonth',
  'open-incidents': 'nav', respond: '=respond', route: 'pickRoute', city: 'pickCity', 'freq-up': '=plus', 'freq-down': '=minus',
  'open-route': '=openRoute', request: '=request', 'station-up': '=celebrate', music: '@open', 'music-play': 'musicPick', 'music-toggle': '!toggle',
  'voice-toggle': '!toggle', 'sfx-toggle': '!toggle', say: 'say', 'music-next': 'musicNext', 'tutorial-next': 'tutorialNext', 'tutorial-skip': 'dismiss',
  'tutorial-start': 'tutorialStart', 'route-zoom': 'focus', 'route-trips': 'timetable', 'route-tab': 'tab', 'network-zoom': 'focus', 'open-network': '=openRoute',
  train: 'pickTrain', station: 'pickStation', 'station-map': 'focus', 'station-timetable': 'timetable', 'tt-type': 'tab', 'tt-station': 'timetable',
  'real-trip': 'pickTrain', follow: '!toggle', layer: 'lever', 'visit-work': 'focus', 'close-service': '=closeService', upgrade: '=infra', 'fleet-tab': 'tab',
  'fleet-detail': '@open', refurbish: '=refurbish', sell: '=sell', 'train-record': '@open', 'market-tab': 'tab', purchase: '@open', 'confirm-buy': '=contract',
  project: '@open', 'confirm-project': '=infra', 'new-line': '@open', 'confirm-line': '=infra', borrow: '=borrow', repay: '=repay', 'archive-tab': 'tab',
  license: '@open', 'save-dialog': '@open', help: '@open', 'save-now': 'punch', export: 'export', 'new-game': '@open',
};

/** Motor de efectos: comparte el contexto de audio de la banda sonora pero tiene su propio volumen. */
export class Sfx {
  constructor(music) {
    this.music = music; this.ctx = null; this.bus = null; this.log = []; this.last = {t: -1, p: 0}; this.intent = null; this.armed = false; this.slideAt = 0; this.skipped = []; this.tr = 0;
    music.on?.(() => { this.tr = keyOf(music.current?.song); }); // los efectos se afinan con la pieza que suena
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('iberia-efectos') || '{}'); } catch {}
    this.volume = saved.volume ?? .7; this.enabled = saved.enabled ?? true;
    // las muestras de los efectos se piden (versión web) y se decodifican ya, en un contexto fuera de línea, para que
    // el primer clic suene completo (los búferes decodificados sirven luego en el contexto real)
    const warm = () => { try { return loadInstruments(new OfflineAudioContext(1, 1, 44100), UI_SAMPLES); } catch { return null; } };
    if (typeof OfflineAudioContext !== 'undefined') prefetchInstruments(UI_SAMPLES).then(warm).catch(() => {});
  }
  save() { try { localStorage.setItem('iberia-efectos', JSON.stringify({volume: this.volume, enabled: this.enabled})); } catch {} }
  /** Se arma con el primer gesto del jugador (los navegadores no dejan sonar antes). */
  arm() { this.armed = true; this.init(); }
  init() {
    if (this.bus) return true;
    if (!this.armed) return false;
    this.music.init?.();
    if (!this.music.ctx) return false;
    this.attach(this.music.ctx, this.music.ctx.destination);
    loadInstruments(this.ctx, UI_SAMPLES);
    return true;
  }
  /** Prepara el bus de efectos en un contexto: volumen → compresor suave → salida, con un envío a una sala pequeña. */
  attach(ctx, dest) {
    this.ctx = ctx;
    const out = ctx.createGain(), comp = ctx.createDynamicsCompressor(), dry = ctx.createGain(), send = ctx.createGain(), hp = ctx.createBiquadFilter(), rev = ctx.createConvolver();
    out.gain.value = this.enabled ? this.volume * MAKEUP : 0;
    comp.threshold.value = -18; comp.ratio.value = 3; comp.attack.value = .003; comp.release.value = .15;
    hp.type = 'highpass'; hp.frequency.value = 300; rev.buffer = hallIR(ctx, 1.2, [.9, .7, .4], .012, [7, 11, 17, 23, 29, 37]); send.gain.value = .22;
    dry.connect(out); dry.connect(send); send.connect(hp); hp.connect(rev); rev.connect(out); out.connect(comp); comp.connect(dest);
    this.bus = {ctx, out, dry, send, missing: {}};
    return this.bus;
  }
  setVolume(v) { this.volume = v; if (this.bus) this.bus.out.gain.setTargetAtTime(this.enabled ? v * MAKEUP : 0, this.ctx.currentTime, .05); this.save(); }
  /** Muestras que aún no estaban listas cuando sonó un efecto (se tocó su sustituto sintetizado). */
  get missing() { return this.bus?.missing || {}; }
  /** Activa o silencia los efectos; al silenciar deja terminar el clic del propio interruptor. */
  toggle() {
    this.enabled = !this.enabled;
    if (this.bus) { const g = this.bus.out.gain, now = this.ctx.currentTime; g.cancelScheduledValues(now); if (this.enabled) g.setValueAtTime(this.volume * MAKEUP, now); else g.setTargetAtTime(0, now + .25, .05); }
    this.save(); return this.enabled;
  }
  /** Suena un efecto ahora (o en `at` segundos del contexto). Devuelve si ha sonado. */
  play(name, o = {}, at = null) {
    const r = R[name];
    if (!r || !this.enabled || !this.init()) return false;
    const ctx = this.ctx;
    if (ctx.state === 'suspended' && !ctx.startRendering) ctx.resume();
    const now = at ?? ctx.currentTime, p = r.p ?? 2;
    if (at === null && now - this.last.t < (r.gap ?? .12) && p <= this.last.p) { this.skipped.push(name); if (this.skipped.length > 300) this.skipped.shift(); return false; }
    if (at === null) this.last = {t: now, p};
    this.log.push(name); if (this.log.length > 300) this.log.shift();
    r.fn(new Layers(this.bus, now + .004, 10 ** ((r.db || 0) / 20), this.tr), o);
    return true;
  }
  /** Deslizadores y casillas numéricas: un tic de detención cuya altura sigue al valor (como mucho uno cada 45 ms). */
  slide(el) {
    if (!this.ctx || this.ctx.currentTime - this.slideAt < .045) return;
    const min = +el.min || 0, max = +el.max || 1, x = max > min ? (+el.value - min) / (max - min) : .5;
    if (this.play('slider', {x: Math.max(0, Math.min(1, x))})) this.slideAt = this.ctx.currentTime;
  }
  /** Efecto que debe sonar solo si la acción en curso sale bien (lo resuelve result()). */
  expect(name, o = {}) { this.intent = [name, o]; }
  result(ok) {
    const i = this.intent; this.intent = null;
    if (!ok) return this.play('error');
    if (i) this.play(i[0], typeof i[1] === 'function' ? i[1]() : i[1]);
  }
}
