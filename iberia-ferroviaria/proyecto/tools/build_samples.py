"""Construye el banco de instrumentos muestreados de la banda sonora.

Uso (desde proyecto/): python3 tools/build_samples.py [carpeta-caché]
Requiere numpy, soundfile, librosa y ffmpeg con libmp3lame.

Para cada instrumento: descarga las grabaciones originales (con caché), detecta la altura real de cada nota (cada
biblioteca numera las octavas a su manera), elige las notas que cubren el registro necesario, recorta el silencio
inicial, aplica un fundido de salida, iguala el nivel entre notas conservando la diferencia natural entre dinámicas
(p, f…) y codifica MP3 compactos. Las baterías pueden mezclar varios micrófonos de la misma toma.

Salida: dist/assets/muestras-<grupo>.js (orquesta, teclas, percusion y ui, los efectos de la interfaz). Cada fichero añade sus instrumentos a
window.IBERIA_SAMPLES; dist/assets/samples-index.js dice en qué fichero está cada instrumento, para cargarlos solo
cuando una pieza los necesita. Créditos y licencias: ../investigacion/musica/MUESTRAS.txt (se regenera aquí).

Fuentes, todas libres:
- VSCO 2 Community Edition (Versilian Studios), CC0: secciones de violines, violas, violonchelos, contrabajo, violín
  solista, arpa, flauta, oboe, clarinete, fagot, trompa, trompeta, trombón, tuba y timbales.
- VCSL (Versilian Community Sample Library), CC0: vibráfono, cajón, congas, bongós, darbuka, pandero, palmas,
  bombo y caja de banda, platos de choque y platillo suspendido.
- Salamander Grand Piano V3 (Alexander Holm), CC BY 3.0: piano de cola, dos capas dinámicas, en estéreo.
- jRhodes3d (Jeff Learman), muestras CC BY-NC 4.0: piano eléctrico Rhodes Mark I de 1977.
- Virtuosity Drums (Versilian / Virtuosity Musical Instruments), CC0: batería de jazz, mezcla de micrófonos.
- Double bass de D. Smolken (Otto Rubner, 1958), CC0: contrabajo en pizzicato.
- Weresax (Karoryfer), CC0: saxofón alto.
- tonejs-instruments (Nicholaus Brosowsky), CC BY 3.0: guitarra española de nailon y bajo eléctrico.
Interfaz (grupo ui, VCSL y Virtuosity Drums, CC0): caja china, claves, cabasa, triángulo, crótalos, carillón de
barras, yunque, campanas de mano y vibráfono.
"""
import base64, json, os, re, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request

import numpy as np
import soundfile as sf

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, 'dist', 'assets')
CREDITS = os.path.join(ROOT, '..', 'investigacion', 'musica', 'MUESTRAS.txt')
CACHE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, '..', '.cache-muestras')

RAW = 'https://raw.githubusercontent.com/'
VSCO = RAW + 'sgossner/VSCO-2-CE/master/'
VCSL = RAW + 'sgossner/VCSL/master/'
SAL = RAW + 'sfzinstruments/SalamanderGrandPiano/master/Samples/'
RHO = RAW + 'sfzinstruments/jlearman.jRhodes3d/master/jRhodes3d-mono/'
VIR = RAW + 'sfzinstruments/virtuosity_drums/master/Samples/'
SMO = RAW + 'sfzinstruments/dsmolken.double-bass/master/pizz/'
SAX = RAW + 'sfzinstruments/karoryfer.weresax/master/Samples/alto/'
TJI = RAW + 'nbrosowsky/tonejs-instruments/master/samples/'
PC = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}

S_VLN = ['G2', 'A2', 'B2', 'D3', 'F#3', 'A3', 'C4', 'E4', 'G4', 'B4', 'D5']
S_VLA = ['C2', 'D2', 'E2', 'G2', 'B2', 'D3', 'F3', 'A3', 'C4', 'E4', 'G4', 'B4', 'D5']
S_VC = ['C1', 'E1', 'G1', 'B1', 'D2', 'F2', 'A2', 'C3', 'E3', 'G3', 'B3', 'D4', 'F4']
S_CB = ['F#0', 'G0', 'A#0', 'C1', 'D1', 'E1', 'F#1', 'G#1', 'A1', 'C#2', 'E2', 'G#2', 'B2']
S_VC_SHORT = ['C1', 'E1', 'B1', 'D2', 'A2', 'C3', 'B3', 'D4']
S_VLN_SHORT = ['G2', 'A2', 'B2', 'D3', 'A3', 'C4', 'E4', 'G4', 'B4', 'D5']
SAL_NOTES = [f'{n}{o}' for o in range(2, 7) for n in ['C', 'D#', 'F#', 'A']] + ['C7']
RHO_NOTES = ['A_029__F1', 'A_035__B1', 'A_040__E2', 'A_045__A2', 'A_050__D3', 'A_055__G3', 'A_059__B3', 'A_062__D4',
             'A_065__F4', 'A_071__B4', 'A_076__E5', 'A_081__A5', 'A_086__D6']


def L(fmt, names, layers):
    """Candidatos tonales: por cada nota, la lista de URLs de sus capas dinámicas (de suave a fuerte)."""
    return [[fmt.format(n=n, l=l) for l in layers] for n in names]


