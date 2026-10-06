#!/usr/bin/env python3
"""Genera dist/assets/timetable.js a partir de los GTFS oficiales de Renfe.

Uso (desde proyecto/):
    python3 tools/build_timetable.py [cercanias.zip] [av-ld-md.zip]

Requisitos: Python 3.9+ y numpy. Node.js se usa para leer data.js.

Qué hace:
  * Selecciona tres días tipo de los GTFS (laborable, sábado y domingo).
  * Conserva TODAS las circulaciones de esos días: Cercanías/Rodalies y AV/LD/MD.
  * Agrupa las paradas y tiempos en patrones para reducir tamaño.
  * Dibuja cada tramo entre paradas consecutivas sobre geometría real:
      - shapes.txt del GTFS de Cercanías cuando la parada está sobre el trazado;
      - si no, camino mínimo sobre las vías OSM (railways-iberia-compact.json)
        ponderado por ancho y velocidad según el producto.
  * Asigna cada circulación a una relación jugable de la campaña.
Los horarios son los publicados para octubre de 2026; no reconstruyen 2022.
"""
import collections, csv, datetime, heapq, io, json, math, os, re, subprocess, sys, unicodedata, zipfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INV = os.path.join(os.path.dirname(ROOT), 'investigacion')
CER_ZIP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(INV, 'gtfs', 'renfe-cercanias-2026-10-06.zip')
LD_ZIP = sys.argv[2] if len(sys.argv) > 2 else os.path.join(INV, 'gtfs', 'renfe-av-ld-md-2026-10-06.zip')
RAIL = os.path.join(INV, 'railgeo', 'railways-iberia-compact.json')
OUT = os.path.join(ROOT, 'dist', 'assets', 'timetable.js')
REPORT = os.path.join(INV, 'gtfs', 'timetable-report.json')
# v0.4: el juego se centra en AV/LD/MD; las circulaciones de Cercanías/Rodalies no se incluyen.
INCLUDE_CERCANIAS = os.environ.get('INCLUDE_CERCANIAS') == '1'
DAYS = {'L': '20261014', 'S': '20261017', 'D': '20261018'}
WEEK = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday']

PRODUCTS = {
    'AVE': ('AVE', 'av', 'hs'), 'AVLO': ('AVLO', 'av', 'hs'), 'AVANT': ('Avant', 'av', 'hs'),
    'AVANT EXP': ('Avant Exprés', 'av', 'hs'), 'AVE INT': ('AVE Internacional', 'av', 'hs'),
    'EUROMED': ('Euromed', 'av', 'mix'), 'ALVIA': ('Alvia', 'ld', 'mix'), 'Intercity': ('Intercity', 'ld', 'mix'),
    'MD': ('Media Distancia', 'md', 'conv'), 'REGIONAL': ('Regional', 'md', 'conv'),
    'REG.EXP.': ('Regional Exprés', 'md', 'conv'), 'PROXIMDAD': ('Proximidad', 'md', 'conv'),
    'TRENCELTA': ('Trencelta', 'md', 'conv'),
}
PRODUCT_COLORS = {'AVE': '#a3123a', 'AVLO': '#7b2d8e', 'Avant': '#c4462b', 'Avant Exprés': '#c4462b',
                  'AVE Internacional': '#a3123a', 'Euromed': '#b0306a', 'Alvia': '#2f6f9f', 'Intercity': '#3f7f8c',
                  'Media Distancia': '#c27a18', 'Regional': '#8a6d3b', 'Regional Exprés': '#a0782c',
                  'Proximidad': '#6f8a2e', 'Trencelta': '#5b7d6b'}
# Relaciones de la campaña v0.2 que corresponden a una línea de Cercanías publicada.
CERCANIAS_ALIASES = {'c-valencia-c2': 'valencia-xativa', 'c-asturias-c1': 'oviedo-gijon', 'c-sanSebastian-c1': 'donostia-irun',
                     'c-madrid-c2': 'madrid-guadalajara', 'c-valencia-c6': 'valencia-castellon'}
