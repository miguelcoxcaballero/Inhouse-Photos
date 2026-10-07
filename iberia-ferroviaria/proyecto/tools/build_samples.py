"""Construye el banco de instrumentos muestreados de la banda sonora (dist/assets/samples.js).

Uso (desde proyecto/): python3 tools/build_samples.py [carpeta-caché]
Requiere numpy, soundfile, librosa y ffmpeg con libmp3lame. Descarga las muestras originales (caché en la carpeta
indicada), detecta la altura real de cada una (las bibliotecas numeran las octavas de forma distinta), elige un
subconjunto que cubra el registro necesario, recorta, aplica un fundido de salida, iguala niveles y codifica MP3
mono compactos. Créditos y licencias: ../investigacion/musica/MUESTRAS.txt (se regenera aquí).

Fuentes (todas libres):
- Salamander Grand Piano V3, Alexander Holm, CC BY 3.0 (copia MP3 de Tone.js).
- FluidR3_GM (Frank Wen), CC BY 3.0 (MP3 de gleitz/midi-js-soundfonts): piano eléctrico.
- VSCO 2 Community Edition, Versilian Studios, CC0: cuerdas, arpa, contrabajo pizzicato.
- VCSL (Versilian Community Sample Library), CC0: vibráfono, marimba, glockenspiel y percusión.
- tonejs-instruments (Nicholaus Brosowsky; muestras de la Philharmonia Orchestra y otras), CC BY 3.0: flauta,
  clarinete, guitarra de nailon y bajo eléctrico.
"""
import base64, json, os, subprocess, sys, tempfile, urllib.parse, urllib.request

import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'dist', 'assets', 'samples.js')
CREDITS = os.path.join(ROOT, '..', 'investigacion', 'musica', 'MUESTRAS.txt')
CACHE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, '..', '.cache-muestras')

SAL = 'https://tonejs.github.io/audio/salamander/'
FLU = 'https://gleitz.github.io/midi-js-soundfonts/FluidR3_GM/'
VCSL = 'https://raw.githubusercontent.com/sgossner/VCSL/master/'
VSCO = 'https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master/'
TJI = 'https://raw.githubusercontent.com/nbrosowsky/tonejs-instruments/master/samples/'
PC = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


def octs(names, lo, hi):
    return [f'{n}{o}' for o in range(lo, hi + 1) for n in names]


# Instrumentos con altura: candidatos, registro a cubrir (MIDI), salto máximo entre muestras (semitonos),
# duración máxima (s) y fuente para los créditos.
MARIMBA = ['Marimba_hit_Outrigger_' + n + '_med_01.wav' for n in ['F1', 'C2', 'G2', 'B2', 'F3', 'C4', 'G4', 'B4', 'F5', 'C6']]