# group: fichero de salida · stereo · sr y kbps del MP3 · len (s) en grave y agudo · range (MIDI) · gap (semitonos)
TONAL = {
    # cuerdas: dos dinámicas reales (p y f) por nota
    'vln': dict(src='VSCO 2 CE, sección de violines, sostenido con vibrato (CC0)', group='orquesta', range=(55, 98), gap=4, len=(4.6, 3.6),
                cands=L(VSCO + 'Strings/Violin Section/susVib/VlnEns_susVib_{n}_v{l}.wav', S_VLN, [1, 2])),
    'vla': dict(src='VSCO 2 CE, sección de violas, sostenido con vibrato (CC0)', group='orquesta', range=(48, 79), gap=4, len=(4.6, 4.0),
                cands=L(VSCO + 'Strings/Viola Section/susvib/ViolaEns_susvib_{n}_v{l}_1.wav', S_VLA, [1, 2])),
    'vc': dict(src='VSCO 2 CE, sección de violonchelos, sostenido con vibrato (CC0)', group='orquesta', range=(36, 69), gap=4, len=(4.8, 4.2),
               cands=L(VSCO + 'Strings/Cello Section/susvib/susvib_{n}_v{l}_1.wav', S_VC, [1, 3])),
    'cb': dict(src='VSCO 2 CE, contrabajo, sostenido con vibrato (CC0)', group='orquesta', range=(28, 52), gap=5, len=(4.6, 4.2),
               cands=L(VSCO + 'Strings/Solo Contrabass/SusVib/BKCtbss_SusVib_{n}_v{l}_rr1.wav', S_CB, [1, 3])),
    'vln_spic': dict(src='VSCO 2 CE, violines en spiccato (CC0)', group='orquesta', range=(55, 93), gap=5, len=(.6, .5),
                     cands=L(VSCO + 'Strings/Violin Section/Spic/VlnEns_Spic_{n}_v{l}_rr1.wav', S_VLN_SHORT, [1, 2])),
    'vc_spic': dict(src='VSCO 2 CE, violonchelos en spiccato (CC0)', group='orquesta', range=(36, 64), gap=5, len=(.7, .55),
                    cands=L(VSCO + 'Strings/Cello Section/spic/spic_{n}_v{l}_RR1.wav', S_VC_SHORT, [1, 2])),
    'vln_pizz': dict(src='VSCO 2 CE, violines en pizzicato (CC0)', group='orquesta', range=(55, 93), gap=5, len=(1.2, .9),
                     cands=L(VSCO + 'Strings/Violin Section/Pizz/VlnEns_Pizz_{n}_v{l}_rr1.wav', S_VLN_SHORT, [2])),
    'vc_pizz': dict(src='VSCO 2 CE, violonchelos en pizzicato (CC0)', group='orquesta', range=(36, 64), gap=5, len=(1.5, 1.1),
                    cands=L(VSCO + 'Strings/Cello Section/pizzT/pizzT_{n}_v{l}_RR1.wav', S_VC_SHORT, [2])),
    'vln_trem': dict(src='VSCO 2 CE, violines en trémolo (CC0)', group='orquesta', range=(55, 93), gap=5, len=(3.8, 3.4),
                     cands=L(VSCO + 'Strings/Violin Section/Trem/VlnEns_Trem_{n}_v{l}.wav', S_VLN_SHORT, [2])),
    'vc_trem': dict(src='VSCO 2 CE, violonchelos en trémolo (CC0)', group='orquesta', range=(36, 64), gap=5, len=(3.8, 3.4),
                    cands=L(VSCO + 'Strings/Cello Section/trem/trem_{n}_v{l}_1.wav', ['E1', 'G1', 'D2', 'F2', 'A2', 'C3', 'E3', 'G3', 'B3', 'D4'], [2])),
    'svln': dict(src='VSCO 2 CE, violín solista con vibrato (CC0)', group='orquesta', range=(55, 98), gap=4, len=(3.8, 3.2),
                 cands=L(VSCO + 'Strings/Solo Violin/Arco Vib/LLVln_ArcoVib_{n}_{l}.wav', ['G3', 'A3', 'C4', 'E4', 'G4', 'A4', 'C5', 'E5', 'G5', 'A5', 'C6', 'E6', 'G6', 'A6', 'C7'], ['p', 'f'])),
    'harp': dict(src='VSCO 2 CE, arpa (CC0)', group='orquesta', range=(36, 96), gap=4, len=(3.0, 2.0),
                 cands=L(VSCO + 'Strings/Harp/KSHarp_{n}.wav', ['G1_mp', 'B1_mf', 'D2_mf', 'F2_mf', 'A2_mf', 'C3_mf', 'E3_mf', 'G3_mf', 'B3_mf', 'D4_mf', 'F4_mf', 'A4_mf', 'C5_mf', 'E5_mf', 'G5_mf', 'B5_mf', 'D6_mf'], [''])),
    # maderas
    'flute': dict(src='VSCO 2 CE, flauta con vibrato (CC0)', group='orquesta', range=(60, 96), gap=4, len=(3.2, 2.8),
                  cands=L(VSCO + 'Woodwinds/Flute/susvib/LDFlute_susvib_{n}_v1_1.wav', ['C3', 'E3', 'A3', 'C4', 'E4', 'A4', 'C5', 'E5', 'A5', 'C6'], [''])),
    'oboe': dict(src='VSCO 2 CE, oboe con vibrato (CC0)', group='orquesta', range=(58, 89), gap=4, len=(3.0, 2.6),
                 cands=L(VSCO + 'Woodwinds/Oboe/Vib/Oboe_Vib_{n}_v{l}_Main.wav', ['A#2', 'D3', 'F3', 'A#3', 'D4', 'F4', 'A#4', 'D5', 'F5'], [1, 3])),
    'clarinet': dict(src='VSCO 2 CE, clarinete (CC0)', group='orquesta', range=(50, 90), gap=4, len=(3.0, 2.6),
                     cands=L(VSCO + 'Woodwinds/Clarinet/susLong/DCClar_susLong_{n}_v{l}_rr1_sum.wav', ['D2', 'F2', 'A#2', 'D3', 'F3', 'A#3', 'D4', 'F4', 'A#4', 'D5', 'F#5'], [1, 3])),
    'bassoon': dict(src='VSCO 2 CE, fagot (CC0)', group='orquesta', range=(34, 72), gap=5, len=(3.0, 2.6),
                    cands=L(VSCO + 'Woodwinds/Bassoon/vib/PSBassoon_{n}_v{l}_1.wav', ['G1', 'A1', 'C2', 'G2', 'C3', 'E3', 'A3', 'C4'], [1, 2])),
    # metales
    'horn': dict(src='VSCO 2 CE, trompa (CC0)', group='orquesta', range=(41, 77), gap=4, len=(3.6, 3.0),
                 cands=L(VSCO + 'Brass/F Horn/sus/MOHorn_sus_{n}_v{l}_1.wav', ['C1', 'D#1', 'G1', 'A#1', 'D2', 'F2', 'A2', 'C3', 'D4', 'F4'], [1, 3])),
    'trumpet': dict(src='VSCO 2 CE, trompeta (CC0)', group='orquesta', range=(54, 86), gap=4, len=(3.2, 2.8),
                    cands=L(VSCO + 'Brass/Trumpet/sus/Sum_SHTrumpet_sus_{n}_v{l}_rr1.wav', ['F2', 'A2', 'C3', 'D#3', 'G3', 'A#3', 'D4', 'F4', 'A4', 'C5'], [1, 3])),
    'trombone': dict(src='VSCO 2 CE, trombón tenor (CC0)', group='orquesta', range=(40, 70), gap=5, len=(3.2, 2.8),
                     cands=L(VSCO + 'Brass/Tenor Trombone/sus/tenortbn_sus_{n}_v{l}_1.wav', ['A#0', 'C#1', 'D#1', 'F1', 'A#1', 'D2', 'F2', 'C3', 'C#3', 'D#3', 'F3'], [1, 2])),
    'tuba': dict(src='VSCO 2 CE, tuba (CC0)', group='orquesta', range=(28, 52), gap=5, len=(3.0, 2.6),
                 cands=L(VSCO + 'Brass/Tuba/sus/Tuba3_sus_{n}_v{l}_rr1_Mid.wav', ['F0', 'A#0', 'D#1', 'F1', 'A#1', 'D2', 'F2', 'A#2', 'D3'], [1, 3])),
    'mtrumpet': dict(src='VSCO 2 CE, trompeta con sordina recta (CC0)', group='orquesta', range=(55, 84), gap=5, len=(2.8, 2.4),
                     cands=L(VSCO + 'Brass/Trumpet/straightM-sus/Sum_SHTrumpet_straightM-sus_{n}_v1_rr1.wav', ['C3', 'D3', 'G3', 'A#3', 'D4', 'F4', 'A4'], [''])),
    'timp': dict(src='VCSL, timbales (Timpani 2), golpe mezzoforte, 34 afinaciones (CC0)', group='orquesta', range=(36, 57), gap=3, len=(2.8, 2.4), drum=True,
                 cands=L(VCSL + 'Membranophones/Struck Membranophones/Timpani 2/Hit/Timpani{n}_hit_v{l}_rr1_main.wav',
                         ['1A', '1B', '1C', '1D', '2A', '2B', '3A', '3B', '3C', '4A', '5A', '5B', '6A', '6B', '6C', '6D', '6E', '6F', '6G', '6H', '6I', '6J',
                          '7A', '7B', '7C', '7D', '7E', '7F', '7G', '8A', '8B', '8C', '8D', '8E'], [2, 5])),
    'timproll': dict(src='VSCO 2 CE, timbales, redoble (CC0)', group='orquesta', range=(36, 60), gap=6, len=(3.4, 3.0), nopitch=True,
                     cands=L(VSCO + 'Percussion/Timpani/Rolls/Timpani{n}_Roll_v3_rr1_Sum.wav', ['1', '2', '3', '4', '5'], [''])),
    # teclados, guitarra, bajos y saxo
    'piano': dict(src='Salamander Grand Piano V3, capas 6 y 12 de 16, estéreo (CC BY 3.0)', group='teclas', range=(36, 96), gap=3, len=(3.4, 1.8),
                  stereo=True, sr=44100, kbps=96, cands=L(SAL + '{n}v{l}.flac', SAL_NOTES, [6, 12])),
    'rhodes': dict(src='jRhodes3d, Rhodes Mark I de 1977, capas 2 y 4 (CC BY-NC 4.0)', group='teclas', range=(40, 88), gap=5, len=(3.0, 2.2),
                   cands=L(RHO + '{n}_{l}.flac', RHO_NOTES, [2, 4])),
    'vibes': dict(src='VCSL, vibráfono con baquetas blandas (CC0)', group='teclas', range=(53, 89), gap=4, len=(3.2, 2.4),
                  cands=L(VCSL + 'Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_{n}_v{l}_rr1_Main.wav', ['F2', 'A2', 'C3', 'E3', 'G3', 'B3', 'D4', 'F4', 'A4', 'C5', 'E5'], [1, 2])),
    'guitar': dict(src='tonejs-instruments, guitarra española de nailon (CC BY 3.0)', group='teclas', range=(40, 84), gap=4, len=(2.6, 1.8),
                   cands=L(TJI + 'guitar-nylon/{n}.mp3', ['E2', 'Gs2', 'B2', 'D3', 'Fs3', 'A3', 'Cs4', 'E4', 'Gs4', 'B4', 'D5', 'Fs5', 'A5', 'As5'], [''])),
    'upright': dict(src='D. Smolken, contrabajo Otto Rubner en pizzicato, dinámicas media y fuerte (CC0)', group='teclas', range=(28, 60), gap=5, len=(1.9, 1.3),
                    cands=L(SMO + 'pizz_{n}_{l}a.wav', ['c1', 'eb1', 'g1', 'bb1', 'd2', 'f2', 'a2', 'c3', 'e3', 'g3', 'a3'], ['m', 'f'])),
    'ebass': dict(src='tonejs-instruments, bajo eléctrico (CC BY 3.0)', group='teclas', range=(28, 60), gap=6, len=(1.6, 1.1),
                  cands=L(TJI + 'bass-electric/{n}.mp3', ['E1', 'G1', 'As1', 'Cs2', 'E2', 'G2', 'As2', 'Cs3', 'E3', 'G3'], [''])),
    'sax': dict(src='Weresax (Karoryfer), saxofón alto, dinámicas p y f (CC0)', group='teclas', range=(49, 82), gap=4, len=(2.8, 2.4),
                cands=L(SAX + '{n}_{l}_rr1_cnd.wav', ['db2', 'e2', 'g2', 'bb2', 'db3', 'e3', 'g3', 'bb3', 'db4', 'e4', 'g4', 'ab4'], ['p', 'f'])),
    # interfaz: campanas de mano (avisos de estación, confirmaciones) y vibráfono suave (notas de los botones)
    'ui_chime': dict(src='VCSL, campanas de mano (CC0)', group='ui', range=(60, 90), gap=3, len=(2.2, 1.8),
                     cands=L(VCSL + 'Idiophones/Struck Idiophones/Hand Chimes/sus_{n}_r01_main.wav', ['C4', 'D4', 'F#4', 'A4', 'C5', 'D5', 'E5', 'F#5', 'G#5', 'A#5', 'C6'], [''])),
    'ui_vibe': dict(src='VCSL, vibráfono con baquetas blandas, notas cortas (CC0)', group='ui', range=(60, 88), gap=3, len=(1.4, 1.1),
                    cands=L(VCSL + 'Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_{n}_v1_rr1_Main.wav', ['C3', 'E3', 'G3', 'B3', 'D4', 'F4', 'A4', 'C5', 'E5'], [''])),
}