METRIC_LINES = {('20', c) for c in ['C4', 'C5', 'C5a', 'C6', 'C7', 'C8']} | {('62', 'C3'), ('62', 'R3'), ('47', 'C1'), ('46', 'C1'), ('45', 'C1')}


def rows(zf, name):
    with zf.open(name) as raw:
        reader = csv.reader(io.TextIOWrapper(raw, encoding='utf-8-sig', newline=''))
        head = [h.strip() for h in next(reader)]
        for r in reader:
            if r:
                yield dict(zip(head, (v.strip() for v in r)))


def minutes(t):
    if not t:
        return None
    h, m, s = (int(x) for x in t.split(':'))
    return h * 60 + m + (1 if s >= 30 else 0)


def hav(lon1, lat1, lon2, lat2):
    r = math.pi / 180
    a = math.sin((lat2 - lat1) * r / 2) ** 2 + math.cos(lat1 * r) * math.cos(lat2 * r) * math.sin((lon2 - lon1) * r / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(min(1, a)))


def slug(x):
    x = unicodedata.normalize('NFD', x).encode('ascii', 'ignore').decode().lower()
    return re.sub(r'[^a-z0-9]+', '-', x).strip('-')[:40]


def active_services(zf, has_dates, day):
    d = datetime.date(int(day[:4]), int(day[4:6]), int(day[6:]))
    out = set()
    for c in rows(zf, 'calendar.txt'):
        if c['start_date'] <= day <= c['end_date'] and c[WEEK[d.weekday()]] == '1':
            out.add(c['service_id'])
    if has_dates:
        for x in rows(zf, 'calendar_dates.txt'):
            if x['date'] == day:
                (out.add if x['exception_type'] == '1' else out.discard)(x['service_id'])
    return out


def encode_polyline(coords):
    """Algoritmo de polilínea de Google, precisión 1e5, sobre (lon, lat)."""
    out, plon, plat = [], 0, 0
    for lon, lat in coords:
        ilon, ilat = int(round(lon * 1e5)), int(round(lat * 1e5))
        for v in (ilon - plon, ilat - plat):
            v = ~(v << 1) if v < 0 else v << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1f)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        plon, plat = ilon, ilat
    return ''.join(out)


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    a = np.array(pts)
    keep = np.zeros(len(a), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(a) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        p, q = a[i], a[j]
        seg = a[i + 1:j]
        d = q - p
        n = math.hypot(d[0], d[1])
        if n == 0:
            dist = np.hypot(seg[:, 0] - p[0], seg[:, 1] - p[1])
        else:
            dist = np.abs(d[0] * (seg[:, 1] - p[1]) - d[1] * (seg[:, 0] - p[0])) / n
        k = int(np.argmax(dist))
        if dist[k] > tol:
            m = i + 1 + k
            keep[m] = True
            stack += [(i, m), (m, j)]
    return [tuple(x) for x in a[keep].tolist()]


def length_km(pts):
    return sum(hav(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]) for i in range(len(pts) - 1))


