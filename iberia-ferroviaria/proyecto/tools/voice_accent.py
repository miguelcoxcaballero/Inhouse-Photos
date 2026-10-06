"""Medidor de acento: ¿suena a castellano de España?

Reconoce fonemas (wav2vec2 ajustado a espeak-ng, facebook/wav2vec2-lv-60-espeak-cv-ft) y cuenta, en las
palabras con «z», «ce» o «ci», si se pronuncian con /θ/ (distinción, España) o con /s/ (seseo, América).
También informa de la proporción de /s/ final conservada (en Andalucía y el Caribe se aspira).

Uso: python3 tools/voice_accent.py <carpeta-modelo-w2v> <audio.wav|carpeta> [...]
Imprime por fichero: θ, s, veredicto; con una carpeta, una tabla ordenada por θ. Es una medida objetiva, no una
escucha, y solo tiene sentido si el texto contiene «z», «ce» o «ci». El reconocedor confunde a veces /θ/ con /f/
(fricativas sordas vecinas), así que un /f/ donde no hay «f» en el texto cuenta como medio /θ/.
"""
import sys


def load(model_dir):
    import torch
    import json, os
    from transformers import Wav2Vec2ForCTC, Wav2Vec2FeatureExtractor
    torch.set_num_threads(4)
    vocab = {v: k for k, v in json.load(open(os.path.join(model_dir, 'vocab.json'), encoding='utf-8')).items()}
    proc = (Wav2Vec2FeatureExtractor.from_pretrained(model_dir), vocab)
    model = Wav2Vec2ForCTC.from_pretrained(model_dir).eval()
    return proc, model


def ctc_decode(ids, vocab):
    """Colapsa repeticiones y quita el relleno (CTC); «|» separa palabras."""
    out, prev = [], None
    for i in ids.tolist():
        if i != prev and i != 0:
            out.append(' ' if vocab[i] == '|' else vocab[i])
        prev = i
    return ''.join(out)


def phonemes(proc, model, path):
    import torch, librosa
    y, _ = librosa.load(path, sr=16000, mono=True)
    out = []
    for i in range(0, len(y), 16000 * 20):  # trozos de 20 s
        x = proc[0](y[i:i + 16000 * 20], sampling_rate=16000, return_tensors='pt').input_values
        with torch.no_grad():
            ids = model(x).logits.argmax(-1)
        out.append(ctc_decode(ids[0], proc[1]))
    return ' '.join(out)


def verdict(ph, text_f=0):
    """text_f: número de «f» reales en el texto (las /f/ sobrantes se cuentan como medio /θ/)."""
    th = ph.count('θ') + 0.5 * max(0, ph.count('f') - text_f)
    s = ph.count('s')
    return th, s, ('España (distinción)' if th >= 2 and th >= 0.25 * s else 'dudoso' if th >= 1 else 'seseo / no castellano')


if __name__ == '__main__':
    import os, glob
    proc, model = load(sys.argv[1])
    files = []
    for a in sys.argv[2:]:
        files += sorted(glob.glob(os.path.join(a, '*.wav'))) if os.path.isdir(a) else [a]
    rows = []
    for f in files:
        ph = phonemes(proc, model, f)
        th, s, v = verdict(ph)
        rows.append((th, s, v, f, ph))
        print(f'{f}\n  θ={th} s={s} → {v}\n  {ph[:160]}', flush=True)
    if len(files) > 3:
        print('\nRANKING (θ desc):')
        for th, s, v, f, _ in sorted(rows, key=lambda r: (-r[0], r[1])):
            print(f'  θ={th:<4} s={s:<3} {v:22} {os.path.basename(f)}')
