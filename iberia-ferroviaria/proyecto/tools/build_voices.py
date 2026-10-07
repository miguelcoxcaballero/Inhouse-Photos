"""Genera las voces de los personajes y las incrusta en dist/assets/voices.js.

Uso (desde proyecto/):
  node tools/voice_lines.mjs > ../investigacion/voces/frases.json
  python3 tools/build_voices.py generar <carpeta-modelo-xtts>   # genera lo que falte
  python3 tools/build_voices.py                                  # solo reempaqueta los MP3

Motor: XTTS-v2 (Coqui, licencia CPML: uso no comercial; paquete PyPI coqui-tts), con español «es».
Referencias (../investigacion/voces/referencias/<personaje>/, ver REFERENCIAS.txt): grabaciones reales .wav de
un hablante de España (dave, CC0, grabado para crear voces sintéticas) o, con xtts-speaker.txt, una voz de estudio
integrada en XTTS elegida con tools/voice_accent.py por su distinción castellana. No son voces de las personas
parodiadas ni de ninguna persona pública.

Interpretación: tools/voice_direction.json marca pausas y remates, que aquí se convierten en puntuación.
Cada frase se genera hasta RETRIES veces y se descarta la toma con saltos de octava (artefactos) o con una
duración fuera de lo esperable para su longitud; entre las válidas se queda la de más variación melódica.
Requiere ffmpeg con libmp3lame.
"""
import base64, glob, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOICES = os.path.join(ROOT, '..', 'investigacion', 'voces')
REFS = os.path.join(VOICES, 'referencias')
OUT = os.path.join(ROOT, 'dist', 'assets', 'voices.js')
RETRIES = 3

# Parámetros de interpretación por personaje: temperatura (variedad), velocidad y énfasis.
CAST = {
    'president': {'temperature': 0.75, 'speed': 0.92, 'repetition_penalty': 5.0},   # solemne, de mitin
    'minister': {'temperature': 0.8, 'speed': 1.0, 'repetition_penalty': 5.0},      # rueda de prensa entusiasta
    'successor': {'temperature': 0.8, 'speed': 1.08, 'repetition_penalty': 5.0},    # rápido, de tuit
}


def directed(item, direction):
    """Convierte la dirección de voz en puntuación: punto en las pausas largas, coma en las cortas."""
    chunks = direction.get(item['raw'])
    if not chunks:
        return item['text']
    out = ''
    for k, (text, _, pause) in enumerate(chunks):
        word = text.split()[0]
        if out.endswith(', ') and word[:1].isupper() and word.lower() in item['raw']:
            text = text[0].lower() + text[1:]
        if k == len(chunks) - 1:
            out += text
        elif text[-1] in '!?' or text[-1] == '.' or pause >= 280:
            out += text.rstrip(',') + ('' if text[-1] in '.!?' else '.') + ' '
        else:
            out += text.rstrip(',') + ', '
    return out


def expressiveness(x, sr):
    """Desviación típica de la F0 en semitonos; None si hay saltos de octava (artefacto) o poca voz."""
    import numpy as np, librosa
    y = librosa.resample(x, orig_sr=sr, target_sr=16000)
    f0, _, _ = librosa.pyin(y, fmin=60, fmax=450, sr=16000, frame_length=1024)
    f = f0[~np.isnan(f0)]
    if len(f) < 8 or len(f) < 0.25 * len(f0):
        return None
    st = 12 * np.log2(f / np.median(f))
    if np.mean(np.abs(np.diff(st)) > 7) > 0.03 or np.std(st) > 7:
        return None
    return float(np.std(st))


