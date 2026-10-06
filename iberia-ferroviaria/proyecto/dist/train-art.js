// Ilustraciones laterales de material rodante: coche de cabeza completo y parte del segundo coche.
// Cada familia reproduce los rasgos reconocibles de la serie real: perfil del morro, rodadura
// (bogies o rodales Talgo), pantógrafo o equipos diésel, puertas, ventanillas, pisos y librea.
// Son dibujos esquemáticos originales; los colores evocan las libreas, sin logotipos.

const LIVERY = {
  ave: {band: '#5d2477', line: '#c8102e', nose: null, roof: '#c9c6c2'},
  avlo: {band: '#7b3fb1', line: '#d9b8f2', nose: '#7b3fb1', roof: '#c9c6c2'},
  avant: {band: '#5d2477', line: '#e2672a', nose: null, roof: '#c9c6c2'},
  alvia: {band: '#8f959b', line: '#5d2477', nose: null, roof: '#c4c2bf'},
  md: {band: '#c8102e', line: '#5d2477', nose: null, roof: '#c4c2bf'},
  cercanias: {band: '#d6001c', line: '#7d868c', nose: null, roof: '#bfc3c5', doors: '#d6001c'},
  metric: {band: '#6a2c83', line: '#d6001c', nose: null, roof: '#bfc3c5'},
  historic: {band: '#c8102e', line: '#f2a900', nose: null, roof: '#b8b2a8'},
  future: {band: '#2d1b4e', line: '#c8102e', nose: '#2d1b4e', roof: '#cfccd4'},
  loco: {band: '#5d2477', line: '#c8102e', nose: null, roof: '#9a9fa3'},
};

// nose: perfil del morro · run: bogie | talgo · power: e | d · deck: 1 | 2 | 'mixed' (2.º coche de dos pisos)
const FAMILY = {
  duck: {nose: 'duck', run: 'talgo', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'ave', top: 38, label: 'Talgo 350 / 250'},
  avril: {nose: 'avril', run: 'talgo', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'ave', top: 42, label: 'Talgo Avril'},
  velaro: {nose: 'velaro', run: 'bogie', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'ave', top: 34, label: 'Siemens Velaro'},
  tgv: {nose: 'tgv', run: 'bogie', power: 'e', deck: 1, windows: 'power', doors: 0, livery: 'ave', top: 34, label: 'Alstom'},
  pendolino: {nose: 'round', run: 'bogie', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'avant', top: 34, label: 'Alstom'},
  alvia120: {nose: 'emu', run: 'bogie', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'alvia', top: 34, label: 'CAF'},
  md: {nose: 'emu', run: 'bogie', power: 'e', deck: 1, windows: 'large', doors: 2, livery: 'md', top: 34, label: 'CAF'},
  mdDiesel: {nose: 'emu', run: 'bogie', power: 'd', deck: 1, windows: 'large', doors: 2, livery: 'md', top: 34, label: 'CAF diésel'},
  trd: {nose: 'round', run: 'bogie', power: 'd', deck: 1, windows: 'large', doors: 2, livery: 'md', top: 34, label: 'TRD'},
  camello: {nose: 'boxy', run: 'bogie', power: 'd', deck: 1, windows: 'large', doors: 2, livery: 'historic', top: 36, label: 'Diésel'},
  civia: {nose: 'civia', run: 'bogie', power: 'e', deck: 1, windows: 'large', doors: 3, livery: 'cercanias', top: 34, label: 'Civia'},
  caf460: {nose: 'emu', run: 'bogie', power: 'e', deck: 1, windows: 'large', doors: 3, livery: 'cercanias', top: 34, label: 'CAF'},
  boxy: {nose: 'boxy', run: 'bogie', power: 'e', deck: 1, windows: 'large', doors: 3, livery: 'cercanias', top: 34, label: 'UT'},
  dd: {nose: 'boxy', run: 'bogie', power: 'e', deck: 2, windows: 'double', doors: 2, livery: 'cercanias', top: 18, label: 'Dos pisos'},
  max: {nose: 'emu', run: 'bogie', power: 'e', deck: 'mixed', windows: 'large', doors: 2, livery: 'cercanias', top: 34, label: 'Dos pisos central'},
  metric: {nose: 'emu', run: 'bogie', power: 'e', deck: 1, windows: 'large', doors: 2, livery: 'metric', top: 40, label: 'Ancho métrico', narrow: true},
  metricDiesel: {nose: 'boxy', run: 'bogie', power: 'd', deck: 1, windows: 'large', doors: 2, livery: 'metric', top: 40, label: 'Ancho métrico diésel', narrow: true},
  alpine: {nose: 'boxy', run: 'bogie', power: 'e', deck: 1, windows: 'panorama', doors: 1, livery: 'historic', top: 40, label: 'Cremallera', narrow: true},
  future: {nose: 'avril', run: 'bogie', power: 'e', deck: 1, windows: 'ribbon', doors: 1, livery: 'future', top: 38, label: 'AV 2030'},
  loco: {nose: 'loco', run: 'bogie', power: 'd', deck: 1, windows: 'coach', doors: 1, livery: 'loco', top: 34, label: 'Locomotora y coche'},
};