P = 'Membranophones/Struck Membranophones/'
I = 'Idiophones/Struck Idiophones/'


def kit(piece, names, mics=(('mid', 1.0), ('oh', .55))):
    """Variantes de una pieza de la batería, cada una mezcla de varios micrófonos de la misma toma."""
    return [[(VIR + f'{mic}/{piece}/{mic}_{name}.flac', g) for mic, g in mics] for name in names]


# Percusión: variantes (cada una, lista de (url, ganancia) que se suman), duración máx., frecuencia de muestreo.
DRUMS = {
    'kick': ('Virtuosity Drums, bombo (micrófono de bombo + ambiente) (CC0)',
             kit('kick', ['kick_snon_vl3_rr1', 'kick_snon_vl3_rr2'], (('kickmic', .8), ('mid', .8))), .7, 44100),
    'snare': ('Virtuosity Drums, caja (CC0)', kit('snare', ['snare_center_vl11', 'snare_center_vl12']), .6, 44100),
    'ghost': ('Virtuosity Drums, caja suave (CC0)', kit('snare', ['snare_center_vl3', 'snare_center_vl4']), .35, 44100),
    'xstick': ('Virtuosity Drums, golpe de aro cruzado (CC0)', kit('snare', ['snare_crossstick_vl8', 'snare_crossstick_vl10']), .3, 44100),
    'rimshot': ('Virtuosity Drums, caja con aro (CC0)', kit('snare', ['snare_rimshot_vl8']), .6, 44100),
    'hat': ('Virtuosity Drums, charles cerrado (CC0)', kit('hh', ['hh_closed_vl2_rr1', 'hh_closed_vl2_rr2', 'hh_closed_vl3_rr1']), .35, 44100),
    'hatopen': ('Virtuosity Drums, charles abierto (CC0)', kit('hh', ['hh_open_vl2_rr1']), 1.3, 44100),
    'hatpedal': ('Virtuosity Drums, charles con pedal (CC0)', kit('hh', ['hh_pedal_vl2_rr1', 'hh_pedal_vl2_rr2']), .3, 44100),
    'ride': ('Virtuosity Drums, plato ride (CC0)', kit('ride', ['ride_ride_vl2_rr1', 'ride_ride_vl2_rr2', 'ride_ride_vl1_rr1']), 2.2, 44100),
    'ridebell': ('Virtuosity Drums, campana del ride (CC0)', kit('ride', ['ride_bell_vl2_rr1']), 2.0, 44100),
    'crash': ('Virtuosity Drums, plato crash (CC0)', kit('crash', ['crash_crash_vl2_rr1']), 3.0, 44100),
    'tomh': ('Virtuosity Drums, tom agudo (CC0)', kit('htom', ['htom_center_vl10']), .8, 44100),
    'toml': ('Virtuosity Drums, tom grave (CC0)', kit('ltom', ['ltom_center_vl10']), 1.0, 44100),
    'shaker': ('Virtuosity Drums, shaker (CC0)', [[(VIR + 'perc/mid/shaker/LShaker_Shake1D_rr1_Mid.wav', 1)], [(VIR + 'perc/mid/shaker/LShaker_Shake1U_rr1_Mid.wav', 1)]], .3, 44100),
    'tamb': ('Virtuosity Drums y VCSL, pandereta (CC0)', [[(VIR + 'perc/mid/tambourine/Tamb1_Shake_rr1_Mid.wav', 1)], [(VCSL + I + 'Tambourine 1/Tamb1_Hit_v2_rr1_Mid.wav', 1)]], .5, 44100),
    'triangle': ('Virtuosity Drums, triángulo (CC0)', [[(VIR + 'perc/mid/triangle/Triangle1_Hit_v1_rr1_Mid.wav', 1)]], 1.6, 44100),
    'cajon': ('VCSL, cajón, grave (CC0)', [[(VCSL + I + 'Cajon/Cajon_hit1_f_rr1.wav', 1)], [(VCSL + I + 'Cajon/Cajon_hit1_f_rr2.wav', 1)]], .5, 32000),
    'cajonslap': ('VCSL, cajón, agudo (CC0)', [[(VCSL + I + 'Cajon/Cajon_hit3_f_rr1.wav', 1)], [(VCSL + I + 'Cajon/Cajon_hit3_f_rr2.wav', 1)]], .4, 32000),
    'claps': ('VCSL, palmas (CC0)', [[(VCSL + I + 'Claps/SoloClap_vl2.wav', 1)], [(VCSL + I + 'Claps/SoloClap_vl3.wav', 1)], [(VCSL + I + 'Claps/Clap_rr1.wav', 1)]], .4, 44100),
    'conga': ('VCSL, conga (CC0)', [[(VCSL + P + 'Conga/Conga_HitN_v2_rr1_Sum.wav', 1)]], .6, 32000),
    'congamute': ('VCSL, conga apagada (CC0)', [[(VCSL + P + 'Conga/Conga_HitFM_v2_rr1_Sum.wav', 1)]], .3, 32000),
    'quinto': ('VCSL, quinto (CC0)', [[(VCSL + P + 'Conga/Quinto_HitN_v2_rr1_Sum.wav', 1)]], .5, 32000),
    'tumba': ('VCSL, tumbadora (CC0)', [[(VCSL + P + 'Conga/Tumba_HitN_v2_rr1_Sum.wav', 1)]], .7, 32000),
    'bongo': ('VCSL, bongó (CC0)', [[(VCSL + P + 'Bongos/BongoH_Hit1_v2_rr1_Mid.wav', 1)], [(VCSL + P + 'Bongos/BongoL_Hit1_v2_rr1_Mid.wav', 1)]], .4, 32000),
    'darbuka': ('VCSL, darbuka, «dum» (CC0)', [[(VCSL + P + 'Darbuka/Darbuka_1_hit_vl2_rr1.wav', 1)], [(VCSL + P + 'Darbuka/Darbuka_1_hit_vl2_rr2.wav', 1)]], .6, 32000),
    'darbukatek': ('VCSL, darbuka, «tek» (CC0)', [[(VCSL + P + 'Darbuka/Darbuka_5_hit_vl2_rr1.wav', 1)], [(VCSL + P + 'Darbuka/Darbuka_5_hit_vl2_rr2.wav', 1)]], .3, 32000),
    'frame': ('VCSL, pandero (CC0)', [[(VCSL + P + 'Frame Drum/HDrumL_Hit_v2_rr1_Sum.wav', 1)], [(VCSL + P + 'Frame Drum/HDrumL_Hit_v2_rr2_Sum.wav', 1)]], .8, 32000),
    'bassdrum': ('VCSL, bombo de banda (CC0)', [[(VCSL + P + 'Bass Drum 2/bassdrum_hit_mf1.wav', 1)], [(VCSL + P + 'Bass Drum 2/bassdrum_hit_mf2.wav', 1)]], 1.4, 32000),
    'msnare': ('VCSL, caja de banda (CC0)', [[(VCSL + P + 'Legacy Snares/drum3_marching/snare3_p_rr1.wav', 1)], [(VCSL + P + 'Legacy Snares/drum3_marching/snare3_p_rr2.wav', 1)]], .5, 44100),
    'clash': ('VCSL, platos de choque (CC0)', [[(VCSL + I + 'Clash Cymbals 1/cymbal_crash1_mf1.wav', 1)]], 3.0, 44100),
    'castanets': ('aproximación a castañuelas: claves de Virtuosity Drums (CC0) una quinta más agudas y muy apagadas',
                  [[(VIR + f'perc/mid/claves/Claves1_Hit_v{v}_rr{r}_Mid.wav', 1)] for v, r in ((2, 1), (2, 3), (3, 2), (3, 5))], .12, 44100,
                  dict(rate=1.5, decay=.03, hp=900)),
    'swell': ('VCSL, crescendo de platillo suspendido (CC0)', [[(VCSL + I + 'Suspended Cymbal 1/susCymb1_cresc_2s.wav', 1)]], 3.2, 44100),
}
UI = dict(group='ui')
DRUMS.update({
    'ui_wood': ('VCSL, caja china suave (CC0)', [[(VCSL + I + f'Woodblock/wood_click_pp_rr{r}.wav', 1)] for r in (1, 2, 3)], .25, 44100, UI),
    'ui_woodf': ('VCSL, caja china media y fuerte (CC0)', [[(VCSL + I + 'Woodblock/' + f, 1)] for f in ('wood_click_mp.wav', 'wood_click_f_rr1.wav', 'wood_click_f_rr2.wav')], .3, 44100, UI),
    'ui_clave': ('Virtuosity Drums, claves suaves (CC0)', [[(VIR + f'perc/mid/claves/Claves1_Hit_v1_rr{r}_Mid.wav', 1)] for r in (1, 2)], .25, 44100, UI),
    'ui_paper': ('Virtuosity Drums, cabasa frotada (papel) (CC0)', [[(VIR + f'perc/mid/cabasa/Cabasa1_Rub_v1_rr{r}_Mid.wav', 1)] for r in (1, 2, 3)], .45, 44100, UI),
    'ui_tri': ('VCSL, triángulo apagado (CC0)', [[(VCSL + I + 'Triangles/Legacy/1/triangle1_hit_pp_muted.wav', 1)], [(VCSL + I + 'Triangles/Triangle1_HitM_v1_rr2_Mid.wav', 1)]], .5, 44100, UI),
    'ui_finger': ('VCSL, crótalos (CC0)', [[(VCSL + I + 'Finger Cymbals/Fing_Cymb.wav', 1)]], 2.0, 44100, UI),
    'ui_shimmer': ('VCSL, carillón de barras ascendente y descendente (CC0)', [[(VCSL + I + 'Mark Trees/Legacy/windchimes_asc1.wav', 1)], [(VCSL + I + 'Mark Trees/Legacy/windchimes_desc1.wav', 1)]], 2.5, 44100, UI),
    'ui_anvil': ('VCSL, yunque suave (CC0)', [[(VCSL + I + f'Anvil/Anvil_Hit{h}_v1_rr1_Mid.wav', 1)] for h in (1, 2)], 1.2, 44100, UI),
})
DRUM_GROUP = 'percusion'


