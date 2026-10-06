"""Genera las voces neuronales de los personajes y las incrusta en dist/assets/voices.js.

Uso (desde proyecto/):
  node tools/voice_lines.mjs > ../investigacion/voces/frases.json
  python3 tools/build_voices.py <kokoro.onnx> <voices-es.bin>

Modelo: Kokoro-82M v1.0 (Apache-2.0), versión cuantizada model_quantized.onnx de
onnx-community/Kokoro-82M-v1.0-ONNX (sha256 fbae9257…a1478, publicada también como paquete npm
kokoro-q8-shards). Voces ef_dora, em_alex y em_santa (Apache-2.0) convertidas a un .npz con
claves por voz y forma (510, 1, 256). Requiere los paquetes kokoro-onnx y soundfile, y ffmpeg con libmp3lame.
Las frases ya generadas se reutilizan desde ../investigacion/voces/<id>.mp3; sin modelo, solo se reempaqueta.
"""
import base64, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, '..', 'investigacion', 'voces')
OUT = os.path.join(ROOT, 'dist', 'assets', 'voices.js')

# Voz, velocidad y tratamiento de cada personaje. El tono burlesco lo ponen el guion, el ritmo y el
# entorno sonoro; la voz se deja natural.
CAST = {
    # presidente: voz grave y pausada, con la reverberación de un hemiciclo
    'president': ('em_santa', 0.9, 'aecho=0.85:0.55:70|130:0.16|0.09,highpass=f=70'),
    # ministra: ritmo de rueda de prensa, micrófono de atril
    'minister': ('ef_dora', 1.04, 'highpass=f=90,equalizer=f=3200:t=q:w=1.2:g=2.5'),
    # ministro: deprisa, como quien dicta un tuit
    'successor': ('em_alex', 1.16, 'highpass=f=80,equalizer=f=2500:t=q:w=1.4:g=1.5'),
}


def main():
    lines = json.load(open(os.path.join(CACHE, 'frases.json'), encoding='utf-8'))
    kokoro = None
    if len(sys.argv) >= 3:
        from kokoro_onnx import Kokoro
        kokoro = Kokoro(sys.argv[1], sys.argv[2])
    clips, made, total = {}, 0, 0.0
    for item in lines:
        mp3 = os.path.join(CACHE, item['id'] + '.mp3')
        if not os.path.exists(mp3):
            if kokoro is None:
                sys.exit(f'Falta {mp3} y no se ha indicado el modelo.')
            import soundfile as sf
            voice, speed, fx = CAST[item['person']]
            audio, sr = kokoro.create(item['text'], voice=voice, speed=speed, lang='es')
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                sf.write(tmp.name, audio, sr)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', tmp.name, '-af',
                            fx + ',silenceremove=start_periods=1:start_threshold=-50dB,loudnorm=I=-17:TP=-1.5:LRA=11',
                            '-ar', '24000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '48k', mp3], check=True)
            os.unlink(tmp.name)
            made += 1
            print(f"{item['person']:9} {item['text'][:70]}", flush=True)
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3],
                                   capture_output=True, text=True).stdout or 0)
        total += dur
        clips[item['id']] = base64.b64encode(open(mp3, 'rb').read()).decode()
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_voices.py: voces neuronales (Kokoro-82M, Apache-2.0) en MP3, una por frase.\n')
        f.write('export const CLIPS = ' + json.dumps(clips, separators=(',', ':')) + ';\n')
    print(f'{len(clips)} frases ({made} nuevas), {total / 60:.1f} min, {os.path.getsize(OUT) / 1e6:.2f} MB → {OUT}')


if __name__ == '__main__':
    main()
