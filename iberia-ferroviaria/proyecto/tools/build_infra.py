#!/usr/bin/env python3
"""Genera dist/assets/infra.js: la red de vías del juego con su ancho y su electrificación.

Uso (desde proyecto/):  python3 tools/build_infra.py

Qué hace:
  * Define los nodos (estaciones de ciudad y bifurcaciones) y los tramos de la red que interesan a AVE y Alvia:
    líneas de alta velocidad, líneas convencionales por las que circulan o pueden circular los Alvia y las
    líneas de alta velocidad proyectadas.
  * Traza cada tramo sobre las vías OSM (railways-iberia-compact.json) entre sus estaciones, por tramos de paso
    cuando hace falta, y mide a lo largo del trazado el ancho de vía, la electrificación y la velocidad máxima.
  * El estado medido es el de 2026; las obras terminadas entre 2022 y 2026 se deshacen para el arranque de la
    campaña y se vuelven a aplicar en su fecha real (obras históricas).
"""
import collections, heapq, json, math, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INV = os.path.join(os.path.dirname(ROOT), 'investigacion')
RAIL = os.path.join(INV, 'railgeo', 'railways-iberia-compact.json')
OUT = os.path.join(ROOT, 'dist', 'assets', 'infra.js')
REPORT = os.path.join(INV, 'red', 'informe-red.json')
sys.path.insert(0, HERE)
from build_timetable import encode_polyline, simplify, hav, length_km  # noqa: E402

