// Banda sonora original de Iberia Ferroviaria, sintetizada en tiempo real con Web Audio.
// Doce piezas en dos familias de estilo:
//  · «Estación» (preparación y menús): bossa nova, jazz ligero, vals, pop y lounge.
//  · «Red» (jornadas): ambiental orquestal-electrónica de día y piezas nocturnas.
// Melodías, armonías y arreglos son composiciones originales de este proyecto.

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

// ------------------------------------------------------------ instrumentos
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

const INSTR = {
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

// ------------------------------------------------------------ estilos de acompañamiento
// Cada estilo recibe un compás con sus acordes y añade eventos (en pulsos).
const STYLES = {
  bossa(bar, chords, add, sec) {
    const pattern = bar % 2 ? [.5, 2, 3.5] : [0, 1.5, 3];
    for (const p of pattern) { const c = at(chords, p); voicing(c.c, 53).forEach(n => add(sec.comp || 'epiano', p, n, .45, .42)); }
    for (const c of chords) { add('bass', c.start, bassNote(c.c), 1.4, .8); if (c.len >= 2) add('bass', c.start + 1.5, fifth(c.c), .45, .6); if (c.len >= 4) { add('bass', c.start + 2, bassNote(c.c), 1.4, .75); add('bass', c.start + 3.5, fifth(c.c), .45, .55); } }
    if (!sec.light) { (bar % 2 ? [1, 2.5] : [0, 1.5, 3]).forEach(p => add('rim', p, 0, .1, .45)); for (let p = 0; p < 4; p += .5) add('shaker', p, 0, .1, p % 1 ? .5 : .3); add('kick', 0, 0, .1, .35); add('kick', 2, 0, .1, .3); }
    if (sec.pad) chords.forEach(c => voicing(c.c, 60, false).forEach(n => add('strings', c.start, n, c.len, .35, {attack: .6})));
  },
  swing(bar, chords, add, sec, next) {
    for (const c of chords) { const v = voicing(c.c, 52); v.forEach(n => add('piano', c.start, n, .6, .35)); if (c.len >= 2) v.forEach(n => add('piano', c.start + 1.5, n, .3, .3)); }
    const beats = [];
    for (const c of chords) for (let b = 0; b < c.len; b++) beats.push({c: c.c, b, last: b === c.len - 1});
    beats.forEach((x, i) => {
      const nextRoot = i + 1 < beats.length ? beats[i + 1].c : next || x.c;
      let n = x.b === 0 ? bassNote(x.c, 34) : x.last ? bassNote(nextRoot, 34) + (i % 2 ? -1 : 1) : x.b === 1 ? third(x.c, 34) : fifth(x.c, 34);
      add('bass', i, n, .9, .75);
    });
    if (!sec.light) { [0, 1, 1.5, 2, 3, 3.5].forEach(p => add('hat', p, 0, .4, p % 1 ? .35 : .55)); [1, 3].forEach(p => add('hat', p, 0, .05, .5)); [0, 1, 2, 3].forEach(p => add('brush', p, 0, .2, .3)); add('kick', 0, 0, .1, .2); }
    if (sec.pad) chords.forEach(c => voicing(c.c, 60, false).forEach(n => add('pad', c.start, n, c.len, .4, {attack: .5, bright: true})));
  },
  waltz(bar, chords, add, sec) {
    const c = chords[0];
    add('bass', 0, bar % 2 ? fifth(c.c, 36) : bassNote(c.c, 36), .9, .8);
    [1, 2].forEach(p => voicing(at(chords, p).c, 55).forEach(n => add('piano', p, n, .4, .32)));
    if (!sec.light) { add('hat', 0, 0, .05, .3); add('shaker', 1, 0, .05, .25); add('shaker', 2, 0, .05, .25); }
    if (sec.pad) chords.forEach(cc => voicing(cc.c, 62, false).forEach(n => add('strings', cc.start, n, cc.len, .3, {attack: .4})));
  },
  pop(bar, chords, add, sec) {
    for (const p of [0, 1, 1.5, 2.5, 3]) voicing(at(chords, p).c, 55).forEach(n => add('piano', p, n, .4, .3));
    for (const c of chords) { add('bass', c.start, bassNote(c.c), .9, .8); if (c.len >= 2) add('bass', c.start + 1.5, bassNote(c.c), .45, .6); if (c.len >= 4) { add('bass', c.start + 2, fifth(c.c), .9, .7); add('bass', c.start + 3, bassNote(c.c) + 12, .45, .6); add('bass', c.start + 3.5, fifth(c.c), .45, .55); } }
    if (!sec.light) { add('kick', 0, 0, .1, .6); add('kick', 2.5, 0, .1, .45); add('clap', 1, 0, .1, .45); add('clap', 3, 0, .1, .45); for (let p = 0; p < 4; p += .5) add('hat', p, 0, .05, p % 1 ? .45 : .25); }
    if (sec.pad) chords.forEach(c => voicing(c.c, 64, false).forEach(n => add('strings', c.start, n, c.len, .3, {attack: .3})));
  },
  ambient(bar, chords, add, sec) {
    for (const c of chords) {
      voicing(c.c, 48, false).forEach(n => add('pad', c.start, n, c.len, .45));
      add('sub', c.start, bassNote(c.c, 33), c.len, .6);
      const tones = voicing(c.c, 60, false), arp = [...tones, ...tones.map(n => n + 12)];
      for (let p = 0; p < c.len; p += .5) { const k = Math.round(p * 2); add('piano', c.start + p, arp[(bar % 2 ? arp.length - 1 - (k % arp.length) : k % arp.length)], .5, .14, {del: .35, rev: .5}); }
      if (sec.pad) voicing(c.c, 67, false).forEach(n => add('strings', c.start, n, c.len, .3, {attack: 1.4}));
    }
    if (!sec.light) { add('kick', 0, 0, .1, .28); for (let p = .5; p < 4; p += 1) add('hat', p, 0, .05, .14); }
  },
  drive(bar, chords, add, sec) {
    for (const c of chords) {
      const r = bassNote(c.c, 48) + 12, f = r + 7, t = voicing(c.c, r, false)[0] || r + 4, seq = [r, f, r + 12, f, t, f, r + 12, f];
      for (let p = 0; p < c.len; p += .5) add('pluck', c.start + p, seq[Math.round(p * 2) % 8], .4, .32, {del: .25, short: true});
      voicing(c.c, 52, false).forEach(n => add('pad', c.start, n, c.len, .4, {attack: .4, bright: true}));
      for (let p = 0; p < c.len; p += .5) add('synthbass', c.start + p, bassNote(c.c, 36), .4, p % 1 ? .4 : .55);
      if (sec.pad) add('bell', c.start, voicing(c.c, 76, false).at(-1), 1, .5);
    }
    if (!sec.light) { (sec.pad ? [0, 1, 2, 3] : [0, 2]).forEach(p => add('kick', p, 0, .1, .5)); if (sec.pad) [1, 3].forEach(p => add('clap', p, 0, .1, .4)); for (let p = .5; p < 4; p += 1) add('hat', p, 0, .05, .4); }
  },
  night(bar, chords, add, sec) {
    for (const c of chords) {
      voicing(c.c, 52).forEach(n => add('epiano', c.start, n, c.len * .95, .38, {trem: true, del: .2}));
      add('sub', c.start, bassNote(c.c, 33), c.len, .55);
      if (sec.pad) voicing(c.c, 60, false).forEach(n => add('pad', c.start, n, c.len, .35, {attack: 2}));
    }
    if (!sec.light) { add('kick', 0, 0, .1, .3); add('rim', 2, 0, .1, .4); for (let p = .5; p < 4; p += 1) add('hat', p, 0, .05, .18); if (sec.pad) add('kick', 2.5, 0, .1, .2); }
  },
  lounge(bar, chords, add, sec) {
    for (const p of [0, 1.5, 2.5, 3.5]) voicing(at(chords, p).c, 53).forEach(n => add('epiano', p, n, p % 1 ? .4 : .8, .34));
    for (const p of [.5, 1.5, 2.5, 3.5]) { const c = at(chords, p).c; add('pluck', p, voicing(c, 60)[1], .2, .22, {short: true}); }
    for (const c of chords) { add('bass', c.start, bassNote(c.c), 1.4, .8); if (c.len >= 2) add('bass', c.start + 1.5, fifth(c.c), .45, .6); if (c.len >= 4) { add('bass', c.start + 2.5, bassNote(c.c) + 12, .45, .55); add('bass', c.start + 3.5, fifth(c.c), .45, .5); } }
    if (!sec.light) { add('kick', 0, 0, .1, .45); add('kick', 2.5, 0, .1, .35); add('rim', 1, 0, .1, .4); add('rim', 3, 0, .1, .4); for (let p = 0; p < 4; p += .5) add('hat', p, 0, .05, p % 1 ? .3 : .18); }
    if (sec.pad) chords.forEach(c => voicing(c.c, 62, false).forEach(n => add('pad', c.start, n, c.len, .3, {attack: .8, bright: true})));
  },
};
function at(chords, p) { return chords.reduce((best, c) => (c.start <= p ? c : best), chords[0]); }

// ------------------------------------------------------------ las doce piezas
// Melodía: «nota:pulsos», «-:pulsos» para silencio. Acordes por compás («Gm7 C9» divide el compás).
export const SONGS = [
  {id: 'anden1', title: 'Andén 1', family: 'estacion', mood: 'any', style: 'bossa', bpm: 128, meter: 4, lead: ['flute', 'vibes'],
    A: {chords: ['Fmaj7', 'Gm7 C9', 'Fmaj7', 'Am7 D7b9', 'Gm7', 'C9', 'Fmaj7', 'Gm7 C7'],
      mel: 'A4:1.5 C5:.5 E5:1 D5:1 D5:1.5 Bb4:.5 G4:1 E5:1 F5:2 E5:.5 D5:.5 C5:1 E5:1.5 C5:.5 F#5:1 Eb5:1 D5:1.5 Bb4:.5 A4:.5 G4:.5 F4:1 G4:1 A4:.5 Bb4:.5 D5:2 C5:3 -:1 Bb4:1 A4:1 G4:1 E4:1'},
    B: {chords: ['Bbmaj7', 'Bbm6 Eb9', 'Am7', 'D9', 'Gm7', 'C13', 'Fmaj9', 'Gm7 C7'],
      mel: 'D5:1 F5:1 A5:2 G5:1.5 F5:.5 Db5:2 C5:1 E5:1 G5:1.5 E5:.5 F#5:2 E5:1 D5:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 D5:1 Bb4:1 A4:1 G4:1 A4:2 -:2 C5:1 E5:1'}},
  {id: 'primera', title: 'Primera salida', family: 'red', mood: 'day', style: 'ambient', bpm: 84, meter: 4, lead: ['piano', 'bell'],
    A: {chords: ['Dmaj9', 'Bm11', 'Gmaj7', 'A6', 'Dmaj9', 'F#m7', 'Gmaj9', 'Asus4 A'],
      mel: 'F#5:2 A5:1 E5:1 D5:3 -:1 B4:1 D5:1 F#5:2 E5:3 C#5:1 F#5:2 A5:1 B5:1 A5:2 C#6:1 A5:1 B5:2 F#5:2 E5:4'},
    B: {chords: ['Bm9', 'Gmaj7', 'Dmaj7/F#', 'Em9', 'Bm9', 'Gmaj9', 'Em7', 'Asus4'],
      mel: 'D6:2 C#6:1 B5:1 A5:3 -:1 A5:1 F#5:1 D5:2 E5:2 G5:1 F#5:1 D6:2 E6:1 F#6:1 E6:2 D6:1 B5:1 G5:2 B5:1 A5:1 A5:3 -:1'}},
  {id: 'verano', title: 'Horario de verano', family: 'estacion', mood: 'any', style: 'pop', bpm: 112, meter: 4, lead: ['marimba', 'flute'],
    A: {chords: ['C', 'G/B', 'Am7', 'F', 'C/E', 'Dm7', 'F G', 'C'],
      mel: 'E5:.5 G5:.5 C6:1 B5:.5 A5:.5 G5:1 G5:.5 D5:.5 G5:1 F5:.5 E5:.5 D5:1 C5:.5 E5:.5 A5:1 G5:.5 E5:.5 C5:1 A4:.5 C5:.5 F5:1.5 E5:.5 D5:1 E5:.5 G5:.5 C6:1 D6:.5 C6:.5 G5:1 F5:1 A5:1 D5:1.5 E5:.5 F5:1 A5:1 G5:1 B5:1 C6:3 -:1'},
    B: {chords: ['Am', 'Em', 'F', 'C', 'Dm7', 'G', 'Em7 A7', 'Dm7 G7'],
      mel: 'A5:1.5 G5:.5 E5:2 G5:1.5 F5:.5 E5:2 F5:1 A5:1 C6:1 A5:1 G5:3 E5:1 F5:1.5 E5:.5 D5:1 C5:1 B4:1 D5:1 G5:2 G5:1 E5:1 C#5:1 E5:1 F5:1 D5:1 B4:1 G4:1'}},
  {id: 'vialibre', title: 'Vía libre', family: 'red', mood: 'day', style: 'drive', bpm: 118, meter: 4, lead: ['strings', 'flute'],
    A: {chords: ['Em9', 'Cmaj7', 'G', 'D/F#', 'Em9', 'Cmaj9', 'Am7', 'Dsus4 D'],
      mel: 'B4:3 G4:1 E5:4 D5:3 B4:1 A4:4 B4:2 E5:2 G5:3 F#5:1 E5:2 C5:2 D5:4'},
    B: {chords: ['Cmaj7', 'G/B', 'Am7', 'Em7', 'Cmaj7', 'D', 'Bm7', 'Em'],
      mel: 'G5:2 E5:1 G5:1 D6:3 B5:1 C6:2 B5:1 A5:1 G5:4 E5:2 G5:2 A5:2 F#5:1 D5:1 B5:2 A5:1 F#5:1 E5:4'}},
  {id: 'tarifa', title: 'Tarifa reducida', family: 'estacion', mood: 'any', style: 'swing', swing: true, bpm: 136, meter: 4, lead: ['vibes', 'piano'],
    A: {chords: ['Bbmaj7', 'G7', 'Cm7', 'F7', 'Dm7 G7', 'Cm7 F7', 'Bbmaj7 G7', 'Cm7 F7'],
      mel: 'D5:1 F5:.5 G5:.5 A5:1 F5:1 B5:1.5 A5:.5 G5:1 F5:1 Eb5:1 G5:.5 Bb5:.5 C6:1 Bb5:1 A5:2 F5:1 -:1 F5:.5 G5:.5 A5:1 B5:1 D6:1 C6:.5 Bb5:.5 G5:1 A5:1 Eb5:1 D5:2 B4:1 D5:1 C5:1 Eb5:1 A4:1 -:1'},
    B: {chords: ['D7', 'D7', 'G7', 'G7', 'C7', 'C7', 'F7', 'F7'],
      mel: 'F#5:1 A5:1 C6:2 A5:.5 F#5:.5 D5:1 -:2 B4:1 D5:1 F5:2 G5:.5 F5:.5 D5:1 -:2 E5:1 G5:1 Bb5:2 G5:.5 E5:.5 C5:1 -:2 A4:1 C5:1 Eb5:2 F5:2 -:2'}},
  {id: 'medianoche', title: 'Talgo a medianoche', family: 'red', mood: 'night', style: 'night', bpm: 72, meter: 4, lead: ['vibes', 'flute'],
    A: {chords: ['Am9', 'Fmaj7', 'Dm9', 'E7sus4 E7', 'Am9', 'Cmaj7', 'Fmaj7', 'E7sus4 E7'],
      mel: 'E5:2 C5:1 B4:1 A4:3 -:1 F5:2 E5:1 D5:1 E5:3 -:1 G5:2 E5:1 C5:1 D5:1 E5:1 G5:2 A5:2 C6:1 A5:1 G#5:3 -:1'},
    B: {chords: ['Dm9', 'G13', 'Cmaj9', 'Fmaj7', 'Bm7b5', 'E7b9', 'Am9', 'Am9'],
      mel: 'A5:2 F5:1 E5:1 F5:3 -:1 E5:1 G5:1 B5:2 A5:3 -:1 D5:2 F5:1 A5:1 G#5:2 F5:1 D5:1 C5:2 B4:1 A4:1 A4:3 -:1'}},
  {id: 'norte', title: 'Estación del Norte', family: 'estacion', mood: 'any', style: 'waltz', bpm: 150, meter: 3, lead: ['clarinet', 'flute'], form: ['intro', 'A', 'A2', 'B', 'A', 'B2', 'A2', 'B', 'A', 'B2', 'A2', 'outro'],
    A: {chords: ['G', 'Em', 'Am7', 'D7', 'G', 'B7', 'Em', 'A7 D7'],
      mel: 'D5:2 B4:1 G5:2 E5:1 C5:2 E5:1 F#5:2 D5:1 B5:2 G5:1 F#5:1 D#5:1 B4:1 E5:2 G5:1 C#5:1.5 F#5:1.5'},
    B: {chords: ['C', 'G', 'Am', 'D', 'C', 'G/B', 'Am7 D7', 'G'],
      mel: 'E5:1 G5:1 C6:1 B5:2 D5:1 C5:1 E5:1 A5:1 F#5:2 A5:1 G5:1 E5:1 C5:1 D5:2 G5:1 A5:1.5 F#5:1.5 G5:3'}},
  {id: 'mediterraneo', title: 'Corredor Mediterráneo', family: 'red', mood: 'day', style: 'drive', bpm: 104, meter: 4, lead: ['strings', 'bell'],
    A: {chords: ['Bb', 'F/A', 'Gm7', 'Ebmaj7', 'Bb/D', 'Ebmaj9', 'Cm7', 'F'],
      mel: 'D5:2 F5:2 C5:3 F4:1 Bb4:2 D5:2 G5:3 -:1 F5:2 Bb5:2 G5:2 F5:1 Eb5:1 Eb5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Gm', 'Ebmaj7', 'Bb', 'F', 'Gm', 'Eb', 'Cm7', 'F'],
      mel: 'Bb5:2 A5:1 G5:1 G5:3 Bb5:1 F5:2 D5:2 C5:4 D5:1 Eb5:1 F5:1 G5:1 G5:2 Bb5:2 Eb6:2 D6:1 C6:1 C6:4'}},
  {id: 'ancho', title: 'Cambio de ancho', family: 'estacion', mood: 'any', style: 'lounge', bpm: 96, meter: 4, lead: ['vibes', 'flute'],
    A: {chords: ['Ebmaj7', 'Cm7', 'Fm7', 'Bb7', 'Gm7', 'C7b9', 'Fm7', 'Bb7sus4 Bb7'],
      mel: 'G5:1.5 Bb5:.5 D6:1 C6:1 Bb5:1.5 G5:.5 Eb5:2 Ab5:1 G5:.5 F5:.5 C5:1 Ab4:1 D5:2 F5:1 -:1 Bb4:1 D5:1 F5:1 A5:1 G5:1.5 E5:.5 Db5:1 Bb4:1 Ab4:1 C5:1 Eb5:1 Ab5:1 G5:2 F5:2'},
    B: {chords: ['Abmaj7', 'Gm7', 'Fm7', 'Ebmaj7', 'Dm7b5', 'G7b9', 'Cm7', 'F7 Bb7'],
      mel: 'C6:1.5 Bb5:.5 G5:2 Bb5:1.5 F5:.5 D5:2 Ab5:1 G5:1 F5:1 Eb5:1 G5:3 -:1 F5:1 Ab5:1 C6:2 B5:1.5 Ab5:.5 F5:2 Eb5:1 G5:1 Bb5:1 G5:1 A5:2 Ab5:2'}},
  {id: 'meseta', title: 'Atardecer en la meseta', family: 'red', mood: 'dusk', style: 'ambient', bpm: 76, meter: 4, lead: ['piano', 'strings'],
    A: {chords: ['Fmaj7#11', 'C/E', 'Dm9', 'Bbmaj7', 'Fmaj7', 'Am7', 'Bbmaj9', 'Csus4 C'],
      mel: 'A5:2 C6:1 B5:1 G5:4 F5:2 A5:1 E5:1 D5:4 C5:1 F5:1 A5:2 G5:2 E5:2 F5:2 D5:1 C5:1 C5:4'},
    B: {chords: ['Dm7', 'Bbmaj7', 'F/A', 'Gm9', 'Dm9', 'Bbmaj7#11', 'Gm7', 'Csus4'],
      mel: 'F6:2 E6:1 D6:1 D6:3 -:1 C6:2 A5:1 F5:1 G5:3 -:1 A5:2 C6:1 E6:1 D6:2 E6:1 F6:1 D6:2 Bb5:1 G5:1 G5:4'}},
  {id: 'pasajeros', title: 'Pasajeros al tren', family: 'estacion', mood: 'any', style: 'bossa', bpm: 140, meter: 4, lead: ['flute', 'marimba'],
    A: {chords: ['Gmaj7', 'Am7 D9', 'Bm7 E7', 'Am7 D7', 'Gmaj7', 'Em7', 'A9', 'Am7 D7'],
      mel: 'B4:1 D5:.5 F#5:.5 A5:2 G5:1 E5:1 C5:1 F#5:1 D5:1.5 B4:.5 G#5:1 D5:1 C5:1 E5:1 F#5:2 B5:1.5 A5:.5 F#5:1 D5:1 E5:2 G5:1 B5:1 C#6:1.5 B5:.5 G5:1 E5:1 A5:2 F#5:2'},
    B: {chords: ['Cmaj7', 'Cm6 F9', 'Bm7', 'E7', 'Am7', 'D9', 'Gmaj7', 'Am7 D7'],
      mel: 'E5:1 G5:1 B5:2 A5:1.5 G5:.5 Eb5:2 D5:1 F#5:1 A5:2 G#5:2 E5:2 C5:1 E5:1 G5:1 B5:1 A5:1.5 F#5:.5 E5:2 D5:4 -:2 C5:1 F#5:1'}},
  {id: 'obras', title: 'Obras nocturnas', family: 'red', mood: 'night', style: 'night', bpm: 90, meter: 4, lead: ['bell', 'vibes'],
    A: {chords: ['Dm9', 'Bbmaj7', 'Gm9', 'A7sus4', 'Dm9', 'Fmaj7', 'Gm7', 'Asus4 A7'],
      mel: 'A5:1 F5:1 E5:1 D5:1 D5:3 -:1 Bb5:1 A5:1 F5:1 D5:1 E5:3 -:1 A5:1 C6:1 E6:1 D6:1 C6:3 -:1 Bb5:1 A5:1 G5:1 F5:1 E5:2 C#5:2'},
    B: {chords: ['Gm9', 'C9', 'Fmaj7', 'Bbmaj7', 'Em7b5', 'A7b9', 'Dm9', 'Dm9'],
      mel: 'Bb5:2 D6:2 E6:2 Bb5:2 A5:2 C6:1 A5:1 F5:4 G5:2 Bb5:1 E5:1 C#5:2 E5:1 G5:1 F5:2 E5:1 D5:1 D5:4'}},
];
export const FAMILY_LABEL = {estacion: 'Estilo «Estación»: bossa, jazz, vals y pop', red: 'Estilo «Red»: ambiental orquestal'};
export const STYLE_LABEL = {bossa: 'Bossa nova', swing: 'Jazz ligero', waltz: 'Vals', pop: 'Pop alegre', lounge: 'Lounge', ambient: 'Ambiental', drive: 'Ambiental rítmica', night: 'Nocturna'};

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
/** Convierte una pieza en una lista de eventos {t (s), inst, midi, dur (s), vel, opt}. */
export function arrange(song) {
  const spb = 60 / song.bpm, M = song.meter, rand = rng(song.id), events = [];
  const form = song.form || ['intro', 'A', 'B', 'A2', 'B2', 'A', 'B', 'A2', 'outro'];
  const swing = b => { if (!song.swing) return b; const f = b - Math.floor(b); return Math.abs(f - .5) < 1e-6 ? Math.floor(b) + .67 : b; };
  let bar0 = 0;
  for (const part of form) {
    const key = part[0] === 'B' ? 'B' : 'A', sec = song[key];
    let bars = sec.chords;
    if (part === 'intro') bars = sec.chords.slice(0, 4);
    if (part === 'outro') bars = sec.chords.slice(-4, -1).concat([sec.chords[0].split(' ')[0]]);
    const info = {light: part === 'intro' || part === 'outro', pad: part.endsWith('2'), comp: song.style === 'bossa' && song.id === 'pasajeros' ? 'pluck' : null};
    bars.forEach((spec, i) => {
      const syms = spec.split(' '), len = M / syms.length;
      const chords = syms.map((s, k) => ({c: chord(s), start: k * len, len}));
      const nextSpec = bars[i + 1] || sec.chords[0], next = chord(nextSpec.split(' ')[0]);
      const base = (bar0 + i) * M;
      const add = (inst, beat, m, dur, vel, opt = {}) => {
        const human = INSTR[inst] && ['kick', 'snare', 'clap', 'hat', 'shaker', 'rim', 'brush'].includes(inst) ? .004 : .009;
        events.push({t: swing(base + beat) * spb + (rand() - .5) * human, inst, midi: m, dur: dur * spb, vel: Math.min(1, vel * (.88 + rand() * .2) * (info.light ? .8 : 1)), opt});
      };
      STYLES[song.style](i, chords, add, info, next);
      if (part === 'outro' && i === bars.length - 1) chords.forEach(c => voicing(c.c, 55, false).forEach(n => add(song.style === 'night' || song.style === 'lounge' || song.style === 'bossa' ? 'epiano' : 'piano', M, n, M * 1.5, .35)));
    });
    if (!info.light) {
      const {notes} = parseMel(sec.mel), lead = song.lead[part.endsWith('2') ? 1 : 0];
      for (const n of notes) if (n.midi !== null) {
        const t = swing(bar0 * M + n.beat) * spb + (rand() - .5) * .01, vel = .55 + rand() * .15 + (n.dur >= 2 ? .05 : 0);
        events.push({t, inst: lead, midi: n.midi + (lead === 'bell' ? 12 : 0), dur: n.dur * spb * .95, vel, opt: {}});
        if (part.endsWith('2') && song.family === 'estacion' && n.dur >= 1) events.push({t, inst: 'bell', midi: n.midi + 12, dur: .3, vel: .22, opt: {}});
      }
    }
    bar0 += bars.length;
  }
  events.sort((a, b) => a.t - b.t);
  return {events, length: bar0 * M * spb + 3.5};
}

