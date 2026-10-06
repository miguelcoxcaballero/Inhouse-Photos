// Voces de los personajes. Primero, voces neuronales pregrabadas (Piper, assets/voices.js, una por frase);
// si falta alguna frase, la síntesis de voz del sistema (Web Speech API). Cada personaje tiene su ritmo y su cortinilla.
import {CLIPS} from './assets/voices.js';

export const CAST = {
  // valores cercanos a 1: las voces del sistema suenan robóticas si se fuerza mucho el tono
  president: {gender: 'm', pitch: .93, rate: .93, swing: .03, pause: 380, sting: 'fanfare', label: 'solemne y pausado'},
  minister: {gender: 'f', pitch: 1.05, rate: 1.03, swing: .04, pause: 160, sting: 'ding', label: 'optimismo de rueda de prensa'},
  successor: {gender: 'm', pitch: 1.0, rate: 1.12, swing: .03, pause: 90, sting: 'tweet', label: 'a la velocidad de un tuit'},
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

/** Identificador estable de una frase de un personaje (FNV-1a), compartido con tools/voice_lines.mjs. */
export function clipId(person, sentence) {
  let h = 0x811c9dc5;
  for (const ch of person + '|' + speechText(sentence)) { h ^= ch.codePointAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(36);
}

/** Trocea en frases para dar entonación propia a cada una y resaltar el subtítulo. */
export function sentences(text) {
  return (String(text).match(/[^.!?…]+[.!?…]*(\s+|$)/g) || [String(text)]).map(s => s.trim()).filter(Boolean);
}

function score(v) {
  let s = 0;
  if (/^es[-_]ES/i.test(v.lang)) s += 40; else if (/^es/i.test(v.lang)) s += 22;
  if (/natural|neural|online|premium|enhanced|mejorad|siri/i.test(v.name)) s += 60;
  if (/google/i.test(v.name)) s += 14;
  if (/microsoft/i.test(v.name)) s += 6;
  if (v.localService === false) s += 4;
  return s;
}

export class Voices {
  constructor(music) {
    this.music = music; this.synth = typeof window !== 'undefined' ? window.speechSynthesis : null;
    this.voices = []; this.token = 0; this.speaking = null; this.listeners = new Set(); this.source = null; this.buffers = new Map(); this.log = [];
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem('iberia-voz') || '{}'); } catch {}
    this.enabled = saved.enabled ?? true; this.volume = saved.volume ?? 1;
    if (this.synth) { this.load(); this.synth.addEventListener?.('voiceschanged', () => this.load()); }
  }
  get neural() { return Object.keys(CLIPS).length > 0; }
  get available() { return this.neural || (!!this.synth && this.voices.length > 0); }
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
    if (this.source) { try { this.source.onended = null; this.source.stop(); } catch {} this.source = null; }
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
  /** Decodifica (una vez) el MP3 de una frase. */
  buffer(id) {
    if (!this.buffers.has(id)) {
      const bin = atob(CLIPS[id]), bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      this.buffers.set(id, this.music.ctx.decodeAudioData(bytes.buffer));
    }
    return this.buffers.get(id);
  }
  /**
   * Lee un texto con la voz del personaje.
   * onSentence(i) se llama al empezar cada frase (para el subtítulo); onend al terminar o al cortar.
   */
  speak(person, text, {onSentence, onend, sting = true} = {}) {
    this.stop();
    const parts = sentences(text), ids = parts.map(p => clipId(person, p));
    this.music?.init?.();
    const neural = !!this.music?.ctx && ids.every(id => CLIPS[id]);
    if (!this.enabled || (!neural && !this.synth)) { onend?.(); return false; }
    if (!neural && !this.voices.length) this.load();
    const c = CAST[person] || CAST.minister, voice = neural ? null : this.voiceFor(person), token = ++this.token;
    if (neural) ids.forEach(id => this.buffer(id).catch(() => {}));
    this.speaking = {person, onend}; this.duck(true); this.emit();
    const finish = () => { if (token !== this.token) return; this.speaking = null; this.duck(false); this.emit(); onend?.(); };
    const say = i => {
      if (token !== this.token) return;
      if (i >= parts.length) return finish();
      onSentence?.(i);
      const raw = parts[i], line = speechText(raw);
      if (!line) return say(i + 1);
      this.log.push(line); if (this.log.length > 60) this.log.shift();
      if (neural) {
        const ctx = this.music.ctx;
        this.buffer(ids[i]).then(buf => {
          if (token !== this.token) return;
          const src = ctx.createBufferSource(), g = ctx.createGain(); src.buffer = buf; g.gain.value = this.volume;
          src.connect(g); g.connect(ctx.destination); this.source = src;
          let done = false;
          const go = () => { if (done) return; done = true; clearTimeout(guard); if (this.source === src) this.source = null; setTimeout(() => say(i + 1), c.pause); };
          const guard = setTimeout(go, buf.duration * 1000 + 1500); // por si el contexto de audio está suspendido
          src.onended = go;
          src.start();
        }).catch(() => setTimeout(() => say(i + 1), 50));
        return;
      }
      const u = new SpeechSynthesisUtterance(line);
      if (voice) { u.voice = voice; u.lang = voice.lang; } else u.lang = 'es-ES';
      // entonación burlesca: exclamaciones más agudas, preguntas que suben, frases largas algo más rápidas
      const exclaim = /!/.test(raw), ask = /\?/.test(raw);
      u.pitch = Math.max(0, Math.min(2, c.pitch + (exclaim ? c.swing : 0) + (ask ? c.swing / 2 : 0)));
      u.rate = Math.max(.5, Math.min(2, c.rate * (person === 'president' && i === parts.length - 1 ? .95 : 1)));
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