# ---------------------------------------------------------------- nodos
# id: (nombre, lon, lat, tipo, puertos). Coordenadas de la estación principal; los puertos son otras estaciones
# del mismo nodo (alta velocidad y convencional no siempre comparten estación).
NODES = {
    'mad': ('Madrid', -3.69089, 40.40644, 'city', {'cham': (-3.68295, 40.47118)}),
    'bcn': ('Barcelona', 2.14102, 41.37986, 'city', {}),
    'vlc': ('València', -0.38292, 39.45905, 'city', {'nord': (-0.37722, 39.46693)}),
    'ali': ('Alicante', -0.49552, 38.34471, 'city', {}),
    'elx': ('Elche', -0.76675, 38.24551, 'city', {'parc': (-0.69522, 38.27178)}),
    'mur': ('Murcia', -1.13151, 37.97482, 'city', {}),
    'car': ('Cartagena', -0.97512, 37.60497, 'city', {}),
    'lor': ('Lorca', -1.69623, 37.67211, 'city', {}),
    'alm': ('Almería', -2.45552, 36.83495, 'city', {}),
    'gra': ('Granada', -3.60915, 37.18404, 'city', {}),
    'mal': ('Málaga', -4.43139, 36.71134, 'city', {}),
    'sev': ('Sevilla', -5.97493, 37.3925, 'city', {}),
    'cor': ('Córdoba', -4.78945, 37.88829, 'city', {}),
    'cad': ('Cádiz', -6.28797, 36.52893, 'city', {}),
    'jer': ('Jerez', -6.1266, 36.68002, 'city', {}),
    'hue': ('Huelva', -6.94482, 37.25259, 'city', {}),
    'alg': ('Algeciras', -5.45111, 36.12683, 'city', {}),
    'ron': ('Ronda', -5.16197, 36.7484, 'city', {}),
    'ant': ('Antequera', -4.71901, 37.06988, 'city', {'boba': (-4.72794, 37.03707)}),
    'jae': ('Jaén', -3.7908, 37.77983, 'city', {}),
    'lin': ('Linares', -3.5894, 38.06886, 'city', {}),
    'cic': ('Ciudad Real', -3.91363, 38.9853, 'city', {}),
    'pue': ('Puertollano', -4.11165, 38.69128, 'city', {}),
    'cue': ('Cuenca', -2.14441, 40.03519, 'city', {}),
    'req': ('Requena', -1.1276, 39.51983, 'city', {}),
    'alb': ('Albacete', -1.84845, 38.99938, 'city', {}),
    'xat': ('Xàtiva', -0.52454, 38.99215, 'city', {}),
    'enc': ('La Encina', -0.95424, 38.76534, 'junction', {}),
    'cas': ('Castelló', -0.05235, 39.98847, 'city', {}),
    'sag': ('Sagunt', -0.27154, 39.6758, 'city', {}),
    'ter': ('Teruel', -1.11028, 40.34103, 'city', {}),
    'tar': ('Tarragona', 1.27267, 41.19207, 'city', {'ciutat': (1.25323, 41.11156)}),
    'gir': ('Girona', 2.81694, 41.97936, 'city', {}),
    'fig': ('Figueres', 2.94355, 42.26477, 'city', {}),
    'per': ('Perpiñán', 2.88038, 42.69642, 'foreign', {}),
    'zar': ('Zaragoza', -0.91127, 41.65866, 'city', {}),
    'lle': ('Lleida', 0.63365, 41.62013, 'city', {}),
    'huc': ('Huesca', -0.40975, 42.13359, 'city', {}),
    'tdn': ('Tardienta', -0.53822, 41.97572, 'junction', {}),
    'cal': ('Calatayud', -1.63868, 41.34669, 'city', {}),
    'gua': ('Guadalajara', -3.1243, 40.58731, 'city', {'ciudad': (-3.18226, 40.64419)}),
    'trb': ('Torralba', -2.4934, 41.1574, 'junction', {}),
    'sor': ('Soria', -2.47654, 41.75475, 'city', {}),
    'tol': ('Toledo', -4.01124, 39.86227, 'city', {}),
    'alc': ('Alcázar de S. Juan', -3.20574, 39.39563, 'city', {}),
    'mor': ('Moreda', -3.31052, 37.43122, 'junction', {}),
    'utr': ('Utrera', -5.79075, 37.18482, 'junction', {}),
    'mot': ('Motilla', -2.7533, 40.0316, 'junction', {}),
    'mnc': ('Monforte del Cid', -0.7398, 38.4027, 'junction', {}),
    'seg': ('Segovia', -4.09456, 40.91058, 'city', {}),
    'olm': ('Olmedo', -4.665, 41.29, 'junction', {}),
    'med': ('Medina del Campo', -4.91007, 41.31746, 'city', {}),
    'vll': ('Valladolid', -4.72699, 41.64217, 'city', {}),
    'avi': ('Ávila', -4.68331, 40.65725, 'city', {}),
    'sal': ('Salamanca', -5.64899, 40.97223, 'city', {}),
    'zam': ('Zamora', -5.73968, 41.51589, 'city', {}),
    'vdb': ('Venta de Baños', -4.4876, 41.9244, 'junction', {}),
    'pal': ('Palencia', -4.53414, 42.01571, 'city', {}),
    'leo': ('León', -5.58243, 42.59605, 'city', {}),
    'pol': ('Pola de Lena', -5.83103, 43.15872, 'junction', {}),
    'ovi': ('Oviedo', -5.85484, 43.36636, 'city', {}),
    'gij': ('Gijón', -5.67581, 43.53773, 'city', {}),
    'avl': ('Avilés', -5.92283, 43.56134, 'city', {}),
    'san': ('Santander', -3.81095, 43.4584, 'city', {}),
    'bur': ('Burgos', -3.66631, 42.3712, 'city', {}),
    'mir': ('Miranda de Ebro', -2.94037, 42.69102, 'city', {}),
    'vit': ('Vitoria', -2.6726, 42.84152, 'city', {}),
    'bil': ('Bilbao', -2.92856, 43.26013, 'city', {}),
    'ber': ('Bergara', -2.4183, 43.1006, 'junction', {}),
    'don': ('Donostia', -1.97672, 43.3177, 'city', {}),
    'iru': ('Irún', -1.80125, 43.33954, 'city', {}),
    'alt': ('Altsasu', -2.18124, 42.89485, 'junction', {}),
    'pam': ('Pamplona', -1.66142, 42.82488, 'city', {}),
    'cst': ('Castejón', -1.69211, 42.17272, 'junction', {}),
    'log': ('Logroño', -2.44219, 42.45746, 'city', {}),
    'ppf': ('Ponferrada', -6.60238, 42.54543, 'city', {}),
    'mfl': ('Monforte de Lemos', -7.50359, 42.52968, 'junction', {}),
    'our': ('Ourense', -7.87278, 42.35039, 'city', {}),
    'lug': ('Lugo', -7.55218, 43.01522, 'city', {}),
    'bet': ('Betanzos', -8.22585, 43.2707, 'junction', {}),
    'aco': ('A Coruña', -8.41556, 43.34969, 'city', {}),
    'fer': ('Ferrol', -8.23107, 43.48805, 'city', {}),
    'scq': ('Santiago', -8.5447, 42.87084, 'city', {}),
    'pon': ('Pontevedra', -8.63555, 42.42197, 'city', {}),
    'vig': ('Vigo', -8.71373, 42.23419, 'city', {}),
    'tal': ('Talavera', -4.82651, 39.97067, 'city', {}),
    'pla': ('Plasencia', -6.0994, 40.02228, 'city', {}),
    'cac': ('Cáceres', -6.38568, 39.46113, 'city', {}),
    'mer': ('Mérida', -6.34379, 38.9215, 'city', {}),
    'bad': ('Badajoz', -6.98175, 38.8907, 'city', {}),
}