// ------------------------------------------------------------ mezcla y reproducción
function impulse(ctx, seconds = 2.8) {
  const len = Math.floor(ctx.sampleRate * seconds), buf = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) { const d = buf.getChannelData(ch); let last = 0; for (let i = 0; i < len; i++) { const x = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.2); last = last * .6 + x * .4; d[i] = last; } }
  return buf;
}
/** Cadena de mezcla: seco + reverberación + eco, a una salida común. */
export function makeBus(ctx, dest) {
  const dry = ctx.createGain(), rev = ctx.createConvolver(), revIn = ctx.createGain(), del = ctx.createDelay(1), delIn = ctx.createGain(), fb = ctx.createGain(), delOut = ctx.createGain();
  rev.buffer = impulse(ctx); revIn.connect(rev); rev.connect(dest); revIn.gain.value = .9;
  del.delayTime.value = .36; fb.gain.value = .32; delOut.gain.value = .5; delIn.connect(del); del.connect(fb); fb.connect(del); del.connect(delOut); delOut.connect(dest);
  dry.connect(dest);
  return {dry, rev: revIn, del: delIn};
}
function play(ctx, bus, e, t0) { INSTR[e.inst](ctx, bus, t0 + e.t, e.midi, e.dur, e.vel, e.opt || {}); }