# ---------------------------------------------------------------- rail graph
class RailGraph:
    def __init__(self, path):
        data = json.load(open(path, encoding='utf-8'))
        props = data['properties']
        self.nodes, self.index, self.adj = [], {}, []
        def node(p):
            k = (round(p[0] * 1e5), round(p[1] * 1e5))
            i = self.index.get(k)
            if i is None:
                i = self.index[k] = len(self.nodes)
                self.nodes.append((p[0], p[1]))
                self.adj.append([])
            return i
        for pi, coords in data['lines']:
            pr = props[pi]
            g = str(pr.get('gauge', ''))
            gauge = 'mixed' if ('1435' in g and '1668' in g) else '1435' if '1435' in g else '1000' if g.startswith('1000') else '1668' if '1668' in g else '?'
            try:
                vmax = float(str(pr.get('maxspeed', '')).split(';')[0])
            except ValueError:
                vmax = 0
            if not vmax:
                vmax = 250 if gauge == '1435' else 70 if gauge == '1000' else 110
            main = pr.get('usage') in ('main', 'branch')
            ids = [node(p) for p in coords]
            for a, b in zip(ids, ids[1:]):
                if a == b:
                    continue
                L = hav(*self.nodes[a], *self.nodes[b])
                e = (L, gauge, vmax, main)
                self.adj[a].append((b, e))
                self.adj[b].append((a, e))
        self.arr = np.array(self.nodes)
        # Une extremos sueltos separados por pocos metros (cortes del extracto simplificado).
        deg1 = [i for i, a in enumerate(self.adj) if len(a) == 1]
        cell = 0.0006
        grid = collections.defaultdict(list)
        for i, (x, y) in enumerate(self.nodes):
            grid[(int(x / cell), int(y / cell))].append(i)
        self.grid, self.cell = grid, cell
        joined = 0
        for i in deg1:
            x, y = self.nodes[i]
            best, bd = None, 0.045
            for gx in range(int(x / cell) - 1, int(x / cell) + 2):
                for gy in range(int(y / cell) - 1, int(y / cell) + 2):
                    for j in grid.get((gx, gy), []):
                        if j == i or any(n == j for n, _ in self.adj[i]):
                            continue
                        d = hav(x, y, *self.nodes[j])
                        if d < bd:
                            best, bd = j, d
            if best is not None:
                e = (bd, '?', 80, True)
                self.adj[i].append((best, e))
                self.adj[best].append((i, e))
                joined += 1
        self.joined = joined

    def near(self, lon, lat, radius_km):
        d = np.hypot((self.arr[:, 0] - lon) * math.cos(math.radians(lat)), self.arr[:, 1] - lat) * 111.2
        idx = np.where(d < radius_km)[0]
        return sorted(((float(d[i]), int(i)) for i in idx))[:40]

    @staticmethod
    def cost(e, profile):
        L, gauge, vmax, main = e
        v = max(30.0, min(vmax, 320.0))
        if profile == 'hs':
            pen = 1.0 if gauge in ('1435', 'mixed') else 2.2
        elif profile == 'conv':
            pen = 1.0 if gauge in ('1668', 'mixed', '?') else 3.0 if gauge == '1435' else 9.0
            v = min(v, 200)
        elif profile == 'metric':
            pen = 1.0 if gauge in ('1000', '?') else 8.0
        else:  # mix
            pen = 1.0 if gauge != '1000' else 9.0
        return L / v * pen * (1.0 if main else 1.4)

    def route(self, sources, targets, profile, limit):
        """Dijkstra multiorigen. sources/targets: [(dist_km, node)]."""
        tset = {n: d for d, n in targets}
        dist, prev, heap = {}, {}, []
        for d, n in sources:
            c = d / 30.0
            if c < dist.get(n, 1e18):
                dist[n] = c
                heapq.heappush(heap, (c, n))
        best, bestn = 1e18, None
        while heap:
            c, n = heapq.heappop(heap)
            if c > dist.get(n, 1e18) or c > limit or c >= best:
                continue
            if n in tset:
                tc = c + tset[n] / 30.0
                if tc < best:
                    best, bestn = tc, n
            for m, e in self.adj[n]:
                nc = c + self.cost(e, profile)
                if nc < dist.get(m, 1e18):
                    dist[m] = nc
                    prev[m] = n
                    heapq.heappush(heap, (nc, m))
        if bestn is None:
            return None
        path = [bestn]
        while path[-1] in prev:
            path.append(prev[path[-1]])
        path.reverse()
        return [self.nodes[i] for i in path]


