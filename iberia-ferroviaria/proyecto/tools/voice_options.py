import sys, importlib.util, soundfile as sf
spec = importlib.util.spec_from_file_location('bv', sys.argv[1]); bv = importlib.util.module_from_spec(spec); spec.loader.exec_module(bv)
so, tts = bv.load(sys.argv[2]); O = sys.argv[3]
T = {
 'm': '¡Buenas tardes! Hoy, en Zaragoza, quiero dar las gracias a todos. ¡Gracias! Hacemos este esfuerzo por la cercanía, por la eficacia... y por un país que crece. ¿A que sí?',
 'f': '¡Buenos días! Les cuento una noticia buenísima: más trenes en Cáceres, en Valencia y en Barcelona. ¿Y saben qué? ¡Mucha más puntualidad! Gracias, de corazón.',
}
OPTS = {'president': [6, 9, 7], 'successor': [5, 8, 7], 'minister': [1, 3, 0]}
for who, sids in OPTS.items():
    for k, sid in enumerate(sids, 1):
        x, sr, sc = bv.best_take(so, tts, T['f' if who == 'minister' else 'm'], sid, 1.0)
        sf.write(f'{O}/{who}-{k}.wav', x, sr); print(who, k, 'sid', sid, round(sc or 0, 2), flush=True)