def fetch(url, tries=5):
    """Descarga con caché local; None si no existe (404). Reintenta los cortes de red."""
    import http.client, time
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, urllib.parse.unquote(url.split('://', 1)[1]).replace('/', '__'))
    if os.path.exists(path):
        return path
    if os.path.exists(path + '.404'):
        return None
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(urllib.parse.quote(url, safe=':/')), timeout=120) as r, open(path + '.part', 'wb') as f:
                f.write(r.read())
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                open(path + '.404', 'w').close()
                return None
            if k == tries - 1:
                raise
        except (http.client.IncompleteRead, urllib.error.URLError, ConnectionError, TimeoutError):
            if k == tries - 1:
                raise
        time.sleep(2 ** (k + 1))
    os.replace(path + '.part', path)
    return path


def load(path, sr, stereo):
    """Decodifica a float32 (mono o estéreo) con ffmpeg."""
    ch = 2 if stereo else 1
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-ac', str(ch), '-ar', str(sr), '-f', 'f32le', '-'],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).copy()
    return x.reshape(-1, 2) if stereo else x


def mono(x):
    return x.mean(axis=1) if x.ndim == 2 else x


def onset(x, rel=.02):
    m = np.abs(mono(x))
    peak = np.max(m) or 1
    return max(0, int(np.argmax(m > rel * peak)) - 64)


