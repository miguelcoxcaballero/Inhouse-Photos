"""Referencias teatrales por «bootstrap»: genera tomas muy exageradas con Chatterbox a partir de las
referencias castellanas y elige la de mayor variación melódica (pYIN). Sin voces de personas reales.
Uso: python3 tools/voice_bootstrap.py ../investigacion/voces/referencias <salida>
"""
import sys, numpy as np, torch, torchaudio as ta, librosa
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
torch.set_num_threads(4)
m = ChatterboxMultilingualTTS.from_pretrained(device='cpu')
R, O = sys.argv[1], sys.argv[2]
TXT = {
 'president': '¡Ejem! ¡Queridos compatriotas! ¡Hoy es un día histórico! ¡Histórico! Gracias a mí, claro... y a ustedes, un poquito también. ¡Viva Zaragoza, viva Cáceres y viva yo!',
 'minister': '¡Ay, qué ilusión! ¡Buenísimas noticias, de verdad! Los trenes llegan... bueno, casi siempre. ¡Pero con muchísimo cariño! ¡Gracias, gracias, gracias!',
 'successor': '¡A ver, a ver, a ver! ¡Que no, hombre, que no! Las obras van fenomenal, ¿eh? ¡Fenomenal! Y el que diga lo contrario... ¡que venga a Zamora a verlo!',
}
def rng(w, sr):
    y = librosa.resample(w, orig_sr=sr, target_sr=16000)
    f0, _, _ = librosa.pyin(y, fmin=60, fmax=500, sr=16000, frame_length=1024); f = f0[~np.isnan(f0)]
    return float(np.std(12*np.log2(f/np.median(f)))) if len(f) > 20 else 0
for who, text in TXT.items():
    best = None
    for k in range(4):
        wav = m.generate(text, language_id='es', audio_prompt_path=f'{R}/{who}.wav', exaggeration=1.7, cfg_weight=0.3, temperature=1.0)
        x = wav.squeeze().numpy(); r = rng(x, m.sr); print(who, k, round(r, 2), round(len(x)/m.sr, 1), flush=True)
        ta.save(f'{O}/{who}-take{k}.wav', wav, m.sr)
        if best is None or r > best[0]: best = (r, k)
    print(who, 'mejor', best, flush=True)