TONAL = {
    'piano': dict(src='Salamander Grand Piano V3 (CC BY 3.0)', range=(36, 96), gap=3, len=(3.4, 1.6),
                  urls=[SAL + n + '.mp3' for n in octs(['C', 'Ds', 'Fs', 'A'], 2, 6) + ['C7']]),
    'epiano': dict(src='FluidR3_GM, Electric Piano 1 (CC BY 3.0)', range=(45, 86), gap=4, len=(2.4, 1.6),
                   urls=[FLU + 'electric_piano_1-mp3/' + n + '.mp3' for n in octs(['C', 'E', 'Ab'], 3, 6)]),
    'vibes': dict(src='VCSL, Vibraphone soft mallets (CC0)', range=(53, 89), gap=4, len=(3.0, 2.2),
                  urls=[VCSL + 'Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_' + n + '_v2_rr1_Main.wav'
                        for n in ['F2', 'A2', 'C3', 'E3', 'G3', 'B3', 'D4', 'F4', 'A4', 'C5', 'E5']]),
    'marimba': dict(src='VCSL, Marimba (CC0)', range=(55, 96), gap=5, len=(1.1, .7),
                    urls=[VCSL + 'Idiophones/Struck Idiophones/Marimba/' + f for f in MARIMBA]),
    'glock': dict(src='VCSL, Glockenspiel (CC0)', range=(76, 108), gap=7, len=(2.2, 1.6),
                  urls=[VCSL + 'Idiophones/Struck Idiophones/Glockenspiel/glock_medium_' + n + '_01.wav'
                        for n in ['G4', 'C5', 'G5', 'C6', 'G6', 'C7']]),
    'flute': dict(src='tonejs-instruments, flauta (CC BY 3.0)', range=(60, 96), gap=5, len=(2.8, 2.4),
                  urls=[TJI + 'flute/' + n + '.mp3' for n in ['C4', 'E4', 'A4', 'C5', 'E5', 'A5', 'C6', 'E6', 'A6', 'C7']]),
    'clarinet': dict(src='tonejs-instruments, clarinete (CC BY 3.0)', range=(50, 89), gap=5, len=(2.8, 2.4),
                     urls=[TJI + 'clarinet/' + n + '.mp3' for n in ['D3', 'F3', 'As3', 'D4', 'F4', 'As4', 'D5', 'F5', 'As5', 'D6']]),
    'strings': dict(src='VSCO 2 CE, secciones de violines, violas y violonchelos (CC0)', range=(40, 93), gap=5, len=(3.8, 3.2),
                    urls=[VSCO + 'Strings/Cello Section/susvib/susvib_' + n + '_v1_1.wav' for n in ['C1', 'G1', 'B1', 'D2', 'F2', 'A2', 'C3', 'E3']]
                    + [VSCO + 'Strings/Viola Section/susvib/ViolaEns_susvib_' + n + '_v1_1.wav' for n in ['D3', 'F3', 'A3', 'C4']]
                    + [VSCO + 'Strings/Violin Section/susVib/VlnEns_susVib_' + n + '_v1.wav' for n in ['G2', 'B2', 'D3', 'F#3', 'A3', 'C4', 'E4', 'G4', 'B4', 'D5']]),
    'harp': dict(src='VSCO 2 CE, arpa (CC0)', range=(43, 96), gap=5, len=(2.6, 1.8),
                 urls=[VSCO + 'Strings/Harp/KSHarp_' + n + '.wav' for n in
                       ['G1_mp', 'B1_mf', 'D2_mf', 'F2_mf', 'A2_mf', 'C3_mf', 'E3_mf', 'G3_mf', 'B3_mf', 'D4_mf', 'F4_mf', 'A4_mf', 'C5_mf', 'E5_mf', 'G5_mf', 'B5_mf', 'D6_mf']]),
    'guitar': dict(src='tonejs-instruments, guitarra de nailon (CC BY 3.0)', range=(40, 81), gap=5, len=(2.0, 1.4),
                   urls=[TJI + 'guitar-nylon/' + n + '.mp3' for n in ['E2', 'Gs2', 'B2', 'D3', 'Fs3', 'A3', 'Cs4', 'E4', 'Gs4', 'B4', 'D5', 'Fs5']]),
    'upright': dict(src='VSCO 2 CE, contrabajo pizzicato (CC0)', range=(28, 60), gap=6, len=(1.8, 1.2),
                    urls=[VSCO + 'Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_' + n + '_v1_rr1.wav' for n in ['E0', 'A#0', 'C1', 'D1', 'E1', 'A1', 'C#2', 'E2', 'B2']]),
    'ebass': dict(src='tonejs-instruments, bajo eléctrico (CC BY 3.0)', range=(28, 60), gap=6, len=(1.6, 1.1),
                  urls=[TJI + 'bass-electric/' + n + '.mp3' for n in ['E1', 'G1', 'As1', 'Cs2', 'E2', 'G2', 'As2', 'Cs3', 'E3', 'G3']]),
}
P = 'Membranophones/Struck Membranophones/'
I = 'Idiophones/Struck Idiophones/'
DRUMS = {  # nombre: (fuente, [urls de variantes], duración máx, frecuencia de muestreo)
    'hat': ('VCSL, charles (CC0)', [VCSL + I + 'Hi-Hat Cymbal/HiHat_HitC_v2_rr1_Mid.wav', VCSL + I + 'Hi-Hat Cymbal/HiHat_HitC_v2_rr2_Mid.wav'], .35, 44100),
    'hatopen': ('VCSL, charles abierto (CC0)', [VCSL + I + 'Hi-Hat Cymbal/HiHat_HitO_rr1_Mid.wav'], 1.2, 44100),
    'hatpedal': ('VCSL, charles con pedal (CC0)', [VCSL + I + 'Hi-Hat Cymbal/HiHat_Close_rr1_Mid.wav'], .3, 44100),
    'shaker': ('VCSL, shaker pequeño (CC0)', [VCSL + I + 'Shaker, Small/Mid_ShakerHighFaster_Down_rr1.wav', VCSL + I + 'Shaker, Small/Mid_ShakerHighFaster_Up_rr1.wav'], .3, 44100),
    'tamb': ('VCSL, pandereta (CC0)', [VCSL + I + 'Tambourine 1/Tamb1_Hit_v2_rr1_Mid.wav'], .6, 44100),
    'cajon': ('VCSL, cajón (CC0)', [VCSL + I + 'Cajon/Cajon_hit1_f_rr1.wav', VCSL + I + 'Cajon/Cajon_hit1_f_rr2.wav'], .5, 32000),
    'cajonslap': ('VCSL, cajón (CC0)', [VCSL + I + 'Cajon/Cajon_hit3_f_rr1.wav', VCSL + I + 'Cajon/Cajon_hit3_f_rr2.wav'], .4, 32000),
    'snare': ('VCSL, caja moderna (CC0)', [VCSL + P + 'Snare Drum, Modern 1/Snare2_HitSN_v5_rr1_Mid.wav', VCSL + P + 'Snare Drum, Modern 1/Snare2_HitSN_v5_rr2_Mid.wav'], .5, 44100),
    'ghost': ('VCSL, caja, toques suaves (CC0)', [VCSL + P + 'Snare Drum, Modern 1/Snare2_taps_v4_rr1_Mid.wav'], .3, 44100),
    'rim': ('VCSL, caja, golpe de aro (CC0)', [VCSL + P + 'Snare Drum, Modern 1/Snare2_stick_v1_rr1_Mid.wav', VCSL + P + 'Snare Drum, Modern 1/Snare2_stick_v1_rr2_Mid.wav'], .25, 44100),
    'conga': ('VCSL, conga (CC0)', [VCSL + P + 'Conga/Conga_HitN_v2_rr1_Sum.wav'], .6, 32000),
    'congamute': ('VCSL, conga apagada (CC0)', [VCSL + P + 'Conga/Conga_HitFM_v2_rr1_Sum.wav'], .3, 32000),
    'quinto': ('VCSL, quinto (CC0)', [VCSL + P + 'Conga/Quinto_HitN_v2_rr1_Sum.wav'], .5, 32000),
    'tumba': ('VCSL, tumbadora (CC0)', [VCSL + P + 'Conga/Tumba_HitN_v2_rr1_Sum.wav'], .7, 32000),
    'bongo': ('VCSL, bongó (CC0)', [VCSL + P + 'Bongos/BongoH_Hit1_v2_rr1_Mid.wav', VCSL + P + 'Bongos/BongoL_Hit1_v2_rr1_Mid.wav'], .4, 32000),
    'ride': ('VCSL, platillo suspendido con baqueta (CC0)', [VCSL + I + 'Suspended Cymbal 1/susCymb1_hit_stick_mp1.wav'], 2.0, 44100),
    'swell': ('VCSL, crescendo de platillo (CC0)', [VCSL + I + 'Suspended Cymbal 1/susCymb1_cresc_2s.wav'], 3.2, 44100),
    'crash': ('VCSL, platillo suspendido (CC0)', [VCSL + I + 'Suspended Cymbal 1/susCymb1_hit_mp1.wav'], 2.6, 44100),
}


