# Pruebas de voz con Zonos (Zyphra, Apache-2.0): fonemas castellanos vía espeak-ng «es», timbre de la referencia y control de emoción.
# Uso: python3 tools/voice_zonos_options.py tools ../investigacion/voces/referencias/opciones <salida>
import sys, time; sys.path.insert(0, sys.argv[1]); import zinit
import torch, torchaudio
from zonos.model import Zonos
from zonos.conditioning import make_cond_dict
torch.set_num_threads(4)
model = Zonos.from_pretrained('Zyphra/Zonos-v0.1-transformer', device='cpu')
R, O = sys.argv[2], sys.argv[3]
# emoción: [felicidad, tristeza, asco, miedo, sorpresa, ira, otra, neutral]
CAST = {
 'president': ('¡Ejem! Y España... modestamente... ¡soy un poco yo!', [0.45, 0.02, 0.05, 0.02, 0.15, 0.15, 0.3, 0.05], 70.0, 12.0),
 'minister': ('¡Enhorabuena, presidente de Renfe! Es un cargo precioso... ¡todo el mundo sabe hacerlo mejor que tú!', [0.7, 0.02, 0.02, 0.02, 0.35, 0.02, 0.1, 0.05], 80.0, 15.0),
 'successor': ('¡A ver! Y si alguien te dice que esto se hace en dos años... ¡bloquéalo!', [0.3, 0.02, 0.1, 0.02, 0.3, 0.3, 0.1, 0.05], 70.0, 17.0),
}
for who, (text, emo, pstd, rate) in CAST.items():
    for k in (1, 2, 3):
        t = time.time()
        wav, sr = torchaudio.load(f'{R}/{who}-{k}.wav'); spk = model.make_speaker_embedding(wav, sr)
        torch.manual_seed(7)
        cond = make_cond_dict(text=text, speaker=spk, language='es', emotion=emo, pitch_std=pstd, speaking_rate=rate)
        codes = model.generate(model.prepare_conditioning(cond), max_new_tokens=86 * 14, progress_bar=False)
        w = model.autoencoder.decode(codes).cpu()
        torchaudio.save(f'{O}/{who}-{k}.wav', w[0], model.autoencoder.sampling_rate)
        print(who, k, round(w.shape[-1] / model.autoencoder.sampling_rate, 1), 's en', round(time.time() - t), 's', flush=True)