def pitch(x, sr, drum=False):
    import librosa
    y = mono(x)
    seg = y[int(.08 * sr): int(1.1 * sr)]
    f0, voiced, _ = librosa.pyin(seg, fmin=30, fmax=400 if drum else 4200, sr=sr, frame_length=4096)
    f = f0[voiced & ~np.isnan(f0)] if np.any(voiced) else f0[~np.isnan(f0)]
    return float(69 + 12 * np.log2(np.median(f) / 440)) if len(f) else None


def name_midi(url):
    """Altura según el nombre del fichero (convenio científico), solo para el informe."""
    base = os.path.basename(urllib.parse.unquote(url))
    m = re.search(r'(?:^|_)([A-Ga-g])(#|s|b)?(-?\d)(?=[_.v])', base)
    if not m:
        return None
    acc = {'#': 1, 's': 1, 'b': -1}.get(m.group(2), 0)
    return 12 * (int(m.group(3)) + 1) + PC[m.group(1).upper()] + acc


def shape(x, sr, length, fade_frac=.3):
    x = x[onset(x):]
    n = min(len(x), int(length * sr))
    x = x[:n].copy()
    f = max(1, int(n * fade_frac))
    env = np.cos(np.linspace(0, np.pi / 2, f)) ** 2
    x[-f:] *= env[:, None] if x.ndim == 2 else env
    ramp = np.linspace(0, 1, 32)
    x[:32] *= ramp[:, None] if x.ndim == 2 else ramp
    return x