const SERIES = {
  100: 'tgv', 102: 'duck', 112: 'duck', '112M': 'duck', 103: 'velaro', 106: 'avril', 107: 'duck', 130: 'duck', 730: 'duck',
  104: 'pendolino', 114: 'pendolino', 120: 'alvia120', 121: 'alvia120', 448: 'md', 449: 'md', 470: 'camello', 480: 'md', 490: 'md',
  592: 'camello', 594: 'trd', 596: 'trd', 598: 'mdDiesel', 599: 'mdDiesel', 440: 'boxy', 442: 'boxy', 446: 'boxy', 447: 'boxy',
  450: 'dd', 451: 'dd', 452: 'max', 453: 'max', 460: 'caf460', 462: 'civia', 463: 'civia', 464: 'civia', 465: 'civia',
  2400: 'metricDiesel', 2600: 'metricDiesel', 2700: 'metricDiesel', 2900: 'metric', 3300: 'metric', 3500: 'metric', 3600: 'metric', 3800: 'metric',
  401: 'metric', 402: 'alpine', 334: 'loco',
};
const MODEL_SERIES = {s112: '112', s130: '130', s599: '599', s449: '449', civia: '463', metric: '2700', s106f: '106', s106v: '106', s107: '107',
  s452: '452', s453: '453', s453long: '453', s480: '480', s460: '460', s401: '401', future: 'future', s480uic: '480'};

let uid = 0;

/** Clave de ilustración a partir de un modelo de compra, una serie o un identificador del atlas. */
export function artKey(x) {
  const s = String(x ?? '');
  if (MODEL_SERIES[s]) return MODEL_SERIES[s];
  if (/avlo/i.test(s)) return '106avlo';
  if (/caf_am_dual/.test(s)) return '2700';
  if (/caf_am/.test(s)) return '401';
  if (/trenhotel|334/i.test(s)) return '334';
  const m = s.match(/(\d{3,4}M?)/);
  return m ? m[1] : s;
}

function familyOf(key) {
  if (key === 'future') return {...FAMILY.future};
  if (key === '106avlo') return {...FAMILY.avril, livery: 'avlo'};
  const f = FAMILY[SERIES[key]] || FAMILY.md;
  const out = {...f};
  if (key === '130' || key === '730') out.livery = 'alvia';
  if (key === '107') out.livery = 'alvia';
  if (key === '121' || key === '114' || key === '104') out.livery = 'avant';
  if (key === '730') out.power = 'hybrid';
  return out;
}

