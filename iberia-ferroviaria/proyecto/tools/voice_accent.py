"""Medidor de acento: ¿suena a castellano de España?

Reconoce fonemas (wav2vec2 ajustado a espeak-ng, facebook/wav2vec2-lv-60-espeak-cv-ft) y cuenta, en las
palabras con «z», «ce» o «ci», si se pronuncian con /θ/ (distinción, España) o con /s/ (seseo, América).
También informa de la proporción de /s/ final conservada (en Andalucía y el Caribe se aspira).

Uso: python3 tools/voice_accent.py <carpeta-modelo-w2v> <audio.wav> [<audio.wav> ...]
Imprime por fichero: θ, s, veredicto. Es una medida objetiva, no una escucha.
"""
import sys


def load(model_dir):
    import torch
    from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor
    torch.set_num_threads(4)
    proc = Wav2Vec2Processor.from_pretrained(model_dir)
    model = Wav2Vec2ForCTC.from_pretrained(model_dir).eval()
    return proc, model


def phonemes(proc, model, path):
    import torch, librosa
    y, _ = librosa.load(path, sr=16000, mono=True)
    out = []
    for i in range(0, len(y), 16000 * 20):  # trozos de 20 s
        x = proc(y[i:i + 16000 * 20], sampling_rate=16000, return_tensors='pt').input_values
        with torch.no_grad():
            ids = model(x).logits.argmax(-1)
        out.append(proc.batch_decode(ids)[0])
    return ' '.join(out)


def verdict(ph):
    th, s = ph.count('θ'), ph.count('s')
    return th, s, ('España (distinción)' if th >= 2 and th >= 0.25 * s else 'dudoso' if th >= 1 else 'seseo / no castellano')


if __name__ == '__main__':
    proc, model = load(sys.argv[1])
    for f in sys.argv[2:]:
        ph = phonemes(proc, model, f)
        th, s, v = verdict(ph)
        print(f'{f}\n  θ={th} s={s} → {v}\n  {ph[:160]}')