class Engine:
    def __init__(self, model_dir):
        import torch
        from TTS.tts.configs.xtts_config import XttsConfig
        from TTS.tts.models.xtts import Xtts
        torch.set_num_threads(os.cpu_count() or 4)
        cfg = XttsConfig(); cfg.load_json(os.path.join(model_dir, 'config.json'))
        self.model = Xtts.init_from_config(cfg)
        self.model.load_checkpoint(cfg, checkpoint_dir=model_dir, eval=True)
        self.sr = 24000
        self.latents = {}

    def voice(self, person):
        """Referencia del personaje: grabaciones .wav de su carpeta o, si hay xtts-speaker.txt, una voz integrada de XTTS."""
        if person not in self.latents:
            folder = os.path.join(REFS, person)
            named = os.path.join(folder, 'xtts-speaker.txt')
            files = sorted(glob.glob(os.path.join(folder, '*.wav')))
            if os.path.exists(named):
                spk = self.model.speaker_manager.speakers[open(named, encoding='utf-8').read().strip()]
                self.latents[person] = (spk['gpt_cond_latent'], spk['speaker_embedding'])
            elif files:
                self.latents[person] = self.model.get_conditioning_latents(audio_path=files, gpt_cond_len=30, max_ref_length=60)
            else:
                sys.exit(f'Sin referencias en {folder}')
        return self.latents[person]

    def say(self, person, text):
        import numpy as np
        gpt, spk = self.voice(person)
        p = CAST[person]
        out = self.model.inference(text, 'es', gpt, spk, temperature=p['temperature'], speed=p['speed'],
                                   repetition_penalty=p['repetition_penalty'], enable_text_splitting=True)
        return np.asarray(out['wav'], dtype=np.float32)


def best_take(engine, person, text):
    takes = []
    for _ in range(RETRIES):
        x = engine.say(person, text)
        dur = len(x) / engine.sr
        cps = len(text) / max(dur, 0.1)
        score = expressiveness(x, engine.sr) if 8 <= cps <= 22 else None
        takes.append((score, x))
        if score is not None and score >= 2.5:
            break
    ok = [t for t in takes if t[0] is not None]
    return (max(ok, key=lambda t: t[0])[1] if ok else takes[0][1]), [t[0] for t in takes]


def main():
    import soundfile as sf
    lines = json.load(open(os.path.join(VOICES, 'frases.json'), encoding='utf-8'))
    direction = json.load(open(os.path.join(ROOT, 'tools', 'voice_direction.json'), encoding='utf-8'))
    engine = Engine(sys.argv[2]) if len(sys.argv) >= 3 and sys.argv[1] == 'generar' else None
    clips, made, total, report = {}, 0, 0.0, []
    for item in lines:
        mp3 = os.path.join(VOICES, item['id'] + '.mp3')
        if not os.path.exists(mp3):
            if engine is None:
                sys.exit(f'Falta {mp3}: ejecuta «python3 tools/build_voices.py generar <modelo>».')
            text = directed(item, direction)
            x, scores = best_take(engine, item['person'], text)
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                sf.write(tmp.name, x, engine.sr)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', tmp.name, '-af',
                            'silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,loudnorm=I=-17:TP=-1.5:LRA=11',
                            '-ar', '24000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '40k', mp3], check=True)
            os.unlink(tmp.name)
            made += 1
            report.append({'id': item['id'], 'person': item['person'], 'text': text, 'takes': scores})
            print(f"{item['person']:9} {scores} {text[:70]}", flush=True)
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3],
                                   capture_output=True, text=True).stdout or 0)
        total += dur
        clips[item['id']] = base64.b64encode(open(mp3, 'rb').read()).decode()
    if report:
        json.dump(report, open(os.path.join(VOICES, 'tomas.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_voices.py: voces XTTS-v2 (Coqui, CPML) con referencias reales de España, en MP3, una por frase.\n')
        f.write('export const CLIPS = ' + json.dumps(clips, separators=(',', ':')) + ';\n')
    print(f'{len(clips)} frases ({made} nuevas), {total / 60:.1f} min, {os.path.getsize(OUT) / 1e6:.2f} MB → {OUT}')


if __name__ == '__main__':
    main()