// Perfil del coche de cabeza (morro a la derecha). Devuelve contorno y parabrisas.
function nosePath(n, T) {
  const B = 86;
  switch (n) {
    case 'duck': return {body: `M252 ${T} H358 C380 ${T} 392 ${T + 5} 400 ${T + 14} C406 ${T + 21} 416 ${T + 23} 436 ${T + 26} C456 ${T + 29} 468 ${T + 34} 472 ${T + 40} C475 ${B - 4} 471 ${B} 462 ${B} H252 Z`,
      glass: `M362 ${T + 3} C378 ${T + 3} 390 ${T + 8} 397 ${T + 16} L376 ${T + 16} Z`, light: [466, T + 40]};
    case 'avril': return {body: `M252 ${T} H360 C400 ${T} 430 ${T + 14} 452 ${T + 30} C466 ${T + 38} 474 ${T + 41} 474 ${B - 4} C474 ${B} 470 ${B} 464 ${B} H252 Z`,
      glass: `M380 ${T + 3} C402 ${T + 4} 420 ${T + 11} 434 ${T + 21} L404 ${T + 20} Z`, light: [464, T + 38]};
    case 'velaro': return {body: `M252 ${T} H402 C432 ${T} 452 ${T + 14} 462 ${T + 30} C470 ${T + 42} 470 ${B} 458 ${B} H252 Z`,
      glass: `M410 ${T + 4} C432 ${T + 5} 446 ${T + 14} 452 ${T + 24} L424 ${T + 24} Z`, light: [458, T + 42]};
    case 'tgv': return {body: `M252 ${T} H404 L434 ${T + 16} C452 ${T + 22} 468 ${T + 30} 470 ${T + 44} L466 ${B} H252 Z`,
      glass: `M408 ${T + 3} L432 ${T + 17} L412 ${T + 17} Z`, light: [462, T + 42]};
    case 'round': return {body: `M252 ${T} H420 C446 ${T} 460 ${T + 12} 466 ${T + 28} C470 ${T + 40} 470 ${B} 460 ${B} H252 Z`,
      glass: `M424 ${T + 4} C444 ${T + 5} 456 ${T + 14} 460 ${T + 26} L438 ${T + 26} Z`, light: [462, T + 40]};
    case 'emu': return {body: `M252 ${T} H436 C448 ${T} 452 ${T + 4} 456 ${T + 12} L468 ${T + 40} C470 ${T + 48} 468 ${B} 460 ${B} H252 Z`,
      glass: `M440 ${T + 4} C447 ${T + 4} 450 ${T + 7} 453 ${T + 13} L462 ${T + 33} L446 ${T + 33} Z`, light: [462, T + 42]};
    case 'civia': return {body: `M252 ${T} H446 C458 ${T} 463 ${T + 6} 465 ${T + 16} L468 ${T + 44} C469 ${B - 2} 467 ${B} 460 ${B} H252 Z`,
      glass: `M449 ${T + 4} C457 ${T + 4} 460 ${T + 8} 461 ${T + 15} L463 ${T + 32} L451 ${T + 32} Z`, light: [462, T + 42]};
    case 'boxy': return {body: `M252 ${T} H460 Q467 ${T} 467 ${T + 7} V${B} H252 Z`,
      glass: `M455 ${T + 6} H465 V${T + 26} H455 Z`, light: [462, B - 12]};
    case 'loco': return {body: `M262 ${T + 6} Q262 ${T + 2} 270 ${T + 2} H452 Q462 ${T + 2} 464 ${T + 10} L466 ${B} H262 Z`,
      glass: `M450 ${T + 6} H461 L462 ${T + 22} H450 Z`, light: [460, B - 12]};
  }
}

