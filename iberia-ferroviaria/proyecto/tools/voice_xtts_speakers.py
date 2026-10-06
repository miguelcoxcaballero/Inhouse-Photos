"""Prueba las voces integradas de XTTS-v2 (voces de estudio de Coqui, no de personas identificables) en español.
Genera la misma frase con cada voz para medir después acento (voice_accent.py) y expresividad.
Uso: python3 tools/voice_xtts_speakers.py <carpeta-modelo-xtts> <salida> [nombre ...]
"""
import os, sys, torch, soundfile as sf
from TTS.tts.configs.xtts_config import XttsConfig
from TTS.tts.models.xtts import Xtts

TEXT = 'Buenos días. Les cuento una noticia buenísima: más trenes en Zaragoza, en Cáceres y en Barcelona. ¿Y saben qué? ¡Mucha más puntualidad! Gracias, de corazón.'

torch.set_num_threads(os.cpu_count() or 4)
model_dir, out = sys.argv[1], sys.argv[2]
cfg = XttsConfig(); cfg.load_json(os.path.join(model_dir, 'config.json'))
model = Xtts.init_from_config(cfg); model.load_checkpoint(cfg, checkpoint_dir=model_dir, eval=True)
names = sys.argv[3:] or list(model.speaker_manager.speakers.keys())
print(len(model.speaker_manager.speakers), 'voces:', ', '.join(model.speaker_manager.speakers.keys()))
os.makedirs(out, exist_ok=True)
for name in names:
    spk = model.speaker_manager.speakers[name]
    w = model.inference(TEXT, 'es', spk['gpt_cond_latent'], spk['speaker_embedding'], temperature=0.75, enable_text_splitting=True)['wav']
    sf.write(os.path.join(out, name.replace(' ', '_') + '.wav'), w, 24000); print(name, round(len(w) / 24000, 1), 's', flush=True)