def encode(x, sr, kbps):
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as t:
        sf.write(t.name, x, sr)
    mp3 = t.name[:-4] + '.mp3'
    ch = '2' if x.ndim == 2 else '1'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', t.name, '-ac', ch, '-c:a', 'libmp3lame', '-b:a', f'{kbps}k', mp3], check=True)
    data = open(mp3, 'rb').read()
    os.unlink(t.name); os.unlink(mp3)
    return data


def cover(cands, lo, hi, gap):
    """Pocas notas que cubran [lo, hi]: una nota solo se omite si sus vecinas quedan a `gap` semitonos o menos."""
    inside = sorted((c for c in cands if lo - gap <= c[0] <= hi + gap), key=lambda c: c[0])
    keep = inside[:1]
    for k in range(1, len(inside)):
        if k + 1 < len(inside) and inside[k + 1][0] - keep[-1][0] <= gap:
            continue
        keep.append(inside[k])
    return keep


def rms(x, sr):
    seg = mono(x)[: int(.4 * sr)]
    return float(np.sqrt(np.mean(seg ** 2)) + 1e-9)


def build_tonal(name, spec):
    sr, stereo, kbps = spec.get('sr', 32000), spec.get('stereo', False), spec.get('kbps', 56 if not spec.get('stereo') else 96)
    cands = []
    for urls in spec['cands']:
        paths = [fetch(u) for u in urls]
        if not any(paths):
            continue
        paths = [p or next(q for q in reversed(paths[:i] + paths[i:]) if q) for i, p in enumerate(paths)]  # capa ausente → la vecina
        layers = [load(p, sr, stereo) for p in paths]
        loud = layers[-1]
        if spec.get('nopitch'):
            m, cents = len(cands) * 4 + spec['range'][0], 0.0  # redobles de timbal: altura poco definida, se reparten
            p = pitch(loud[onset(loud):], sr)
            if p is not None and spec['range'][0] - 6 <= p <= spec['range'][1] + 6:
                m, cents = int(round(p)), p - round(p)
        else:
            p = pitch(loud[onset(loud):], sr, drum=spec.get('drum', False))
            if p is None:
                print('  sin altura:', urls[-1]); continue
            m, cents = int(round(p)), p - round(p)
        cands.append([m, urls[-1], layers, cents])
    # cada biblioteca numera las octavas a su manera: el desfase típico entre nombre y altura detectada corrige
    # los errores de octava del detector (si la detección se aleja más de 1,5 semitonos de lo esperado)
    named = [c[0] - name_midi(c[1]) for c in cands if name_midi(c[1]) is not None]
    if named and not spec.get('nopitch'):
        off = int(np.median(named))
        for c in cands:
            guess = name_midi(c[1])
            if guess is not None and abs(c[0] + c[3] - (guess + off)) > 1.5:
                print(f'  {name}: {os.path.basename(c[1])} detectada {c[0]}, se usa {guess + off}')
                c[0], c[3] = guess + off, 0.0
    chosen = cover([tuple(c) for c in cands], *spec['range'], spec['gap'])
    notes, tune, data, report, total = [], [], [[] for _ in chosen[0][2]], [], 0
    long_, short = spec['len']
    for m, url, layers, cents in chosen:
        frac = (m - spec['range'][0]) / max(1, spec['range'][1] - spec['range'][0])
        length = long_ + (short - long_) * min(1, max(0, frac))
        shaped = [shape(x, sr, length) for x in layers]
        g = .12 / rms(shaped[-1], sr)  # misma ganancia para todas las capas: se conserva la diferencia p/f
        peak = max(np.max(np.abs(y)) for y in shaped) * g
        if peak > .98:
            g *= .98 / peak
        for k, y in enumerate(shaped):
            b = encode(y * g, sr, kbps)
            data[k].append(base64.b64encode(b).decode()); total += len(b)
        notes.append(m)
        tune.append(round(cents, 2) if abs(cents) >= .25 else 0)  # timbales y notas desafinadas: se corrige al tocar
        guess = name_midi(url)
        report.append(f'{m}{"" if guess is None else f"(nombre {guess})"}{cents:+.2f}')
    entry = {'kind': 'tonal', 'sr': sr, 'notes': notes, 'layers': data}
    if any(tune):
        entry['tune'] = tune
    return entry, f'{name}: {spec["src"]}. Notas MIDI {", ".join(report)}; {len(data)} capa(s).', total


