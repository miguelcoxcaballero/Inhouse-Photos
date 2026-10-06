# Prueba de voz con F5-TTS Spanish (jpgallegoar/F5-Spanish; datos VoxPopuli con acento peninsular): clona timbre y acento de la referencia.
# Uso: python3 tools/voice_f5_test.py ../investigacion/voces/referencias <salida>
import sys, time, torch
from huggingface_hub import hf_hub_download
from f5_tts.api import F5TTS
torch.set_num_threads(4)
ck = hf_hub_download('jpgallegoar/F5-Spanish', 'model_1250000.safetensors'); vocab = hf_hub_download('jpgallegoar/F5-Spanish', 'vocab.txt')
t = time.time(); tts = F5TTS(model='F5TTS_Base', ckpt_file=ck, vocab_file=vocab, device='cpu'); print('carga', round(time.time()-t), flush=True)
R, O = sys.argv[1], sys.argv[2]
REF = {
 'president': 'Buenas tardes. Hoy, en Zaragoza, quiero dar las gracias a todos los ciudadanos. Hacemos este esfuerzo por la cercanía, por la eficacia y por un país que crece. Seguiremos avanzando, juntos.',
 'minister': 'Buenos días. Les explico cómo vamos a mejorar el servicio: más trenes en Cáceres, en Valencia y en Barcelona, más frecuencias y, sobre todo, mucha más puntualidad. Gracias.',
 'successor': 'A ver, os lo cuento rápido. Las obras de Zamora y de Cuenca van bien, se cumplen los plazos, y el que diga lo contrario, que venga a verlo. Así de sencillo.',
}
GEN = {
 'president': '¡Ejem! Querido presidente de Renfe: ¡hoy España elige! Y España... modestamente... ¡soy un poco yo!',
 'minister': '¡Enhorabuena, presidente de Renfe! Es un cargo precioso... ¡todo el mundo sabe hacerlo mejor que tú!',
 'successor': '¡A ver! Te lo resumo en un tuit: ¡corredor mediterráneo, ya! Y si alguien te dice que esto se hace en dos años... ¡bloquéalo!',
}
for who in REF:
    t = time.time()
    wav, sr, _ = tts.infer(ref_file=f'{R}/{who}.wav', ref_text=REF[who], gen_text=GEN[who], file_wave=f'{O}/{who}.wav', nfe_step=32, speed=1.0, remove_silence=False)
    print(who, round(len(wav)/sr, 1), 's en', round(time.time()-t), 's', flush=True)
