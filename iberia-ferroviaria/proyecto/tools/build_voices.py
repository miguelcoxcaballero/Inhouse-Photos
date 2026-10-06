"""Genera las voces de los personajes y las incrusta en dist/assets/voices.js.

Uso (desde proyecto/):
  node tools/voice_lines.mjs > ../investigacion/voces/frases.json
  python3 tools/build_voices.py generar [exageración]     # con el motor; por defecto 0.75
  python3 tools/build_voices.py                            # solo reempaqueta los MP3 ya generados

Motor: Chatterbox Multilingual (Resemble AI, MIT; paquete PyPI chatterbox-tts, pesos en Hugging Face
ResembleAI/chatterbox), modelo expresivo con control de exageración. Idioma «es»; el acento castellano
lo fija la voz de referencia de cada personaje (../investigacion/voces/referencias, ver voice_references.py).
El audio lleva la marca de agua imperceptible Perth de Resemble AI que identifica voz sintética.

Interpretación: tools/voice_direction.json marca pausas y remates; aquí se convierten en puntuación
(«…» para las pausas largas, coma para las cortas) y cada frase se genera de una vez para que la
entonación tenga contexto. Requiere ffmpeg con libmp3lame.
"""
import base64, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VOICES = os.path.join(ROOT, '..', 'investigacion', 'voces')
CACHE = VOICES
REFS = os.path.join(VOICES, 'referencias')
OUT = os.path.join(ROOT, 'dist', 'assets', 'voices.js')

# cfg_weight bajo = ritmo más pausado y teatral; la exageración global se pasa por argumento.
CAST = {
    'president': {'cfg': 0.3, 'exag': 1.0},    # solemne, de mitin
    'minister': {'cfg': 0.4, 'exag': 1.0},     # rueda de prensa entusiasta
    'successor': {'cfg': 0.5, 'exag': 1.0},    # rápido, de tuit
}


def directed(item, direction):
    """Convierte la dirección de voz en puntuación: «…» en las pausas largas, coma en las cortas."""
    chunks = direction.get(item['raw'])
    if not chunks:
        return item['text']
    out = ''
    for k, (text, _, pause) in enumerate(chunks):
        word = text.split()[0]
        if out.endswith(', ') and word[:1].isupper() and word.lower() in item['raw']:
            text = text[0].lower() + text[1:]  # sigue la frase tras una coma
        if k == len(chunks) - 1:
            out += text
        elif text[-1] in '!?':
            out += text + ' '
        elif pause >= 280:
            out += text.rstrip('.,') + '... '
        elif text[-1] == '.':
            out += text + ' '
        else:
            out += text.rstrip(',') + ', '
    return out


def main():
    lines = json.load(open(os.path.join(VOICES, 'frases.json'), encoding='utf-8'))
    direction = json.load(open(os.path.join(ROOT, 'tools', 'voice_direction.json'), encoding='utf-8'))
    model = None
    if len(sys.argv) >= 2 and sys.argv[1] == 'generar':
        import torch
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS
        torch.set_num_threads(os.cpu_count() or 4)
        model = ChatterboxMultilingualTTS.from_pretrained(device='cpu')
        exag = float(sys.argv[2]) if len(sys.argv) >= 3 else 0.75
    clips, made, total = {}, 0, 0.0
    for item in lines:
        mp3 = os.path.join(CACHE, item['id'] + '.mp3')
        if not os.path.exists(mp3):
            if model is None:
                sys.exit(f'Falta {mp3}: ejecuta «python3 tools/build_voices.py generar».')
            import torchaudio as ta
            c = CAST[item['person']]
            text = directed(item, direction)
            wav = model.generate(text, language_id='es', audio_prompt_path=os.path.join(REFS, item['person'] + '.wav'),
                                 exaggeration=exag * c['exag'], cfg_weight=c['cfg'], temperature=0.8)
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp:
                ta.save(tmp.name, wav, model.sr)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', tmp.name, '-af',
                            'silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse,loudnorm=I=-17:TP=-1.5:LRA=11',
                            '-ar', '24000', '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '64k', mp3], check=True)
            os.unlink(tmp.name)
            made += 1
            print(f"{item['person']:9} {text[:80]}", flush=True)
        dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp3],
                                   capture_output=True, text=True).stdout or 0)
        total += dur
        clips[item['id']] = base64.b64encode(open(mp3, 'rb').read()).decode()
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_voices.py: voces de Chatterbox Multilingual (Resemble AI, MIT) en MP3, una por frase.\n')
        f.write('export const CLIPS = ' + json.dumps(clips, separators=(',', ':')) + ';\n')
    print(f'{len(clips)} frases ({made} nuevas), {total / 60:.1f} min, {os.path.getsize(OUT) / 1e6:.2f} MB → {OUT}')


if __name__ == '__main__':
    main()
