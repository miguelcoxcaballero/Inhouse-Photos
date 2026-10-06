// Voces de los personajes: síntesis de voz del sistema (Web Speech API), sin ficheros ni conexión obligatoria.
// Cada personaje tiene su voz preferida, tono, velocidad, muletillas de entonación y una cortinilla sonora.

export const CAST = {
  president: {gender: 'm', pitch: .72, rate: .86, swing: .10, pause: 420, sting: 'fanfare', label: 'solemne y grandilocuente'},
  minister: {gender: 'f', pitch: 1.28, rate: 1.06, swing: .14, pause: 160, sting: 'ding', label: 'optimismo de rueda de prensa'},
  successor: {gender: 'm', pitch: 1.04, rate: 1.24, swing: .08, pause: 90, sting: 'tweet', label: 'a la velocidad de un tuit'},
};

const FEMALE = /elvira|helena|laura|m[oó]nica|paulina|luc[ií]a|elena|abril|dalia|ximena|sabina|marisol|esperanza|estrella|irene|triana|vera|lola|carmen|paloma|female|mujer|google español/i;
const MALE = /[aá]lvaro|jorge|pablo|ra[uú]l|juan|diego|enrique|carlos|arnau|dar[ií]o|gerardo|alonso|nil|sa[uú]l|teo|tom[aá]s|male|hombre|andr[eé]s|jos[eé]/i;