function wheel(x, y = 92, r = 7) {
  return `<circle cx="${x}" cy="${y}" r="${r}" fill="#2b2d30"/><circle cx="${x}" cy="${y}" r="${r * .45}" fill="#6d7175"/><circle cx="${x}" cy="${y}" r="1.4" fill="#2b2d30"/>`;
}
function bogie(x) {
  return `<rect x="${x - 17}" y="84" width="34" height="9" rx="2.5" fill="#3a3d41"/>${wheel(x - 9)}${wheel(x + 9)}<rect x="${x - 4}" y="83" width="8" height="5" fill="#1f2124"/>`;
}

function windowsFor(f, x0, x1, T, deck, doorsAt) {
  const out = [], skip = x => doorsAt.some(d => x + 14 > d - 2 && x < d + 26);
  if (deck === 2) {
    for (let x = x0 + 8; x < x1 - 18; x += 21) if (!skip(x)) { out.push(`<rect x="${x}" y="${T + 9}" width="16" height="13" rx="3" class="w"/>`, `<rect x="${x}" y="${T + 40}" width="16" height="13" rx="3" class="w"/>`); }
    return out.join('');
  }
  if (f.windows === 'ribbon') { for (let x = x0 + 10; x < x1 - 14; x += 17) if (!skip(x)) out.push(`<rect x="${x}" y="${T + 12}" width="11" height="11" rx="2.5" class="w"/>`); }
  else if (f.windows === 'panorama') out.push(`<rect x="${x0 + 10}" y="${T + 6}" width="${x1 - x0 - 30}" height="24" rx="4" class="w"/>`);
  else if (f.windows === 'coach') { for (let x = x0 + 12; x < x1 - 18; x += 22) if (!skip(x)) out.push(`<rect x="${x}" y="${T + 12}" width="16" height="15" rx="2" class="w"/>`); }
  else if (f.windows !== 'power') { for (let x = x0 + 8; x < x1 - 18; x += 21) if (!skip(x)) out.push(`<rect x="${x}" y="${T + 10}" width="16" height="19" rx="3.5" class="w"/>`); }
  return out.join('');
}

function doorsFor(count, x0, x1, T, colour, wide) {
  const xs = count === 3 ? [x0 + (x1 - x0) * .18, x0 + (x1 - x0) * .5 - 11, x0 + (x1 - x0) * .82 - 22] : count === 2 ? [x0 + (x1 - x0) * .2, x0 + (x1 - x0) * .78 - 20] : count === 1 ? [x0 + 14] : [];
  const w = wide ? 22 : 14;
  return {xs, svg: xs.map(x => `<rect x="${x}" y="${T + 6}" width="${w}" height="${80 - T - 1}" rx="2" fill="${colour || 'none'}" fill-opacity="${colour ? .9 : 0}" stroke="#55595e" stroke-width="1"/>${wide ? `<line x1="${x + w / 2}" y1="${T + 6}" x2="${x + w / 2}" y2="85" stroke="#55595e" stroke-width=".8"/>` : ''}<rect x="${x + 3}" y="${T + 12}" width="${wide ? 6 : 8}" height="14" rx="1.5" class="w"/>${wide ? `<rect x="${x + w / 2 + 2}" y="${T + 12}" width="6" height="14" rx="1.5" class="w"/>` : ''}`).join('')};
}

function pantograph(x, T) {
  return `<g stroke="#4a4e52" stroke-width="1.6" fill="none" stroke-linecap="round"><path d="M${x - 10} ${T - 1} H${x + 10}"/><path d="M${x - 7} ${T - 2} L${x + 9} ${T - 12} L${x - 3} ${T - 23}"/><path d="M${x - 11} ${T - 23} H${x + 5}" stroke-width="2.4"/><circle cx="${x + 9}" cy="${T - 12}" r="1.6" fill="#4a4e52"/></g><rect x="${x - 12}" y="${T - 3}" width="4" height="3" fill="#6b7075"/><rect x="${x + 8}" y="${T - 3}" width="4" height="3" fill="#6b7075"/>`;
}
function dieselRoof(x, T) {
  return `<rect x="${x - 26}" y="${T - 7}" width="52" height="7" rx="2" fill="#8e9398"/><g fill="#5a5f64">${[0, 1, 2, 3, 4].map(i => `<rect x="${x - 22 + i * 9}" y="${T - 6}" width="6" height="5" rx="1"/>`).join('')}</g><rect x="${x + 30}" y="${T - 11}" width="5" height="11" rx="1" fill="#55595e"/>`;
}