# ---------------------------------------------------------------- tramos
# (a, b, clase, nombre, opciones). clase: 'lav' (alta velocidad) o 'conv' (convencional).
# opciones: via (puntos de paso), pa/pb (puerto de la estación en cada extremo), plan (proyecto que lo construye:
# el tramo no existe al empezar), hist (obras históricas: [(fecha, cambios)]), fix (corrige el estado de 2026),
# start (estado al empezar la campaña si difiere del de 2026).
LAV, CONV = 'lav', 'conv'
TRAMOS = [
    # Madrid–Barcelona–frontera francesa
    ('mad', 'gua', LAV, 'LAV Madrid — Guadalajara', {}),
    ('gua', 'cal', LAV, 'LAV Guadalajara — Calatayud', {}),
    ('cal', 'zar', LAV, 'LAV Calatayud — Zaragoza', {}),
    ('zar', 'lle', LAV, 'LAV Zaragoza — Lleida', {}),
    ('lle', 'tar', LAV, 'LAV Lleida — Camp de Tarragona', {}),
    ('tar', 'bcn', LAV, 'LAV Camp de Tarragona — Barcelona', {}),
    ('bcn', 'gir', LAV, 'LAV Barcelona — Girona', {}),
    ('gir', 'fig', LAV, 'LAV Girona — Figueres', {}),
    ('fig', 'per', LAV, 'Figueres — Perpiñán (Pertús)', {}),
    ('zar', 'tdn', LAV, 'LAV Zaragoza — Tardienta', {}),
    ('tdn', 'huc', CONV, 'Tardienta — Huesca', {}),
    # Madrid–Andalucía
    ('mad', 'tol', LAV, 'LAV Madrid — Toledo', {}),
    ('mad', 'cic', LAV, 'LAV Madrid — Ciudad Real', {}),
    ('cic', 'pue', LAV, 'LAV Ciudad Real — Puertollano', {}),
    ('pue', 'cor', LAV, 'LAV Puertollano — Córdoba', {}),
    ('cor', 'sev', LAV, 'LAV Córdoba — Sevilla', {}),
    ('cor', 'ant', LAV, 'LAV Córdoba — Antequera', {}),
    ('ant', 'mal', LAV, 'LAV Antequera — Málaga', {}),
    ('ant', 'gra', LAV, 'LAV Antequera — Granada', {}),
    # Madrid–Levante
    ('mad', 'cue', LAV, 'LAV Madrid — Cuenca', {}),
    ('cue', 'mot', LAV, 'LAV Cuenca — Motilla', {}),
    ('mot', 'req', LAV, 'LAV Motilla — Requena', {}),
    ('req', 'vlc', LAV, 'LAV Requena — València', {}),
    ('mot', 'alb', LAV, 'LAV Motilla — Albacete', {}),
    ('alb', 'mnc', LAV, 'LAV Albacete — Monforte del Cid', {'via': [(-0.8733, 38.5853)]}),
    ('mnc', 'ali', LAV, 'LAV Monforte del Cid — Alicante', {}),
    ('mnc', 'elx', LAV, 'LAV Monforte del Cid — Elche', {}),
    ('elx', 'mur', LAV, 'LAV Elche — Murcia', {'via': [(-0.94461, 38.07793)], 'start': {'built': False}, 'hist': [('2022-12-20', {'built': True})]}),
    # Madrid–Norte y Galicia
    ('mad', 'seg', LAV, 'LAV Madrid — Segovia', {'pa': 'cham'}),
    ('seg', 'olm', LAV, 'LAV Segovia — Olmedo', {}),
    ('olm', 'vll', LAV, 'LAV Olmedo — Valladolid', {}),
    ('olm', 'med', LAV, 'LAV Olmedo — Medina del Campo', {'fix': {'gauge': 'std', 'speed': 250}}),
    ('med', 'zam', LAV, 'LAV Medina del Campo — Zamora', {}),
    ('zam', 'our', LAV, 'LAV Zamora — Ourense', {'via': [(-6.56313, 42.04505)]}),
    ('our', 'scq', LAV, 'LAV Ourense — Santiago', {}),
    ('vll', 'vdb', LAV, 'LAV Valladolid — Venta de Baños', {}),
    ('vdb', 'pal', LAV, 'LAV Venta de Baños — Palencia', {}),
    ('pal', 'leo', LAV, 'LAV Palencia — León', {}),
    ('vdb', 'bur', LAV, 'LAV Venta de Baños — Burgos', {'start': {'built': False}, 'hist': [('2022-07-21', {'built': True, 'changer': True})]}),
    ('leo', 'pol', CONV, 'León — Pola de Lena (Pajares)', {'fix': {'gauge': 'mixto'}, 'start': {'gauge': 'ib', 'elec': '3kv', 'speed': 70},
                                                                'hist': [('2023-11-29', {'gauge': 'mixto', 'elec': '25kv', 'speed': 220, 'changer': True})]}),
    # Convencional: Castilla y León
    ('mad', 'avi', CONV, 'Madrid — Ávila', {'pa': 'cham'}),
    ('avi', 'med', CONV, 'Ávila — Medina del Campo', {}),
    ('med', 'vll', CONV, 'Medina del Campo — Valladolid', {}),
    ('med', 'sal', CONV, 'Medina del Campo — Salamanca', {}),
    ('avi', 'sal', CONV, 'Ávila — Salamanca', {'via': [(-5.0, 40.85)]}),
    ('vll', 'vdb', CONV, 'Valladolid — Venta de Baños', {}),
    ('vdb', 'pal', CONV, 'Venta de Baños — Palencia', {}),
    ('vdb', 'bur', CONV, 'Venta de Baños — Burgos', {}),
    ('pal', 'san', CONV, 'Palencia — Santander', {'via': [(-4.14095, 42.9945), (-4.04269, 43.32768)]}),
    ('leo', 'ppf', CONV, 'León — Ponferrada', {}),
    # Convencional: norte
    ('bur', 'mir', CONV, 'Burgos — Miranda de Ebro', {}),
    ('mir', 'vit', CONV, 'Miranda de Ebro — Vitoria', {}),
    ('vit', 'alt', CONV, 'Vitoria — Altsasu', {}),
    ('alt', 'don', CONV, 'Altsasu — Donostia', {}),
    ('don', 'iru', CONV, 'Donostia — Irún', {}),
    ('mir', 'bil', CONV, 'Miranda de Ebro — Bilbao', {}),
    ('mir', 'log', CONV, 'Miranda de Ebro — Logroño', {}),
    ('log', 'cst', CONV, 'Logroño — Castejón', {}),
    ('cst', 'zar', CONV, 'Castejón — Zaragoza', {}),
    ('cst', 'pam', CONV, 'Castejón — Pamplona', {}),
    ('pam', 'alt', CONV, 'Pamplona — Altsasu', {}),
    ('pol', 'ovi', CONV, 'Pola de Lena — Oviedo', {}),
    ('ovi', 'gij', CONV, 'Oviedo — Gijón', {}),
    ('ovi', 'avl', CONV, 'Oviedo — Avilés', {}),
    # Convencional: Galicia
    ('ppf', 'mfl', CONV, 'Ponferrada — Monforte de Lemos', {}),
    ('mfl', 'our', CONV, 'Monforte de Lemos — Ourense', {}),
    ('our', 'vig', CONV, 'Ourense — Vigo (por Guillarei)', {'via': [(-8.142, 42.288), (-8.62253, 42.06566), (-8.6194, 42.28601)]}),
    ('mfl', 'lug', CONV, 'Monforte de Lemos — Lugo', {}),
    ('lug', 'bet', CONV, 'Lugo — Betanzos', {}),
    ('bet', 'aco', CONV, 'Betanzos — A Coruña', {}),
    ('bet', 'fer', CONV, 'Betanzos — Ferrol', {}),
    ('aco', 'scq', CONV, 'Eje atlántico: A Coruña — Santiago', {}),
    ('scq', 'pon', CONV, 'Eje atlántico: Santiago — Pontevedra', {}),
    ('pon', 'vig', CONV, 'Eje atlántico: Pontevedra — Vigo', {}),
    # Convencional: Aragón, Soria y Mediterráneo
    ('mad', 'gua', CONV, 'Madrid — Guadalajara', {'pb': 'ciudad'}),
    ('gua', 'trb', CONV, 'Guadalajara — Torralba', {'pa': 'ciudad'}),
    ('trb', 'sor', CONV, 'Torralba — Soria', {}),
    ('zar', 'ter', CONV, 'Zaragoza — Teruel', {}),
    ('ter', 'sag', CONV, 'Teruel — Sagunt', {}),
    ('sag', 'vlc', CONV, 'Sagunt — València', {'pb': 'nord', 'fix': {'gauge': 'mixto'}}),
    ('sag', 'cas', CONV, 'Sagunt — Castelló', {'fix': {'gauge': 'mixto'}}),
    ('cas', 'tar', CONV, 'Castelló — Tarragona', {'pb': 'ciutat', 'via': [(0.45573, 40.47168), (0.61431, 40.75356)]}),
    ('tar', 'bcn', CONV, 'Tarragona — Barcelona', {'pa': 'ciutat'}),
    ('vlc', 'xat', CONV, 'València — Xàtiva', {'pa': 'nord', 'via': [(-0.41498, 39.36195)]}),
    ('xat', 'enc', CONV, 'Xàtiva — La Encina', {}),
    ('enc', 'alb', CONV, 'La Encina — Albacete', {}),
    ('enc', 'ali', CONV, 'La Encina — Alicante', {}),
    ('ali', 'mur', CONV, 'Alicante — Murcia (por Elche)', {'via': [(-0.69522, 38.27178), (-0.88, 38.12), (-0.94461, 38.07793)]}),
    ('alb', 'mur', CONV, 'Albacete — Murcia (por Hellín)', {'via': [(-1.72, 38.92), (-1.68844, 38.50878), (-1.4217, 38.24661)]}),
    ('mur', 'car', CONV, 'Murcia — Cartagena', {}),
    # Convencional: Madrid–Andalucía y Extremadura
    ('mad', 'alc', CONV, 'Madrid — Alcázar de San Juan', {'via': [(-3.61825, 40.03503)]}),
    ('alc', 'alb', CONV, 'Alcázar de San Juan — Albacete', {}),
    ('alc', 'lin', CONV, 'Alcázar de San Juan — Linares', {'via': [(-3.37051, 39.00584)]}),
    ('lin', 'jae', CONV, 'Linares — Jaén', {}),
    ('lin', 'cor', CONV, 'Linares — Córdoba', {}),
    ('lin', 'mor', CONV, 'Linares — Moreda', {}),
    ('mor', 'gra', CONV, 'Moreda — Granada', {}),
    ('mor', 'alm', CONV, 'Moreda — Almería', {'via': [(-3.12721, 37.31687), (-2.43, 36.88)]}),
    ('cor', 'ant', CONV, 'Córdoba — Bobadilla', {'pb': 'boba'}),
    ('ant', 'ron', CONV, 'Bobadilla — Ronda', {'pa': 'boba'}),
    ('ron', 'alg', CONV, 'Ronda — Algeciras', {}),
    ('sev', 'utr', CONV, 'Sevilla — Utrera', {}),
    ('utr', 'jer', CONV, 'Utrera — Jerez', {}),
    ('jer', 'cad', CONV, 'Jerez — Cádiz', {'via': [(-6.2311, 36.5951), (-6.1979, 36.4659)]}),
    ('sev', 'hue', CONV, 'Sevilla — Huelva', {}),
    ('mer', 'sev', CONV, 'Mérida — Sevilla (por Zafra)', {'via': [(-6.40508, 38.41363)]}),
    ('mad', 'tal', CONV, 'Madrid — Talavera', {}),
    ('tal', 'pla', CONV, 'Talavera — Plasencia', {'via': [(-5.54561, 39.89491)]}),
    ('pla', 'cac', CONV, 'Plasencia — Cáceres', {'start': {'elec': 'no', 'speed': 110}, 'hist': [('2022-07-19', {'speed': 180}), ('2023-12-14', {'elec': '25kv'})]}),
    ('cac', 'mer', CONV, 'Cáceres — Mérida', {'start': {'elec': 'no', 'speed': 110}, 'hist': [('2022-07-19', {'speed': 180}), ('2023-12-14', {'elec': '25kv'})]}),
    ('mer', 'bad', CONV, 'Mérida — Badajoz', {'start': {'elec': 'no', 'speed': 120}, 'hist': [('2022-07-19', {'speed': 180}), ('2023-12-14', {'elec': '25kv'})]}),
    # Alta velocidad proyectada (se construye con los grandes proyectos de la campaña)
    ('mur', 'lor', LAV, 'LAV Murcia — Lorca', {'plan': 'almeria', 'via': [(-1.41451, 37.8494)]}),
    ('lor', 'alm', LAV, 'LAV Lorca — Almería', {'plan': 'almeria', 'via': [(-1.75, 37.40), (-1.86, 37.25), (-2.2, 36.97)]}),
    ('vit', 'ber', LAV, 'Y vasca: Vitoria — Bergara', {'plan': 'basque', 'via': [(-2.49, 43.06)]}),
    ('ber', 'bil', LAV, 'Y vasca: Bergara — Bilbao', {'plan': 'basque', 'via': [(-2.73, 43.22)]}),
    ('ber', 'don', LAV, 'Y vasca: Bergara — Donostia', {'plan': 'basque', 'via': [(-2.25, 43.04), (-2.07, 43.14), (-1.95, 43.28)]}),
    ('bur', 'vit', LAV, 'LAV Burgos — Vitoria', {'plan': 'burgosvitoria', 'via': [(-3.11, 42.63), (-2.94, 42.71)]}),
    ('zar', 'cst', LAV, 'LAV Zaragoza — Castejón', {'plan': 'navarra', 'via': [(-1.32, 41.87), (-1.59793, 42.05943)]}),
    ('cst', 'pam', LAV, 'LAV Castejón — Pamplona', {'plan': 'navarra', 'via': [(-1.67, 42.52)]}),
    ('mad', 'tal', LAV, 'LAV Madrid — Talavera', {'plan': 'extremadura', 'via': [(-3.85, 40.12)]}),
    ('tal', 'pla', LAV, 'LAV Talavera — Plasencia', {'plan': 'extremadura', 'via': [(-5.18614, 39.92175), (-5.54561, 39.89491), (-5.6, 39.98)]}),
    ('mur', 'car', LAV, 'LAV Murcia — Cartagena', {'plan': 'cartagena', 'via': [(-0.95, 37.74)]}),
    ('pal', 'san', LAV, 'LAV Palencia — Santander', {'plan': 'cantabria', 'via': [(-4.36, 42.41), (-4.2339, 42.78536), (-4.14095, 42.9945), (-4.04269, 43.32768)]}),
    ('sev', 'hue', LAV, 'LAV Sevilla — Huelva', {'plan': 'huelva', 'via': [(-6.55, 37.38)]}),
    ('our', 'pon', LAV, 'LAV Ourense — Pontevedra (Cerdedo)', {'plan': 'cerdedo', 'via': [(-8.08, 42.43), (-8.39, 42.53)]}),
]