def build_drum(name, src, variants, length, sr, fx=None):
    """Percusión: cada variante suma los micrófonos de una toma; fx permite transportar (rate), apagar (decay, s)
    y filtrar graves (hp, Hz), para las castañuelas aproximadas."""
    fx = fx or {}
    mixes = []
    for parts in variants:
        sig = None
        for url, gain in parts:
            p = fetch(url)
            if p is None:
                continue
            x = load(p, sr, False) * gain
            sig = x if sig is None else (np.pad(sig, (0, max(0, len(x) - len(sig)))) + np.pad(x, (0, max(0, len(sig) - len(x)))))
        if sig is None:
            continue
        if fx.get('rate'):  # transporte por remuestreo (más agudo y más corto)
            n = int(len(sig) / fx['rate'])
            sig = np.interp(np.arange(n) * fx['rate'], np.arange(len(sig)), sig).astype(np.float32)
        sig = sig[onset(sig):]
        if fx.get('hp'):
            a = np.exp(-2 * np.pi * fx['hp'] / sr); y = np.zeros_like(sig); prev_x = prev_y = 0.0
            for i, v in enumerate(sig):
                prev_y = a * (prev_y + v - prev_x); prev_x = v; y[i] = prev_y
            sig = y
        if fx.get('decay'):
            sig = sig * np.exp(-np.arange(len(sig)) / (fx['decay'] * sr)).astype(np.float32)
        mixes.append(shape(sig, sr, length, .3))
    peak = max(np.max(np.abs(y)) for y in mixes) or 1
    out, total = [], 0
    for y in mixes:
        b = encode(y * (.9 / peak), sr, 80 if sr == 44100 else 56)
        out.append(base64.b64encode(b).decode()); total += len(b)
    return {'kind': 'drum', 'sr': sr, 'data': out}, f'{name}: {src}; {len(out)} variante(s).', total