/** SVG lateral de una serie o modelo. `key` admite id de modelo del juego, serie («463») o id del atlas. */
export function trainArt(key) {
  key = artKey(key);
  if (key === 'bus') return busArt();
  const f = familyOf(key), L = LIVERY[f.livery], id = 'ta' + (++uid);
  const T = f.top, B = 86, noseP = nosePath(f.nose, T);
  const deck2 = f.deck === 2 || f.deck === 'mixed', T2 = f.deck === 1 ? T : 18;
  const doorColour = L.doors || null, wide = f.doors === 3 || f.deck !== 1;
  // segundo coche (parcial, se desvanece hacia la izquierda)
  const d2 = doorsFor(f.run === 'talgo' ? 1 : f.doors, 24, 246, T2, doorColour, wide);
  const car2 = `<path d="M24 ${T2 + 4} Q24 ${T2} 30 ${T2} H240 Q246 ${T2} 246 ${T2 + 4} V${B} H24 Z" fill="url(#${id}b)" stroke="#4a4038" stroke-width="1.1"/>
    <rect x="24" y="${B - 12}" width="222" height="7" fill="${L.band}"/><rect x="24" y="${B - 15}" width="222" height="2" fill="${L.line}"/>
    <rect x="24" y="${B - 4}" width="222" height="4" fill="#3c3f43"/>${d2.svg}${windowsFor({...f, windows: f.windows === 'power' ? 'ribbon' : f.windows}, 24, 246, T2, deck2 ? 2 : 1, d2.xs)}
    <rect x="26" y="${T2 - 3}" width="218" height="4" rx="2" fill="${L.roof}"/>`;
  // coche de cabeza
  const front0 = f.nose === 'loco' ? 262 : 252;
  const d1 = doorsFor(f.windows === 'power' || f.nose === 'loco' ? 0 : f.doors, front0, f.nose === 'loco' ? 440 : 420, T, doorColour, f.doors === 3);
  const roofEquip = f.power === 'd' ? dieselRoof(f.nose === 'loco' ? 380 : 330, T) : f.power === 'hybrid' ? pantograph(300, T) + dieselRoof(360, T) : pantograph(f.run === 'talgo' ? 330 : 300, T);
  const powerGrille = f.windows === 'power' || f.nose === 'loco' ? `<g fill="#9ca1a6">${Array.from({length: 8}, (_, i) => `<rect x="${(f.nose === 'loco' ? 318 : 280) + i * 12}" y="${T + 10}" width="8" height="22" rx="1"/>`).join('')}</g>` : '';
  const front = `<path d="${noseP.body}" fill="url(#${id}a)" stroke="#4a4038" stroke-width="1.2"/>
    <g clip-path="url(#${id}c)"><rect x="${front0}" y="${B - 12}" width="230" height="7" fill="${L.band}"/><rect x="${front0}" y="${B - 15}" width="230" height="2" fill="${L.line}"/>
    ${L.nose ? `<path d="M410 0 L480 0 L480 ${B} L440 ${B} Z" fill="${L.nose}" opacity=".85"/>` : ''}<rect x="${front0}" y="${B - 4}" width="230" height="4" fill="#3c3f43"/></g>
    ${d1.svg}${windowsFor(f, front0, {duck: 356, avril: 376, velaro: 404, round: 416, emu: 432, civia: 444, boxy: 450, loco: 300, tgv: 404}[f.nose] || 404, T, f.deck === 2 ? 2 : 1, d1.xs)}${powerGrille}
    <path d="${noseP.glass}" fill="#1d2730"/><path d="${noseP.glass}" fill="url(#${id}g)" opacity=".55"/>
    <ellipse cx="${noseP.light[0]}" cy="${noseP.light[1]}" rx="4" ry="2.4" fill="#fff6c8" stroke="#8a8f94" stroke-width=".6"/>
    ${roofEquip}`;
  const run = f.run === 'talgo'
    ? `${bogie(f.nose === 'loco' ? 330 : 290)}${bogie(400)}${wheel(249, 92, 7)}${wheel(28, 92, 7)}`
    : `${bogie(f.nose === 'loco' ? 330 : 286)}${bogie(f.nose === 'loco' ? 436 : 418)}${bogie(70)}${bogie(206)}`;
  const coupler = `<rect x="244" y="${Math.max(T, T2) + 8}" width="10" height="${B - Math.max(T, T2) - 10}" rx="2" fill="#2f3236"/><g stroke="#55595e" stroke-width=".7">${[0, 1, 2, 3, 4, 5, 6].map(i => `<line x1="244" y1="${Math.max(T, T2) + 12 + i * 6}" x2="254" y2="${Math.max(T, T2) + 12 + i * 6}"/>`).join('')}</g>`;
  const loco2 = '';
  return `<svg class="train-art" viewBox="0 0 480 108" role="img" aria-label="Ilustración de la serie ${key} (${f.label})">
  <defs><linearGradient id="${id}a" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset=".55" stop-color="#f3f1ec"/><stop offset="1" stop-color="#d9d6cf"/></linearGradient>
  <linearGradient id="${id}b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbfaf7"/><stop offset="1" stop-color="#d6d3cc"/></linearGradient>
  <linearGradient id="${id}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#9fc3d8"/><stop offset=".5" stop-color="#2a3a46" stop-opacity="0"/></linearGradient>
  <linearGradient id="${id}f" x1="0" x2="1"><stop offset="0" stop-color="#000"/><stop offset=".42" stop-color="#fff"/></linearGradient>
  <mask id="${id}m"><rect width="480" height="108" fill="url(#${id}f)"/></mask><clipPath id="${id}c"><path d="${noseP.body}"/></clipPath>
  <style>.w{fill:#26323c}</style></defs>
  <ellipse cx="250" cy="100" rx="236" ry="4" fill="#000" opacity=".12"/>
  <rect x="0" y="98" width="480" height="5" fill="#b9ab8f"/><rect x="0" y="97" width="480" height="2" fill="#7a7068"/>
  <g mask="url(#${id}m)">${car2}</g>${loco2}${coupler}${front}${run}</svg>`;
}

function busArt() {
  return `<svg class="train-art" viewBox="0 0 480 108" role="img" aria-label="Ilustración de autocar de servicio alternativo">
  <ellipse cx="250" cy="100" rx="150" ry="4" fill="#000" opacity=".12"/><rect x="0" y="98" width="480" height="5" fill="#9c9a94"/>
  <path d="M110 28 Q110 20 120 20 H372 Q392 20 396 34 L402 80 Q402 90 392 90 H110 Z" fill="#fbfaf7" stroke="#4a4038" stroke-width="1.2"/>
  <rect x="110" y="70" width="292" height="8" fill="#f2b13a"/><g fill="#26323c">${[0, 1, 2, 3, 4, 5, 6, 7, 8].map(i => `<rect x="${122 + i * 27}" y="32" width="22" height="22" rx="3"/>`).join('')}</g>
  <path d="M372 26 H388 Q394 28 396 40 L398 56 H372 Z" fill="#1d2730"/><rect x="350" y="32" width="18" height="52" rx="2" fill="none" stroke="#55595e"/>
  ${wheel(160, 90, 10)}${wheel(352, 90, 10)}<ellipse cx="398" cy="74" rx="3" ry="2" fill="#fff6c8"/></svg>`;
}