# Cambiadores de ancho con los que arranca la campaña (enero de 2022). El de Burgos llega con la LAV y el de
# Pola de Lena con la variante de Pajares (obras históricas).
CHANGERS_2022 = {
    'zar': 'Plasencia de Jalón', 'vll': 'Valdestillas', 'leo': 'León', 'med': 'Medina del Campo', 'our': 'Taboadela',
    'sev': 'Majarabique', 'cor': 'Córdoba', 'ant': 'Bobadilla', 'gra': 'Granada', 'alb': 'Albacete', 'tar': 'Roda de Berà',
}
CHANGER_NAMES = {'bur': 'Burgos', 'pol': 'Pola de Lena'}


# ---------------------------------------------------------------- grafo OSM con atributos
def gauge_class(g):
    g = str(g or '')
    return 'mixto' if ('1435' in g and '1668' in g) else 'std' if '1435' in g else 'met' if g.startswith('1000') else 'ib' if '1668' in g else '?'


def elec_class(p):
    e, v = str(p.get('electrified') or ''), str(p.get('voltage') or '')
    if e == 'no':
        return 'no'
    if e in ('contact_line', 'yes', 'rail') or v:
        return '25kv' if '25000' in v else '3kv' if '3000' in v else '1.5kv' if '1500' in v else '?'
    return '?'


