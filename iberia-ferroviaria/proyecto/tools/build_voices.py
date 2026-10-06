"""Genera las voces neuronales de los personajes y las incrusta en dist/assets/voices.js.

Uso (desde proyecto/):
  node tools/voice_lines.mjs > ../investigacion/voces/frases.json
  python3 tools/build_voices.py <carpeta-de-voces-piper>

Motor: Piper (paquete PyPI piper-tts, GPL-3.0, solo en la generación). Voces en castellano de España,
publicadas por sherpa-onnx (https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models):
  vits-piper-es_ES-davefx-medium   (dataset davefx, CC0)
  vits-piper-es_ES-sharvard-medium (dataset Sharvard, Universidad de Edimburgo, CC BY 3.0; hablantes M y F)
Hace falta ffmpeg con libmp3lame. Las frases ya generadas se reutilizan desde ../investigacion/voces/<id>.mp3;
sin carpeta de voces, solo se reempaqueta.
"""
import base64, json, os, subprocess, sys, tempfile, wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, '..', 'investigacion', 'voces')
OUT = os.path.join(ROOT, 'dist', 'assets', 'voices.js')

# Voz (modelo, hablante) y ritmo de cada personaje. Sin efectos: prima la naturalidad; el tono burlesco
# lo ponen el guion y las cortinillas del juego. length_scale > 1 habla más despacio.
CAST = {
    'president': ('es_ES-davefx-medium', None, 1.08),   # pausado, de mitin
    'minister': ('es_ES-sharvard-medium', 1, 1.0),      # rueda de prensa
    'successor': ('es_ES-sharvard-medium', 0, 0.9),     # deprisa, como quien dicta un tuit
}


def main():
    lines = json.load(open(os.path.join(CACHE, 'frases.json'), encoding='utf-8'))
    models = {}
    if len(sys.argv) >= 2:
        from piper import PiperVoice, SynthesisConfig
        for name, _, _ in CAST.values():
            if name not in models:
                models[name] = PiperVoice.load(os.path.join(sys.argv[1], f'vits-piper-{name}', f'{name}.onnx'))
    clips, made, total = {}, 0, 0.0
    for item in lines:
        mp3 = os.path.join(CACHE, item['id'] + '.mp3')
        if not os.path.exists(mp3):
            if not models:
                sys.exit(f'Falta {mp3} y no se ha indicado la carpeta de voces.')
            name, speaker, length = CAST[item['person']]
            cfg = SynthesisConfig(speaker_id=speaker, length_scale=length, noise_scale=0.7, noise_w_scale=0.9)
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                with wave.open(tmp.name, 'wb') as w:
                    models[name].synthesize_wav(item['text'], w, syn_config=cfg)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', tmp.name, '-af',
                            'silenceremove=start_periods=1:start_threshold=-55dB,loudnorm=I=-17:TP=-1.5:LRA=11',
                            '-ar', '22050', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '56k', mp3], check=True)
            os.unlink(tmp.name)
            made += 1
            print(f"{item['person']:9} {item['text'][:70]}", flush=True)
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3],
                                   capture_output=True, text=True).stdout or 0)
        total += dur
        clips[item['id']] = base64.b64encode(open(mp3, 'rb').read()).decode()
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_voices.py: voces neuronales (Piper: davefx CC0, Sharvard CC BY 3.0) en MP3, una por frase.\n')
        f.write('export const CLIPS = ' + json.dumps(clips, separators=(',', ':')) + ';\n')
    print(f'{len(clips)} frases ({made} nuevas), {total / 60:.1f} min, {os.path.getsize(OUT) / 1e6:.2f} MB → {OUT}')


if __name__ == '__main__':
    main()
