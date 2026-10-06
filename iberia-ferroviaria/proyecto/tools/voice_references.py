"""Voces de referencia de los personajes (castellano de España) para el motor expresivo.
Se sintetizan con Piper y las voces es_ES davefx (CC0) y Sharvard (CC BY 3.0), grabadas por hablantes de España,
con frases llenas de «z» y «ce/ci» para fijar la distinción castellana. No son voces de personas reales concretas.
Uso: python3 tools/voice_references.py <carpeta-voces-piper> ../investigacion/voces/referencias
"""
import wave, sys
from piper import PiperVoice, SynthesisConfig
d = sys.argv[1]
REF = {
 'president': ('es_ES-davefx-medium', None, 1.05, 'Buenas tardes. Hoy, en Zaragoza, quiero dar las gracias a todos los ciudadanos. Hacemos este esfuerzo por la cercanía, por la eficacia y por un país que crece. Seguiremos avanzando, juntos.'),
 'minister': ('es_ES-sharvard-medium', 1, 1.0, 'Buenos días. Les explico cómo vamos a mejorar el servicio: más trenes en Cáceres, en Valencia y en Barcelona, más frecuencias y, sobre todo, mucha más puntualidad. Gracias.'),
 'successor': ('es_ES-sharvard-medium', 0, 0.95, 'A ver, os lo cuento rápido. Las obras de Zamora y de Cuenca van bien, se cumplen los plazos, y el que diga lo contrario, que venga a verlo. Así de sencillo.'),
}
for who, (m, spk, ls, text) in REF.items():
    v = PiperVoice.load(f'{d}/vits-piper-{m}/{m}.onnx')
    with wave.open(f'{sys.argv[2]}/{who}.wav', 'wb') as w:
        v.synthesize_wav(text, w, syn_config=SynthesisConfig(speaker_id=spk, length_scale=ls, noise_scale=0.7, noise_w_scale=0.9))
    print(who, 'ok')