class Rail:
    def __init__(self):
        d = json.load(open(RAIL, encoding='utf-8'))
        P = d['properties']
        self.nodes, idx, self.adj = [], {}, []
        def node(p):
            k = (round(p[0] * 1e5), round(p[1] * 1e5))
            i = idx.get(k)
            if i is None:
                i = idx[k] = len(self.nodes)
                self.nodes.append((p[0], p[1]))
                self.adj.append([])
            return i
        for pi, co in d['lines']:
            pr = P[pi]
            try:
                v = float(str(pr.get('maxspeed', '')).split(';')[0])
            except ValueError:
                v = 0
            g = gauge_class(pr.get('gauge'))
            if not v:
                v = 250 if g == 'std' else 70 if g == 'met' else 110
            ids = [node(p) for p in co]
            for a, b in zip(ids, ids[1:]):
                if a != b:
                    e = (hav(*self.nodes[a], *self.nodes[b]), g, elec_class(pr), v, pr.get('usage'), pr.get('name') or '')
                    self.adj[a].append((b, e))
                    self.adj[b].append((a, e))
        self.arr = np.array(self.nodes)
        deg1 = [i for i, a in enumerate(self.adj) if len(a) == 1]
        cell, grid = .0006, collections.defaultdict(list)
        for i, (x, y) in enumerate(self.nodes):
            grid[(int(x / cell), int(y / cell))].append(i)
        for i in deg1:
            x, y = self.nodes[i]
            best, bd = None, .045
            for gx in range(int(x / cell) - 1, int(x / cell) + 2):
                for gy in range(int(y / cell) - 1, int(y / cell) + 2):
                    for j in grid.get((gx, gy), []):
                        if j != i and not any(n == j for n, _ in self.adj[i]):
                            dd = hav(x, y, *self.nodes[j])
                            if dd < bd:
                                best, bd = j, dd
            if best is not None:
                e = (bd, '?', '?', 80, 'main', '')
                self.adj[i].append((best, e))
                self.adj[best].append((i, e))

    def near(self, lon, lat, r):
        d = np.hypot((self.arr[:, 0] - lon) * math.cos(math.radians(lat)), self.arr[:, 1] - lat) * 111.2
        idx = np.where(d < r)[0]
        return sorted(((float(d[i]), int(i)) for i in idx))[:40]

    @staticmethod
    def cost(e, prof):
        L, g, el, v, use, name = e
        v = max(30., min(v, 320.))
        if prof == 'lav':
            pen = 1. if g in ('std', 'mixto') else 4. if g == 'ib' else 12.
        else:
            pen = 1. if g in ('ib', 'mixto', '?') else 6. if g == 'std' else 12.
        return L / v * pen * (1. if use in ('main', 'branch', None) else 1.6)

    def leg(self, a, b, prof):
        src, dst = self.near(*a, 2.5), {n: d for d, n in self.near(*b, 2.5)}
        if not src or not dst:
            return None
        dist, prev, heap = {}, {}, []
        for d, n in src:
            dist[n] = d / 30.
            heapq.heappush(heap, (d / 30., n))
        best, bn = 1e18, None
        while heap:
            c, n = heapq.heappop(heap)
            if c > dist.get(n, 1e18) or c >= best:
                continue
            if n in dst and c + dst[n] / 30. < best:
                best, bn = c + dst[n] / 30., n
            for m, e in self.adj[n]:
                nc = c + self.cost(e, prof)
                if nc < dist.get(m, 1e18):
                    dist[m] = nc
                    prev[m] = (n, e)
                    heapq.heappush(heap, (nc, m))
        if bn is None:
            return None
        out, n = [], bn
        while n in prev:
            p, e = prev[n]
            out.append((n, e))
            n = p
        out.append((n, None))
        return out[::-1]