def fetch(url):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, urllib.parse.unquote(url.split('://', 1)[1]).replace('/', '__'))
    if not os.path.exists(path):
        with urllib.request.urlopen(urllib.request.Request(urllib.parse.quote(url, safe=':/'))) as r, open(path + '.part', 'wb') as f:
            f.write(r.read())
        os.replace(path + '.part', path)
    return path


def load(path, sr=44100):
    """Decodifica a mono float32 con ffmpeg."""
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-ac', '1', '-ar', str(sr), '-f', 'f32le', '-'],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def onset(x, rel=.02):
    peak = np.max(np.abs(x)) or 1
    i = int(np.argmax(np.abs(x) > rel * peak))
    return max(0, i - 64)


def pitch(x, sr):
    import librosa
    seg = x[int(.05 * sr): int(1.0 * sr)]
    f0, voiced, _ = librosa.pyin(seg, fmin=30, fmax=4200, sr=sr, frame_length=4096)
    f = f0[voiced & ~np.isnan(f0)] if np.any(voiced) else f0[~np.isnan(f0)]
    return float(69 + 12 * np.log2(np.median(f) / 440)) if len(f) else None


def name_midi(url):
    """Altura según el nombre del fichero (convenio científico), para comprobar la detección."""
    import re
    base = os.path.basename(urllib.parse.unquote(url))
    m = re.search(r'(?:^|_)([A-G])(#|s|b)?(-?\d)(?=[_.])', base)
    if not m:
        return None
    acc = {'#': 1, 's': 1, 'b': -1}.get(m.group(2), 0)
    return 12 * (int(m.group(3)) + 1) + PC[m.group(1)] + acc


def shape(x, sr, length, fade_frac=.35):
    x = x[onset(x):]
    n = min(len(x), int(length * sr))
    x = x[:n].copy()
    f = max(1, int(n * fade_frac))
    x[-f:] *= np.cos(np.linspace(0, np.pi / 2, f)) ** 2
    x[:32] *= np.linspace(0, 1, 32)
    return x


def encode(x, sr, kbps=48):
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as t:
        sf.write(t.name, x, sr)
    mp3 = t.name[:-4] + '.mp3'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', t.name, '-ac', '1', '-c:a', 'libmp3lame', '-b:a', f'{kbps}k', mp3], check=True)
    data = open(mp3, 'rb').read()
    os.unlink(t.name); os.unlink(mp3)
    return data