/** Renderiza una pieza completa en un búfer (para exportar a audio). */
export async function renderSong(song, sampleRate = 44100) {
  const {events, length} = arrange(song);
  const ctx = new OfflineAudioContext(2, Math.ceil(length * sampleRate), sampleRate);
  const master = ctx.createGain(); master.gain.value = .8;
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
    const comp = this.ctx.createDynamicsCompressor(); comp.threshold.value = -16; comp.ratio.value = 3;
    this.master.connect(comp); comp.connect(this.ctx.destination);
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
    const gain = this.ctx.createGain(); gain.gain.value = 0; gain.gain.setTargetAtTime(1, this.ctx.currentTime, .4); gain.connect(this.master);
    const bus = makeBus(this.ctx, gain), {events, length} = arrange(song), t0 = this.ctx.currentTime + .15;
    const cur = this.current = {song, gain, bus, events, length, t0, i: 0};
    this.timer = setInterval(() => {
      if (this.current !== cur) return;
      const now = this.ctx.currentTime;
      while (cur.i < events.length && cur.t0 + events[cur.i].t < now + .3) { play(this.ctx, bus, events[cur.i], cur.t0); cur.i++; }
      if (now > cur.t0 + length) this.next();
    }, 60);
    this.emit();
  }
  next() { if (this.enabled) this.play(this.pick()); }
  get position() { return this.current && this.ctx ? Math.max(0, this.ctx.currentTime - this.current.t0) : 0; }
}