def trace(rail, pts, prof):
    """Recorre los puntos de paso: camino OSM por tramos y, si falta continuidad, enlace recto marcado."""
    coords, measured, straight = [pts[0]], [], 0.0
    for a, b in zip(pts, pts[1:]):
        direct = hav(*a, *b)
        path = rail.leg(a, b, prof) if direct > .05 else None
        L = sum(e[0] for _, e in path if e) if path else 0
        if not path or L > direct * 1.7 + 6:
            coords.append(b)
            straight += direct
            continue
        coords += [rail.nodes[n] for n, _ in path] + [b]
        measured += [e for _, e in path if e]
    return coords, measured, straight


def summarise(measured):
    km, gauge, elec = 0., collections.Counter(), collections.Counter()
    speed, names = 0., collections.Counter()
    for L, g, el, v, use, name in measured:
        km += L
        gauge[g] += L
        elec[el] += L
        speed += min(v, 300) * L
        if name:
            names[name] += L
    known = {k: v for k, v in gauge.items() if k in ('ib', 'std', 'mixto')}
    g = max(known, key=known.get) if known else 'ib'
    if km and gauge['mixto'] >= .35 * km:
        g = 'mixto'
    ke = {k: v for k, v in elec.items() if k in ('25kv', '3kv', 'no', '1.5kv')}
    e = max(ke, key=ke.get) if ke else 'no'
    if e == '1.5kv':
        e = '25kv'
    return {'gauge': g, 'elec': e, 'speed': speed / km if km else 0, 'mix': {k: round(v / km * 100) for k, v in gauge.most_common() if km},
            'elecMix': {k: round(v / km * 100) for k, v in elec.most_common() if km}, 'names': [n for n, _ in names.most_common(3)]}