/** Convierte el texto de pantalla en texto pronunciable. */
export function speechText(text) {
  return String(text)
    .replace(/<[^>]+>/g, ' ')
    .replace(/(\d+(?:[.,]\d+)?)\s*M€/g, '$1 millones de euros')
    .replace(/(\d+(?:[.,]\d+)?)\s*€/g, '$1 euros')
    .replace(/(\d+)\s*×/g, '$1 por')
    .replace(/\bS(\d{3})\b/g, 'ese $1')
    .replace(/\bOuigo\b/g, 'Uigo')
    .replace(/\biryo\b/g, 'íryo')
    .replace(/\bAVE\b/g, 'Ave')
    .replace(/\bM€\b/g, 'millones de euros')
    .replace(/(\p{L})–(\p{L})/gu, '$1, $2')
    .replace(/[«»"“”]/g, '')
    .replace(/[\u{1F300}-\u{1FAFF}☀-➿❗️]/gu, '')
    .replace(/\s+/g, ' ').trim();
}

/** Trocea en frases para dar entonación propia a cada una y resaltar el subtítulo. */
export function sentences(text) {
  return (String(text).match(/[^.!?…]+[.!?…]*(\s+|$)/g) || [String(text)]).map(s => s.trim()).filter(Boolean);
}

function score(v) {
  let s = 0;
  if (/^es[-_]ES/i.test(v.lang)) s += 40; else if (/^es/i.test(v.lang)) s += 22;
  if (/natural|neural|online|premium|enhanced|mejorad/i.test(v.name)) s += 30;
  if (/google/i.test(v.name)) s += 14;
  if (/microsoft/i.test(v.name)) s += 6;
  if (v.localService === false) s += 4;
  return s;
}

export class Voices {
  constructor(music) {
    this.music = music; this.synth = typeof window !== 'undefined' ? window.speechSynthesis : null;
    this.voices = []; this.token = 0; this.speaking = null; this.listeners = new Set();
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('iberia-voz') || '{}'); } catch {}
    this.enabled = saved.enabled ?? true; this.volume = saved.volume ?? 1;
    if (this.synth) { this.load(); this.synth.addEventListener?.('voiceschanged', () => this.load()); }
  }
  get available() { return !!this.synth && this.voices.length > 0; }
  load() { this.voices = (this.synth.getVoices() || []).filter(v => /^es/i.test(v.lang)).sort((a, b) => score(b) - score(a)); this.emit(); }
  save() { try { localStorage.setItem('iberia-voz', JSON.stringify({enabled: this.enabled, volume: this.volume})); } catch {} }
  on(fn) { this.listeners.add(fn); }
  emit() { for (const fn of this.listeners) fn(this); }
  toggle() { this.enabled = !this.enabled; this.save(); if (!this.enabled) this.stop(); this.emit(); }
  /** Voz del sistema para un personaje: intenta respetar el género y no repetir voz entre personajes. */
  voiceFor(person) {
    const c = CAST[person] || CAST.minister, re = c.gender === 'f' ? FEMALE : MALE, other = c.gender === 'f' ? MALE : FEMALE;
    const fit = this.voices.filter(v => re.test(v.name)), neutral = this.voices.filter(v => !other.test(v.name));
    const pool = fit.length ? fit : neutral.length ? neutral : this.voices;
    // el sucesor usa la segunda voz masculina si existe, para distinguirlo del presidente
    return person === 'successor' && pool.length > 1 ? pool[1] : pool[0] || null;
  }
  stop() {
    this.token++;
    if (this.synth) this.synth.cancel();
    if (this.speaking) { this.speaking.onend?.(); this.speaking = null; }
    this.duck(false); this.emit();
  }
  duck(on) {
    const m = this.music;
    if (!m?.master || !m.ctx) return;
    m.master.gain.setTargetAtTime(on ? m.volume * .28 : m.volume, m.ctx.currentTime, .25);
  }
  sting(kind) {
    const m = this.music; if (!m) return 0;
    m.init?.(); const ctx = m.ctx; if (!ctx) return 0;
    const out = ctx.createGain(); out.gain.value = .22 * this.volume; out.connect(ctx.destination);
    const t = ctx.currentTime + .03, tone = (f, at, len, type = 'sine', v = 1) => {
      const o = ctx.createOscillator(), g = ctx.createGain(); o.type = type; o.frequency.value = f;
      g.gain.setValueAtTime(0, at); g.gain.linearRampToValueAtTime(v, at + .015); g.gain.exponentialRampToValueAtTime(.001, at + len);
      o.connect(g); g.connect(out); o.start(at); o.stop(at + len + .05);
      return o;
    };
    if (kind === 'fanfare') { // trompetas de inauguración, algo desafinadas a propósito
      [[392, 0], [392, .14], [523, .28], [659, .5]].forEach(([f, d], i) => { tone(f, t + d, i === 3 ? .9 : .16, 'sawtooth', .35); tone(f * 1.006, t + d, i === 3 ? .9 : .16, 'square', .12); });
      return 1300;
    }
    if (kind === 'tweet') { // pío de notificación
      [0, .11].forEach(d => { const o = tone(2400, t + d, .09, 'sine', .7); o.frequency.setValueAtTime(1900, t + d); o.frequency.exponentialRampToValueAtTime(3400, t + d + .07); });
      return 380;
    }
    [880, 1109, 1319].forEach((f, i) => tone(f, t + i * .1, .5, 'triangle', .8)); // «ding» de megafonía
    return 520;
  }
  /**
   * Lee un texto con la voz del personaje.
   * onSentence(i) se llama al empezar cada frase (para el subtítulo); onend al terminar o al cortar.
   */
  speak(person, text, {onSentence, onend, sting = true} = {}) {
    this.stop();
    if (!this.enabled || !this.synth) { onend?.(); return false; }
    if (!this.voices.length) this.load();
    const c = CAST[person] || CAST.minister, voice = this.voiceFor(person), parts = sentences(text), token = ++this.token;
    this.speaking = {person, onend}; this.duck(true); this.emit();
    const finish = () => { if (token !== this.token) return; this.speaking = null; this.duck(false); this.emit(); onend?.(); };
    const say = i => {
      if (token !== this.token) return;
      if (i >= parts.length) return finish();
      onSentence?.(i);
      const raw = parts[i], line = speechText(raw);
      if (!line) return say(i + 1);
      const u = new SpeechSynthesisUtterance(line);
      if (voice) { u.voice = voice; u.lang = voice.lang; } else u.lang = 'es-ES';
      // entonación burlesca: exclamaciones más agudas, preguntas que suben, frases largas algo más rápidas
      const exclaim = /!/.test(raw), ask = /\?/.test(raw), long = line.length > 120;
      u.pitch = Math.max(0, Math.min(2, c.pitch + (exclaim ? c.swing * 1.6 : 0) + (ask ? c.swing : 0) + (i % 2 ? -c.swing / 2 : c.swing / 3)));
      u.rate = Math.max(.5, Math.min(2, c.rate * (long ? 1.05 : 1) * (person === 'president' && i === parts.length - 1 ? .9 : 1)));
      u.volume = this.volume;
      // vigilante: algunos navegadores no emiten «end» (o no tienen voces); el diálogo sigue igualmente
      let done = false;
      const go = delay => { if (done) return; done = true; clearTimeout(guard); setTimeout(() => say(i + 1), delay); };
      const guard = setTimeout(() => go(0), 2500 + line.length / (13 * u.rate) * 1000);
      u.onend = () => go(c.pause);
      u.onerror = () => go(50);
      this.synth.speak(u);
    };
    const wait = sting ? this.sting(c.sting) : 0;
    setTimeout(() => say(0), wait);
    return true;
  }
}