def main():
    only = set(os.environ.get('SOLO', '').split(',')) - {''}
    groups, index, credits, sizes = {}, {}, [], {}
    old = {}
    for g in ('orquesta', 'teclas', 'percusion', 'ui'):
        path = os.path.join(ASSETS, f'muestras-{g}.js')
        if only and os.path.exists(path):  # reconstrucción parcial: conserva el resto
            s = open(path, encoding='utf-8').read()
            mark = 'Object.assign(globalThis.IBERIA_SAMPLES, '
            old.update(json.loads(s[s.index(mark) + len(mark): s.rindex(')')]))
    for name, spec in TONAL.items():
        if only and name not in only:
            if name in old:
                groups.setdefault(spec['group'], {})[name] = old[name]; index[name] = spec['group']
            continue
        entry, credit, total = build_tonal(name, spec)
        groups.setdefault(spec['group'], {})[name] = entry; index[name] = spec['group']; credits.append(credit); sizes[name] = total
        print(f'{name:9} {len(entry["notes"])} notas × {len(entry["layers"])} capas {entry["notes"]} {total / 1024:.0f} KB', flush=True)
    for name, (src, variants, length, sr, *fx) in DRUMS.items():
        group = (fx[0] if fx else {}).get('group', DRUM_GROUP)
        if only and name not in only:
            if name in old:
                groups.setdefault(group, {})[name] = old[name]; index[name] = group
            continue
        entry, credit, total = build_drum(name, src, variants, length, sr, fx[0] if fx else None)
        groups.setdefault(group, {})[name] = entry; index[name] = group; credits.append(credit); sizes[name] = total
        print(f'{name:9} {len(entry["data"])} variante(s) {total / 1024:.0f} KB', flush=True)
    for g, bank in groups.items():
        with open(os.path.join(ASSETS, f'muestras-{g}.js'), 'w', encoding='utf-8') as f:
            f.write('// Generado por tools/build_samples.py: instrumentos muestreados (MP3). Créditos en investigacion/musica/MUESTRAS.txt.\n')
            f.write('(globalThis.IBERIA_SAMPLES = globalThis.IBERIA_SAMPLES || {}), Object.assign(globalThis.IBERIA_SAMPLES, ')
            f.write(json.dumps(bank, separators=(',', ':')) + ');\n')
    with open(os.path.join(ASSETS, 'samples-index.js'), 'w', encoding='utf-8') as f:
        f.write('// Generado por tools/build_samples.py: fichero de muestras que contiene cada instrumento.\n')
        f.write('export const SAMPLE_INDEX = ' + json.dumps(index, separators=(',', ':')) + ';\n')
    if not only:
        os.makedirs(os.path.dirname(CREDITS), exist_ok=True)
        with open(CREDITS, 'w', encoding='utf-8') as f:
            f.write('MUESTRAS DE LA BANDA SONORA (dist/assets/muestras-*.js)\n\n'
                    'Generadas con tools/build_samples.py a partir de bibliotecas libres. La música (melodías, armonías y arreglos)\n'
                    'es composición original del proyecto; las muestras solo dan el timbre de los instrumentos.\n\n'
                    'Licencias:\n'
                    '- VSCO 2 Community Edition y VCSL, Versilian Studios: CC0 (https://github.com/sgossner/VSCO-2-CE, https://github.com/sgossner/VCSL).\n'
                    '- Salamander Grand Piano V3, Alexander Holm: CC BY 3.0 (https://github.com/sfzinstruments/SalamanderGrandPiano).\n'
                    '- jRhodes3d, Jeff Learman: muestras CC BY-NC 4.0, uso no comercial (https://github.com/sfzinstruments/jlearman.jRhodes3d).\n'
                    '- Virtuosity Drums: CC0 (https://github.com/sfzinstruments/virtuosity_drums).\n'
                    '- Contrabajo de D. Smolken: CC0 (https://github.com/sfzinstruments/dsmolken.double-bass).\n'
                    '- Weresax, Karoryfer: CC0 (https://github.com/sfzinstruments/karoryfer.weresax).\n'
                    '- tonejs-instruments, Nicholaus P. Brosowsky: CC BY 3.0 (https://github.com/nbrosowsky/tonejs-instruments).\n\n'
                    'Instrumentos (altura detectada; entre paréntesis, la que indica el nombre del fichero; desviación en semitonos):\n')
            f.write('\n'.join(credits) + '\n')
    for g in groups:
        p = os.path.join(ASSETS, f'muestras-{g}.js')
        print(f'muestras-{g}.js: {os.path.getsize(p) / 1e6:.2f} MB')


if __name__ == '__main__':
    main()