def main():
    rail = Rail()
    print('grafo', len(rail.nodes), 'nodos')
    nodes_out, tramos_out, report, used_ids = [], [], [], collections.Counter()
    for nid, (name, lon, lat, kind, ports) in NODES.items():
        changer = CHANGERS_2022.get(nid)
        nodes_out.append({'id': nid, 'name': name, 'lon': round(lon, 5), 'lat': round(lat, 5), 'kind': kind,
                          **({'changer': changer} if changer else {}), **({'changerName': CHANGER_NAMES[nid]} if nid in CHANGER_NAMES else {})})
    for a, b, kind, name, o in TRAMOS:
        base = f'{a}-{b}' + ('' if kind == CONV else '-av')
        used_ids[base] += 1
        tid = base if used_ids[base] == 1 else f'{base}{used_ids[base]}'
        pa = NODES[a][4].get(o.get('pa')) or NODES[a][1:3]
        pb = NODES[b][4].get(o.get('pb')) or NODES[b][1:3]
        pts = [tuple(pa)] + [tuple(p) for p in o.get('via', [])] + [tuple(pb)]
        if o.get('plan'):
            coords, measured, straight = pts, [], length_km(pts)
            st = {'gauge': 'std', 'elec': '25kv', 'speed': 300 if kind == LAV else 160, 'mix': {}, 'elecMix': {}, 'names': []}
        else:
            coords, measured, straight = trace(rail, pts, kind)
            st = summarise(measured)
        km = length_km(coords)
        speed = int(round(max(60, min(300, st['speed'] or 120)) / 10) * 10)
        state = {'gauge': st['gauge'], 'elec': st['elec'], 'speed': speed}
        state.update(o.get('fix', {}))
        geom = simplify([tuple(c) for c in coords], .0004)
        t = {'id': tid, 'a': a, 'b': b, 'kind': kind, 'name': name, 'km': round(km, 1), **state,
             'g': encode_polyline(geom), 'approx': round(straight / max(km, .1), 2)}
        if o.get('plan'):
            t['plan'] = o['plan']
        if o.get('start'):
            t['start'] = o['start']
        if o.get('hist'):
            t['hist'] = [[d, c] for d, c in o['hist']]
        tramos_out.append(t)
        report.append({'id': tid, 'name': name, 'km': t['km'], 'state': state, 'osm': {'ancho': st['mix'], 'catenaria': st['elecMix'], 'lineas': st['names']},
                       'aproximado': t['approx']})
        flag = ' APROX' if t['approx'] > .15 else ''
        print(f"{tid:14} {name[:40]:40} {km:6.1f} km  {state['gauge']:5} {state['elec']:4} {speed:3} km/h  ancho {st['mix']} cat {st['elecMix']}{flag}")
    payload = {'nodes': nodes_out, 'tramos': tramos_out}
    os.makedirs(os.path.dirname(REPORT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Red de vías del juego (tools/build_infra.py): ancho, electrificación y velocidad medidos sobre © OpenStreetMap contributors (ODbL).\n')
        f.write('export const INFRA=' + json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + ';\n')
    json.dump(report, open(REPORT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(len(nodes_out), 'nodos,', len(tramos_out), 'tramos,', round(sum(t['km'] for t in tramos_out)), 'km →', OUT)


if __name__ == '__main__':
    main()