def cover(cands, lo, hi, gap):
    """Elige pocas muestras que cubran [lo, hi]: una muestra solo se omite si sus vecinas quedan a `gap` semitonos
    o menos, de modo que ninguna nota tenga que transponerse más de gap/2."""
    inside = sorted((c for c in cands if lo - gap <= c[0] <= hi + gap), key=lambda c: c[0])
    keep = inside[:1]
    for k in range(1, len(inside)):
        if k + 1 < len(inside) and inside[k + 1][0] - keep[-1][0] <= gap:
            continue
        keep.append(inside[k])
    return keep


def rms(x, sr):
    seg = x[: int(.35 * sr)]
    return float(np.sqrt(np.mean(seg ** 2)) + 1e-9)


def main():
    bank, credits, total = {}, [], 0
    for name, spec in TONAL.items():
        sr = 32000
        cands = []
        for url in spec['urls']:
            x = load(fetch(url), sr)
            p = pitch(x[onset(x):], sr)
            if p is None:
                print('  sin altura:', url); continue
            m = int(round(p))
            guess = name_midi(url)
            cands.append((m, url, x, p - m, guess))
        chosen = cover(cands, *spec['range'], spec['gap'])
        notes, data, report = [], [], []
        long_, short = spec['len']
        for m, url, x, cents, guess in chosen:
            frac = (m - spec['range'][0]) / max(1, spec['range'][1] - spec['range'][0])
            y = shape(x, sr, long_ + (short - long_) * min(1, max(0, frac)))
            y = y * (.12 / rms(y, sr))
            y = y / max(1, np.max(np.abs(y)) / .98)
            b = encode(y, sr, 56 if name in ('piano', 'strings') else 48)
            notes.append(m); data.append(base64.b64encode(b).decode()); total += len(b)
            report.append(f'{m}{"" if guess is None else f"(nombre {guess})"}{cents:+.2f}')
        bank[name] = {'kind': 'tonal', 'notes': notes, 'data': data}
        credits.append(f'{name}: {spec["src"]}. Muestras MIDI {", ".join(report)}.')
        print(f'{name:9} {len(notes)} muestras {notes}', flush=True)
    for name, (src, urls, length, sr) in DRUMS.items():
        data = []
        for url in urls:
            y = shape(load(fetch(url), sr), sr, length, .3)
            y = y / (np.max(np.abs(y)) / .9)
            b = encode(y, sr, 64 if sr == 44100 else 48)
            data.append(base64.b64encode(b).decode()); total += len(b)
        bank[name] = {'kind': 'drum', 'data': data}
        credits.append(f'{name}: {src}.')
        print(f'{name:9} {len(data)} variante(s)', flush=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_samples.py: banco de instrumentos muestreados (MP3 mono). Créditos en investigacion/musica/MUESTRAS.txt.\n')
        f.write('export const SAMPLE_BANK = ' + json.dumps(bank, separators=(',', ':')) + ';\n')
    os.makedirs(os.path.dirname(CREDITS), exist_ok=True)
    with open(CREDITS, 'w', encoding='utf-8') as f:
        f.write('MUESTRAS DE LA BANDA SONORA (dist/assets/samples.js)\n\n'
                'Generadas con tools/build_samples.py a partir de bibliotecas libres. La música (melodías, armonías y arreglos)\n'
                'es composición original del proyecto; las muestras solo dan el timbre de los instrumentos.\n\n'
                'Licencias:\n'
                '- Salamander Grand Piano V3, Alexander Holm: CC BY 3.0 (https://github.com/sfzinstruments/SalamanderGrandPiano).\n'
                '- FluidR3_GM, Frank Wen: CC BY 3.0 (https://github.com/gleitz/midi-js-soundfonts).\n'
                '- VSCO 2 Community Edition, Versilian Studios: CC0 (https://github.com/sgossner/VSCO-2-CE).\n'
                '- VCSL, Versilian Community Sample Library: CC0 (https://github.com/sgossner/VCSL).\n'
                '- tonejs-instruments, Nicholaus P. Brosowsky (muestras de la Philharmonia Orchestra y otras): CC BY 3.0\n'
                '  (https://github.com/nbrosowsky/tonejs-instruments).\n\n'
                'Instrumentos (altura detectada; entre paréntesis, la que indica el nombre del fichero; desviación en semitonos):\n')
        f.write('\n'.join(credits) + '\n')
    print(f'{total / 1e6:.2f} MB de audio → {OUT} ({os.path.getsize(OUT) / 1e6:.2f} MB)')


if __name__ == '__main__':
    main()