# ---------------------------------------------------------------- main
def main():
    game = json.loads(subprocess.check_output(['node', '--input-type=module', '-e', '''
import * as D from './dist/data.js';import {COMMUTER_NETWORKS} from './dist/assets/realdata.js';
console.log(JSON.stringify({cities:D.CITIES,routes:D.ROUTES,networks:COMMUTER_NETWORKS.map(n=>({id:n.id,name:n.name,center:String(n.centerStationId).padStart(5,'0'),lon:n.lon,lat:n.lat}))}));
'''], cwd=ROOT))
    cer, ld = zipfile.ZipFile(CER_ZIP), zipfile.ZipFile(LD_ZIP)
    feed_date = max(i.date_time for i in cer.infolist())
    print('Cercanías', CER_ZIP, feed_date)

    # --- estaciones
    stops = {}
    for zf in (ld, cer):
        for s in rows(zf, 'stops.txt'):
            stops[s['stop_id']] = (s['stop_name'], float(s['stop_lon']), float(s['stop_lat']))

    # --- líneas y circulaciones seleccionadas
    cer_routes = {r['route_id']: r for r in rows(cer, 'routes.txt')}
    ld_routes = {r['route_id']: r for r in rows(ld, 'routes.txt')}
    active = {k: (active_services(cer, False, d), active_services(ld, True, d)) for k, d in DAYS.items()}
    trips = {}  # trip_id -> dict
    for t in (rows(cer, 'trips.txt') if INCLUDE_CERCANIAS else []):
        r = cer_routes.get(t['route_id'])
        if not r or r['route_type'] not in ('2', '3'):
            continue
        days = [k for k in DAYS if t['service_id'] in active[k][0]]
        if days:
            # route_type 3: servicio alternativo por carretera publicado por Renfe (obras o cortes).
            trips[t['trip_id']] = dict(feed='cer', route=r, days=days, bus=r['route_type'] == '3', shape=t.get('shape_id', ''), block=t.get('block_id', ''))
    for t in rows(ld, 'trips.txt'):
        r = ld_routes.get(t['route_id'])
        if not r:
            continue
        days = [k for k in DAYS if t['service_id'] in active[k][1]]
        if days:
            trips[t['trip_id']] = dict(feed='ld', route=r, days=days, number=t.get('trip_short_name', ''))
    print('circulaciones seleccionadas', len(trips))

    times = collections.defaultdict(list)
    for zf in (cer, ld):
        with zf.open('stop_times.txt') as raw:
            reader = csv.reader(io.TextIOWrapper(raw, encoding='utf-8-sig', newline=''))
            head = [h.strip() for h in next(reader)]
            it, ia, idp, ist, isq = (head.index(x) for x in ('trip_id', 'arrival_time', 'departure_time', 'stop_id', 'stop_sequence'))
            for r in reader:
                tid = r[it].strip()
                if tid in trips:
                    times[tid].append((int(r[isq]), r[ist].strip(), minutes(r[ia].strip()), minutes(r[idp].strip())))
    for tid in list(trips):
        st = sorted(times.get(tid, []))
        st = [x for x in st if x[1] in stops]
        if len(st) < 2:
            del trips[tid]
            continue
        # completa horas ausentes
        for i, (q, s, a, d) in enumerate(st):
            a = a if a is not None else d
            d = d if d is not None else a
            st[i] = (q, s, a, d)
        if any(x[2] is None for x in st):
            del trips[tid]
            continue
        trips[tid]['stops'] = st
    print('con horario', len(trips))

    # --- núcleos
    prefixes = sorted({t['route']['route_id'][:2] for t in trips.values() if t['feed'] == 'cer'})
    pref_stops = collections.defaultdict(set)
    for t in trips.values():
        if t['feed'] == 'cer':
            pref_stops[t['route']['route_id'][:2]].update(s for _, s, _, _ in t['stops'])
    net_of = {}
    for p in prefixes:
        best = None
        for n in game['networks']:
            if n['center'] in pref_stops[p]:
                best = n
                break
        if not best:
            pts = [stops[s] for s in pref_stops[p]]
            lon = sum(x[1] for x in pts) / len(pts)
            lat = sum(x[2] for x in pts) / len(pts)
            best = min(game['networks'], key=lambda n: hav(lon, lat, n['lon'], n['lat']))
            if hav(lon, lat, best['lon'], best['lat']) > 60:
                best = {'id': 'n' + p, 'name': 'Núcleo ' + p}
        net_of[p] = best
    networks = []
    for p in prefixes:
        n = net_of[p]
        if not any(x['id'] == n['id'] for x in networks):
            networks.append({'id': n['id'], 'name': n['name'], 'prefixes': []})
        next(x for x in networks if x['id'] == n['id'])['prefixes'].append(p)
    print('núcleos', [(n['id'], n['prefixes']) for n in networks])

    # --- líneas
    lines, line_index = [], {}
    def line_for(t):
        r = t['route']
        if t['feed'] == 'cer':
            p, code = r['route_id'][:2], r['route_short_name']
            key = 'c' + p + '-' + code
            if key not in line_index:
                line_index[key] = len(lines)
                lines.append({'id': key, 'net': net_of[p]['id'], 'code': code, 'color': '#' + (r.get('route_color') or '777777'),
                              'kind': 'commuter', 'metric': (p, code) in METRIC_LINES, 'names': collections.Counter()})
            ln = lines[line_index[key]]
            nm = re.sub(r'\s*-\s*', ' – ', r['route_long_name']).strip(' –')
            if nm and ' – ' in nm and not nm.startswith('–'):
                ln['names'][nm] += 1
            return line_index[key]
        name, kind, _ = PRODUCTS.get(r['route_short_name'], (r['route_short_name'] or 'Otros', 'md', 'conv'))
        key = 'p-' + slug(name)
        if key not in line_index:
            line_index[key] = len(lines)
            lines.append({'id': key, 'net': None, 'code': name, 'color': PRODUCT_COLORS.get(name, '#8a6d3b'), 'kind': kind, 'metric': False, 'names': collections.Counter()})
        return line_index[key]
    for t in trips.values():
        t['line'] = line_for(t)

    # --- índice de estaciones usadas
    used = sorted({s for t in trips.values() for _, s, _, _ in t['stops']})
    sidx = {s: i for i, s in enumerate(used)}

    # --- geometría
    print('cargando grafo ferroviario…')
    G = RailGraph(RAIL)
    print('nodos', len(G.nodes), 'uniones', G.joined)
    shapes = collections.defaultdict(list)
    for s in rows(cer, 'shapes.txt'):
        shapes[s['shape_id']].append((int(s['shape_pt_sequence']), float(s['shape_pt_lon']), float(s['shape_pt_lat'])))
    shapes = {k: np.array([(x, y) for _, x, y in sorted(v)]) for k, v in shapes.items()}
    print('shapes', len(shapes))

    edges, edge_index = [], {}
    stats = collections.Counter()
    near_cache = {}
    def near(s):
        if s not in near_cache:
            _, lon, lat = stops[s]
            c = G.near(lon, lat, 0.7)
            if not c:
                c = G.near(lon, lat, 4.0)[:6]
            near_cache[s] = c
        return near_cache[s]

    def add_edge(a, b, prof, coords, approx):
        coords = simplify(coords, 0.00018)
        coords[0] = (stops[a][1], stops[a][2])
        coords[-1] = (stops[b][1], stops[b][2])
        i = len(edges)
        edges.append({'a': sidx[a], 'b': sidx[b], 'g': encode_polyline(coords), 'km': round(length_km(coords), 2), 'x': approx})
        edge_index[(a, b, prof)] = i
        return i

    def project(shape, s, start):
        _, lon, lat = stops[s]
        k = math.cos(math.radians(lat))
        P = shape
        A, B = P[:-1], P[1:]
        D = B - A
        D2 = (D[:, 0] * k) ** 2 + D[:, 1] ** 2
        D2[D2 == 0] = 1e-12
        t = (((lon - A[:, 0]) * D[:, 0] * k * k) + ((lat - A[:, 1]) * D[:, 1])) / D2
        t = np.clip(t, 0, 1)
        X = A[:, 0] + D[:, 0] * t
        Y = A[:, 1] + D[:, 1] * t
        dist = np.hypot((X - lon) * k, Y - lat) * 111.2
        dist[:start] = 1e9
        close = np.where(dist < 0.35)[0]
        if len(close):
            # primer tramo cercano a partir de la posición anterior; luego el mínimo local
            i = int(close[0])
            j = i
            while j + 1 < len(dist) and dist[j + 1] <= dist[j] and dist[j + 1] < 0.35:
                j += 1
            return j, float(t[j]), float(dist[j])
        j = int(np.argmin(dist))
        return (j, float(t[j]), float(dist[j])) if dist[j] < 0.6 else None

    def shape_edges(shape_id, seq):
        shape = shapes.get(shape_id.strip())
        if shape is None or len(shape) < 2:
            return None
        out, pos = [], 0
        projs = []
        for s in seq:
            pr = project(shape, s, pos)
            if pr is None:
                return None
            projs.append(pr)
            pos = pr[0]
        for (a, b), (ia, ta, _), (ib, tb, _) in zip(zip(seq, seq[1:]), projs, projs[1:]):
            pa = shape[ia] + (shape[ia + 1] - shape[ia]) * ta
            pb = shape[ib] + (shape[ib + 1] - shape[ib]) * tb
            coords = [tuple(pa)] + [tuple(x) for x in shape[ia + 1:ib + 1]] + [tuple(pb)]
            out.append(coords)
        return out

    def get_edge(a, b, prof, shape_coords=None):
        if (a, b, prof) in edge_index:
            return edge_index[(a, b, prof)]
        if (b, a, prof) in edge_index:
            return -1 - edge_index[(b, a, prof)]
        if shape_coords is not None and len(shape_coords) >= 2:
            stats['shape'] += 1
            return add_edge(a, b, prof, shape_coords, 0)
        _, la, pa = stops[a]
        _, lb, pb = stops[b]
        direct = hav(la, pa, lb, pb)
        path = None
        if prof == 'bus':
            stats['road'] += 1
            return add_edge(a, b, prof, [(la, pa), (lb, pb)], 2)
        if direct > 0.05:
            path = G.route(near(a), near(b), {'cer': 'conv', 'met': 'metric'}.get(prof, prof), limit=max(0.6, direct * 3.2 / 60 + 0.3))
        if path and len(path) >= 2 and length_km(path) < direct * 3.5 + 3:
            stats['osm'] += 1
            return add_edge(a, b, prof, [(la, pa)] + path + [(lb, pb)], 0)
        stats['straight'] += 1
        return add_edge(a, b, prof, [(la, pa), (lb, pb)], 1)

    patterns, pattern_index = [], {}
    shape_cache = {}
    n = 0
    for tid, t in trips.items():
        seq = [s for _, s, _, _ in t['stops']]
        if t.get('bus'):
            prof = 'bus'
        elif t['feed'] == 'cer':
            ln = lines[t['line']]
            prof = 'met' if ln['metric'] else 'cer'
        else:
            prof = PRODUCTS.get(t['route']['route_short_name'], ('', '', 'conv'))[2]
        key = (tuple(seq), prof, t.get('shape', '') if t['feed'] == 'cer' else '')
        if key not in pattern_index:
            sc = None
            if t['feed'] == 'cer' and prof != 'bus':
                ck = (t['shape'], tuple(seq))
                if ck not in shape_cache:
                    shape_cache[ck] = shape_edges(t['shape'], seq)
                sc = shape_cache[ck]
            e = []
            for i, (a, b) in enumerate(zip(seq, seq[1:])):
                if a == b:
                    e.append(None)
                    continue
                e.append(get_edge(a, b, prof, sc[i] if sc else None))
            pattern_index[key] = len(patterns)
            patterns.append({'s': [sidx[s] for s in seq], 'e': e})
        t['pattern'] = pattern_index[key]
        n += 1
        if n % 1000 == 0:
            print(' …', n, 'circulaciones', len(edges), 'tramos', dict(stats))
    print('patrones', len(patterns), 'tramos', len(edges), dict(stats))

    # --- tiempos
    timings, timing_index = [], {}
    for t in trips.values():
        st = t['stops']
        start = st[0][3]
        offs = []
        for _, _, a, d in st:
            offs += [a - start, d - start]
        offs = offs[1:-1]  # sin llegada al origen ni salida del destino
        key = tuple(offs)
        if key not in timing_index:
            timing_index[key] = len(timings)
            timings.append(offs)
        t['timing'] = timing_index[key]
        t['start'] = start
        t['end'] = st[-1][2]

    # --- relaciones jugables
    cities = {c['id']: c for c in game['cities']}
    def city_of(s, radius=14):
        _, lon, lat = stops[s]
        best = min(cities.values(), key=lambda c: hav(lon, lat, c['lon'], c['lat']))
        return best['id'] if hav(lon, lat, best['lon'], best['lat']) < radius else None
    corridor_routes = game['routes']
    routes, route_index = [], {}
    for r in corridor_routes:
        route_index[r['id']] = len(routes)
        routes.append({'id': r['id'], 'base': True, 'kind': r['kind'], 'ends': r['ends'], 'net': None, 'line': None})
    unmatched = collections.Counter()
    for tid, t in trips.items():
        if t['feed'] == 'cer':
            ln = lines[t['line']]
            rid = 'c-' + ln['net'] + '-' + slug(ln['code'])
            rid = CERCANIAS_ALIASES.get(rid, rid)
            if rid in route_index and routes[route_index[rid]]['base']:
                routes[route_index[rid]].update(net=ln['net'], line=t['line'], code=ln['code'], metric=ln['metric'])
            if rid not in route_index:
                route_index[rid] = len(routes)
                routes.append({'id': rid, 'base': False, 'kind': 'commuter', 'net': ln['net'], 'line': t['line'], 'code': ln['code'], 'metric': ln['metric']})
            t['groute'] = route_index[rid]
            continue
        seq = [city_of(s) for _, s, _, _ in t['stops']]
        cs = [c for c in seq if c]
        trip_km = sum(edges[e if e >= 0 else -1 - e]['km'] for e in patterns[t['pattern']]['e'] if e is not None)
        best, score = None, 0
        for r in corridor_routes:
            # La relación base debe cubrir al menos la mitad del recorrido del tren.
            if r['km'] < trip_km * 0.5:
                continue
            if r['ends'][0] in cs and r['ends'][1] in cs:
                via = r['via']
                cover = sum(1 for v in via if v in cs) / len(via)
                sc = r['km'] * cover
                if sc > score:
                    best, score = r, sc
        if best:
            t['groute'] = route_index[best['id']]
            continue
        a, b = t['stops'][0][1], t['stops'][-1][1]
        ca, cb = city_of(a, 10), city_of(b, 10)
        ea = ca or 'st' + a
        eb = cb or 'st' + b
        names = sorted([(ea, a), (eb, b)])
        rid = 'x-' + slug(stops[names[0][1]][0] if not names[0][0] in cities else cities[names[0][0]]['name']) + '--' + slug(stops[names[1][1]][0] if not names[1][0] in cities else cities[names[1][0]]['name'])
        if rid not in route_index:
            route_index[rid] = len(routes)
            routes.append({'id': rid, 'base': False, 'kind': lines[t['line']]['kind'], 'ends': [names[0][0], names[1][0]], 'endStations': [names[0][1], names[1][1]], 'net': None, 'line': None})
        unmatched[rid] += 1
        t['groute'] = route_index[rid]

    # métricas por relación
    pkm = [sum(abs(edges[e if e >= 0 else -1 - e]['km']) for e in p['e'] if e is not None) for p in patterns]
    for i, r in enumerate(routes):
        ts = [t for t in trips.values() if t['groute'] == i]
        r['tripsByDay'] = {k: sum(1 for t in ts if k in t['days']) for k in DAYS}
        if ts:
            r['km'] = round(sorted(pkm[t['pattern']] for t in ts)[len(ts) // 2], 1)
            lt = [t for t in ts if 'L' in t['days']] or ts
            ev = sorted([(t['start'], 1) for t in lt] + [(t['end'] + 8, -1) for t in lt])
            cur = peak = 0
            for _, d in ev:
                cur += d
                peak = max(peak, cur)
            r['peak'] = peak
            r['first'] = min(t['start'] for t in lt)
            r['last'] = max(t['end'] for t in lt)
            prods = collections.Counter(lines[t['line']]['code'] for t in ts)
            r['products'] = [p for p, _ in prods.most_common(4)]
            if not r.get('ends'):
                main = collections.Counter((t['stops'][0][1], t['stops'][-1][1]) for t in ts).most_common(1)[0][0]
                r['endStations'] = list(main)
                r['ends'] = ['st' + main[0], 'st' + main[1]]
            r['stations'] = len({s for t in ts for _, s, _, _ in t['stops']})
    routes = [r for r in routes if r['base'] or r.get('tripsByDay', {}).get('L', 0) + r.get('tripsByDay', {}).get('S', 0) + r.get('tripsByDay', {}).get('D', 0) > 0]
    # reindexa tras descartar relaciones sin circulaciones
    idx_by_id = {r['id']: i for i, r in enumerate(routes)}
    all_ids = list(route_index.keys())
    for t in trips.values():
        t['groute'] = idx_by_id[all_ids[t['groute']]] if all_ids[t['groute']] in idx_by_id else -1

    # --- tráfico por estación (luces y tamaño)
    traffic = collections.Counter()
    for t in trips.values():
        if 'L' in t['days']:
            for _, s, _, _ in t['stops']:
                traffic[s] += 1

    # --- salida
    out_trips = {k: [] for k in DAYS}
    for tid, t in trips.items():
        if t['feed'] == 'cer':
            m = re.match(r'^\d{4}[A-Z](\d{5})', tid)
            number = m.group(1) if m else ''
        else:
            number = t['number'].lstrip('0') or t['number']
        for k in t['days']:
            out_trips[k].append([t['line'], t['pattern'], t['timing'], t['start'], number, t['groute'], 1 if t.get('bus') else 0])
    for k in out_trips:
        out_trips[k].sort(key=lambda x: (x[3], x[0], x[4]))
    for ln in lines:
        ln['name'] = ln['names'].most_common(1)[0][0] if ln['names'] else ln['code']
        del ln['names']
    station_out = [[s, stops[s][0], round(stops[s][1], 5), round(stops[s][2], 5), traffic.get(s, 0)] for s in used]
    edge_out = [[e['a'], e['b'], e['g'], e['km'], e['x']] for e in edges]
    pattern_out = [[p['s'], [x if x is not None else 'n' for x in p['e']]] for p in patterns]
    meta = {
        'snapshot': '2026-10-06', 'days': DAYS,
        'sources': [
            {'name': 'Renfe Data · GTFS Cercanías (fomento_transit.zip)', 'url': 'https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip', 'license': 'CC BY 4.0'},
            {'name': 'Renfe Data · GTFS AV/LD/MD (google_transit.zip)', 'url': 'https://ssl.renfe.com/gtransit/Fichero_AV_LD/google_transit.zip', 'license': 'CC BY 4.0'},
            {'name': 'Copia diaria pública elguardagujas/renfe-gtfs-archive', 'url': 'https://github.com/elguardagujas/renfe-gtfs-archive'},
        ],
        'counts': {k: len(v) for k, v in out_trips.items()},
        'geometry': dict(stats),
    }
    payload = {'meta': meta, 'networks': networks, 'lines': lines, 'stations': station_out, 'edges': edge_out,
               'patterns': pattern_out, 'timings': timings, 'routes': routes, 'trips': out_trips}
    txt = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('// Horarios oficiales Renfe (GTFS, CC BY 4.0) procesados por tools/build_timetable.py. Geometría: shapes GTFS y © OpenStreetMap contributors (ODbL).\n')
        f.write('export const TT=' + txt + ';\n')
    report = {'meta': meta, 'stations': len(station_out), 'lines': len(lines), 'patterns': len(patterns), 'timings': len(timings),
              'edges': len(edges), 'routes': len(routes), 'autoRoutes': len([r for r in routes if r['id'].startswith('x-')]),
              'unmatchedTop': unmatched.most_common(40), 'bytes': len(txt.encode())}
    json.dump(report, open(REPORT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in report.items() if k != 'unmatchedTop'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
