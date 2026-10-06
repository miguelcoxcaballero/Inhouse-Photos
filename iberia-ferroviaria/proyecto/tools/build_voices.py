"""Genera las voces de los personajes y las incrusta en dist/assets/voices.js.

Uso (desde proyecto/):
  node tools/voice_lines.mjs > ../investigacion/voces/frases.json
  python3 tools/build_voices.py <carpeta-supertonic>

Motor: Supertonic 2 (Supertone, modelo OpenRAIL-M, código MIT), multilingüe con español, ejecutado con
sherpa-onnx (PyPI) a partir de sherpa-onnx-supertonic-tts-int8-2026-03-06
(https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models). Requiere numpy, soundfile, librosa y ffmpeg.

Interpretación:
- tools/voice_direction.json trocea las frases irónicas: pausa antes del remate y remate más lento.
- Cada trozo se genera TAKES veces (el modelo es estocástico) y se elige la toma con más variación de
  entonación (desviación típica de la F0 en semitonos, medida con pYIN), descartando tomas con saltos
  de octava o poca voz. Es una medida objetiva de «menos monótono», no un juicio de escucha.
Las frases ya generadas se reutilizan desde ../investigacion/voces/<id>.mp3; sin modelo, solo se reempaqueta.
"""
import base64, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, '..', 'investigacion', 'voces')
OUT = os.path.join(ROOT, 'dist', 'assets', 'voices.js')
TAKES = 5
STEPS = 10

# Estilo de voz de Supertonic (0–4 femeninas, 5–9 masculinas) y velocidad base de cada personaje.
CAST = {
    'president': (6, 0.9),    # voz grave, pausada, de mitin
    'minister': (1, 1.0),     # voz clara de rueda de prensa
    'successor': (5, 1.1),    # voz ágil, a la velocidad de un tuit
}


def load(folder):
    import sherpa_onnx as so
    d = lambda f: os.path.join(folder, f)
    model = so.OfflineTtsSupertonicModelConfig(
        duration_predictor=d('duration_predictor.int8.onnx'), text_encoder=d('text_encoder.int8.onnx'),
        vector_estimator=d('vector_estimator.int8.onnx'), vocoder=d('vocoder.int8.onnx'), tts_json=d('tts.json'),
        unicode_indexer=d('unicode_indexer.bin'), voice_style=d('voice.bin'))
    return so, so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(supertonic=model, num_threads=4)))


def expressiveness(x, sr):
    """Desviación típica de la F0 en semitonos; None si la toma tiene saltos raros o poca voz."""
    import numpy as np, librosa
    y = librosa.resample(x, orig_sr=sr, target_sr=16000)
    f0, voiced, _ = librosa.pyin(y, fmin=60, fmax=420, sr=16000, frame_length=1024)
    f = f0[~np.isnan(f0)]
    if len(f) < 8 or len(f) < 0.25 * len(f0):
        return None
    st = 12 * np.log2(f / np.median(f))
    jumps = np.abs(np.diff(st))
    if np.mean(jumps > 7) > 0.03 or np.std(st) > 7:  # saltos de octava: artefacto
        return None
    return float(np.std(st))


def best_take(so, tts, text, sid, speed):
    import numpy as np
    takes = []
    for _ in range(TAKES):
        g = so.GenerationConfig(); g.sid = sid; g.speed = speed; g.num_steps = STEPS; g.extra = {'lang': 'es'}
        a = tts.generate(text, g)
        x = np.array(a.samples, dtype=np.float32)
        takes.append((expressiveness(x, a.sample_rate), x))
    ok = [t for t in takes if t[0] is not None]
    score, x = max(ok, key=lambda t: t[0]) if ok else (None, takes[0][1])
    return x, tts.sample_rate, score


def main():
    import numpy as np, soundfile as sf
    lines = json.load(open(os.path.join(CACHE, 'frases.json'), encoding='utf-8'))
    direction = json.load(open(os.path.join(ROOT, 'tools', 'voice_direction.json'), encoding='utf-8'))
    so = tts = None
    if len(sys.argv) >= 2:
        so, tts = load(sys.argv[1])
    clips, made, total, report = {}, 0, 0.0, []
    for item in lines:
        mp3 = os.path.join(CACHE, item['id'] + '.mp3')
        if not os.path.exists(mp3):
            if tts is None:
                sys.exit(f'Falta {mp3} y no se ha indicado la carpeta del modelo.')
            sid, base = CAST[item['person']]
            chunks = direction.get(item['raw']) or [[item['text'], 1.0, 0]]
            parts, scores = [], []
            for text, rel, pause in chunks:
                x, sr, score = best_take(so, tts, text, sid, base * rel)
                parts += [x, np.zeros(int(sr * pause / 1000), dtype=np.float32)]
                scores.append(score)
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                sf.write(tmp.name, np.concatenate(parts), sr)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', tmp.name, '-af',
                            'silenceremove=start_periods=1:start_threshold=-55dB,loudnorm=I=-17:TP=-1.5:LRA=11',
                            '-ar', '24000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '56k', mp3], check=True)
            os.unlink(tmp.name)
            made += 1
            report.append({'id': item['id'], 'person': item['person'], 'chunks': len(chunks), 'range_st': scores})
            print(f"{item['person']:9} {len(chunks)}× {item['text'][:64]}", flush=True)
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3],
                                   capture_output=True, text=True).stdout or 0)
        total += dur
        clips[item['id']] = base64.b64encode(open(mp3, 'rb').read()).decode()
    if report:
        json.dump(report, open(os.path.join(CACHE, 'tomas.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_voices.py: voces de Supertonic 2 (Supertone, OpenRAIL-M) en MP3, una por frase.\n')
        f.write('export const CLIPS = ' + json.dumps(clips, separators=(',', ':')) + ';\n')
    print(f'{len(clips)} frases ({made} nuevas), {total / 60:.1f} min, {os.path.getsize(OUT) / 1e6:.2f} MB → {OUT}')


if __name__ == '__main__':
    main()
