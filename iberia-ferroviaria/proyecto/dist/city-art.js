// Ilustración de ciudad para su menú: cielo según la hora, perfil urbano, monumento característico,
// mar si es costera y estación que crece con su nivel. Dibujo esquemático original.

const COAST = new Set(['bcn', 'vlc', 'ali', 'mal', 'cad', 'alm', 'san', 'bil', 'don', 'gij', 'aco', 'vig', 'car', 'cas', 'tar', 'hue', 'alg', 'fer', 'pon', 'sag', 'iru']);
const LANDMARK = {mad: 'towers', bcn: 'sagrada', sev: 'giralda', vlc: 'shell', seg: 'aqueduct', bil: 'guggen', zar: 'pilar', gra: 'alhambra', tol: 'alcazar',
  avi: 'walls', lug: 'walls', cac: 'walls', bur: 'gothic', leo: 'gothic', sal: 'gothic', scq: 'gothic', aco: 'lighthouse', cor: 'mosque', mal: 'alcazaba',
  cad: 'dome', ter: 'mudejar', cue: 'hanging', ron: 'bridge', mer: 'roman', alm: 'alcazaba', pam: 'gothic', ovi: 'gothic', vit: 'gothic', vll: 'dome', jae: 'gothic'};

function rng(seed) { let x = 0; for (const c of String(seed)) x = (x * 31 + c.charCodeAt(0)) >>> 0; return () => { x = (Math.imul(x, 1664525) + 1013904223) >>> 0; return x / 4294967296; }; }
const mixc = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));
const rgb = c => `rgb(${c.join(',')})`;

function landmark(kind, x, base, ink) {
  switch (kind) {
    case 'towers': return [0, 1, 2, 3].map(i => `<rect x="${x + i * 26}" y="${base - 96 + (i % 2) * 6}" width="17" height="${96 - (i % 2) * 6}" fill="${ink}"/><rect x="${x + i * 26 + 3}" y="${base - 104 + (i % 2) * 6}" width="11" height="8" fill="${ink}"/>`).join('');
    case 'sagrada': return [0, 1, 2, 3].map(i => `<path d="M${x + i * 14} ${base} V${base - 70 - (i % 3) * 14} Q${x + i * 14 + 5} ${base - 98 - (i % 3) * 14} ${x + i * 14 + 10} ${base - 70 - (i % 3) * 14} V${base} Z" fill="${ink}"/>`).join('') + `<rect x="${x - 6}" y="${base - 44}" width="66" height="44" fill="${ink}"/>`;
    case 'giralda': return `<rect x="${x}" y="${base - 92}" width="18" height="92" fill="${ink}"/><rect x="${x + 3}" y="${base - 108}" width="12" height="16" fill="${ink}"/><path d="M${x + 5} ${base - 108} L${x + 9} ${base - 124} L${x + 13} ${base - 108} Z" fill="${ink}"/><rect x="${x + 22}" y="${base - 40}" width="60" height="40" fill="${ink}"/>`;
    case 'shell': return `<path d="M${x} ${base} C${x + 10} ${base - 60} ${x + 60} ${base - 70} ${x + 110} ${base - 30} L${x + 110} ${base} Z" fill="${ink}"/><path d="M${x + 20} ${base - 10} C${x + 40} ${base - 66} ${x + 90} ${base - 80} ${x + 120} ${base - 70}" stroke="${ink}" stroke-width="6" fill="none"/>`;
    case 'aqueduct': return `<path d="M${x} ${base - 50} H${x + 150} V${base} ${Array.from({length: 8}, (_, i) => `H${x + 150 - i * 19 - 4} V${base - 30} A7 9 0 0 0 ${x + 150 - i * 19 - 15} ${base - 30} V${base}`).join(' ')} H${x} Z" fill="${ink}"/><path d="M${x} ${base - 62} H${x + 150} V${base - 52} H${x} Z" fill="${ink}"/>`;
    case 'guggen': return `<path d="M${x} ${base} C${x + 6} ${base - 40} ${x + 30} ${base - 30} ${x + 36} ${base - 60} C${x + 46} ${base - 40} ${x + 70} ${base - 56} ${x + 80} ${base - 30} C${x + 92} ${base - 40} ${x + 110} ${base - 20} ${x + 116} ${base} Z" fill="${ink}"/>`;
    case 'pilar': return `<rect x="${x}" y="${base - 40}" width="110" height="40" fill="${ink}"/>${[18, 46, 74].map(d => `<path d="M${x + d} ${base - 40} a12 12 0 0 1 24 0 Z" fill="${ink}"/><rect x="${x + d + 10}" y="${base - 60}" width="4" height="10" fill="${ink}"/>`).join('')}${[0, 104].map(d => `<rect x="${x + d - 4}" y="${base - 86}" width="14" height="86" fill="${ink}"/><path d="M${x + d - 4} ${base - 86} L${x + d + 3} ${base - 100} L${x + d + 10} ${base - 86} Z" fill="${ink}"/>`).join('')}`;
    case 'alhambra': return `<path d="M${x - 30} ${base} Q${x + 60} ${base - 40} ${x + 170} ${base} Z" fill="${ink}" opacity=".7"/><rect x="${x}" y="${base - 46}" width="130" height="18" fill="${ink}"/>${[0, 40, 92, 118].map(d => `<rect x="${x + d}" y="${base - 62}" width="14" height="20" fill="${ink}"/>`).join('')}`;
    case 'alcazar': return `<rect x="${x}" y="${base - 54}" width="80" height="54" fill="${ink}"/>${[0, 70].map(d => `<rect x="${x + d - 4}" y="${base - 70}" width="18" height="70" fill="${ink}"/><path d="M${x + d - 4} ${base - 70} L${x + d + 5} ${base - 82} L${x + d + 14} ${base - 70} Z" fill="${ink}"/>`).join('')}`;
    case 'walls': return `<path d="M${x} ${base} V${base - 36} ${Array.from({length: 12}, (_, i) => `h6 v-5 h6 v5`).join(' ')} V${base} Z" fill="${ink}"/>${[0, 50, 100, 140].map(d => `<rect x="${x + d}" y="${base - 52}" width="16" height="52" rx="2" fill="${ink}"/>`).join('')}`;
    case 'gothic': return `<rect x="${x}" y="${base - 46}" width="76" height="46" fill="${ink}"/>${[0, 58].map(d => `<rect x="${x + d}" y="${base - 74}" width="18" height="74" fill="${ink}"/><path d="M${x + d} ${base - 74} L${x + d + 9} ${base - 110} L${x + d + 18} ${base - 74} Z" fill="${ink}"/>`).join('')}<circle cx="${x + 38}" cy="${base - 30}" r="7" fill="none" stroke="${ink}"/>`;
    case 'lighthouse': return `<path d="M${x} ${base} L${x + 6} ${base - 80} H${x + 22} L${x + 28} ${base} Z" fill="${ink}"/><rect x="${x + 8}" y="${base - 92}" width="12" height="12" fill="${ink}"/>`;
    case 'mosque': return `<rect x="${x}" y="${base - 30}" width="120" height="30" fill="${ink}"/><rect x="${x + 90}" y="${base - 82}" width="16" height="82" fill="${ink}"/><path d="M${x + 40} ${base - 30} a16 16 0 0 1 32 0 Z" fill="${ink}"/>`;
    case 'alcazaba': return `<path d="M${x - 20} ${base} Q${x + 50} ${base - 50} ${x + 130} ${base} Z" fill="${ink}" opacity=".7"/><rect x="${x + 20}" y="${base - 58}" width="80" height="20" fill="${ink}"/>${[20, 56, 88].map(d => `<rect x="${x + d}" y="${base - 72}" width="12" height="18" fill="${ink}"/>`).join('')}`;
    case 'dome': return `<rect x="${x}" y="${base - 40}" width="90" height="40" fill="${ink}"/><path d="M${x + 25} ${base - 40} a20 22 0 0 1 40 0 Z" fill="${ink}"/><rect x="${x + 43}" y="${base - 72}" width="4" height="10" fill="${ink}"/>`;
    case 'mudejar': return [0, 50].map(d => `<rect x="${x + d}" y="${base - 80}" width="16" height="80" fill="${ink}"/><path d="M${x + d} ${base - 80} L${x + d + 8} ${base - 92} L${x + d + 16} ${base - 80} Z" fill="${ink}"/>`).join('');
    case 'hanging': return `<path d="M${x - 10} ${base} V${base - 30} L${x + 120} ${base - 40} V${base} Z" fill="${ink}" opacity=".7"/>${[0, 24, 48].map(d => `<rect x="${x + d}" y="${base - 74}" width="20" height="40" fill="${ink}"/>`).join('')}`;
    case 'bridge': return `<path d="M${x - 10} ${base - 70} H${x + 30} V${base} H${x - 10} Z M${x + 90} ${base - 70} H${x + 130} V${base} H${x + 90} Z" fill="${ink}"/><path d="M${x + 30} ${base - 70} H${x + 90} V${base - 20} A30 40 0 0 0 ${x + 30} ${base - 20} Z" fill="${ink}"/>`;
    case 'roman': return `<rect x="${x}" y="${base - 50}" width="100" height="6" fill="${ink}"/>${[0, 1, 2, 3, 4, 5].map(i => `<rect x="${x + 4 + i * 17}" y="${base - 44}" width="7" height="44" fill="${ink}"/>`).join('')}`;
    default: return `<rect x="${x}" y="${base - 36}" width="50" height="36" fill="${ink}"/><rect x="${x + 16}" y="${base - 66}" width="18" height="30" fill="${ink}"/><path d="M${x + 16} ${base - 66} L${x + 25} ${base - 82} L${x + 34} ${base - 66} Z" fill="${ink}"/>`;
  }
}

function station(level, x, base, night) {
  const wall = night ? '#4a4252' : '#e9d9b8', roof = night ? '#2c2633' : '#a5523e', win = night ? '#ffd27a' : '#5b6f7c';
  if (level <= 0) return `<rect x="${x}" y="${base - 22}" width="46" height="4" fill="${roof}"/><rect x="${x + 4}" y="${base - 18}" width="3" height="18" fill="${roof}"/><rect x="${x + 39}" y="${base - 18}" width="3" height="18" fill="${roof}"/><rect x="${x + 12}" y="${base - 8}" width="22" height="3" fill="${roof}"/>`;
  const w = 90 + level * 40, h = 26 + level * 8;
  let svg = `<rect x="${x}" y="${base - h}" width="${w}" height="${h}" fill="${wall}"/><path d="M${x - 6} ${base - h} L${x + w / 2} ${base - h - 14 - level * 4} L${x + w + 6} ${base - h} Z" fill="${roof}"/>`;
  for (let i = 0; i < 3 + level * 2; i++) svg += `<path d="M${x + 10 + i * 18} ${base - 6} V${base - h + 12} a5 5 0 0 1 10 0 V${base - 6} Z" fill="${win}"/>`;
  if (level >= 2) svg += `<path d="M${x + w} ${base - 4} V${base - h + 4} Q${x + w + 70} ${base - h - 24} ${x + w + 140} ${base - h + 4} V${base - 4}" fill="${night ? 'rgba(255,214,140,.25)' : 'rgba(180,205,215,.55)'}" stroke="${roof}" stroke-width="2"/>`;
  if (level >= 3) svg += `<rect x="${x + w / 2 - 9}" y="${base - h - 40}" width="18" height="26" fill="${wall}" stroke="${roof}"/><circle cx="${x + w / 2}" cy="${base - h - 30}" r="6" fill="${night ? '#fff3c0' : '#fff'}" stroke="${roof}"/>`;
  return svg;
}

/** SVG de cabecera de la ciudad. `light` 0 (noche) – 1 (día); `minute` sitúa el sol o la luna. */
export function citySkyline(id, name, pop = 50, level = 0, light = 1, minute = 720) {
  const r = rng(id), night = light < .45, W = 440, H = 170, base = 132;
  const day = [[143, 195, 222], [236, 224, 196]], dusk = [[64, 70, 128], [244, 160, 104]], dark = [[12, 18, 44], [42, 46, 86]];
  const k = light;
  const top = k > .6 ? mixc(dusk[0], day[0], (k - .6) / .4) : k > .2 ? mixc(dark[0], dusk[0], (k - .2) / .4) : dark[0];
  const bottom = k > .6 ? mixc(dusk[1], day[1], (k - .6) / .4) : k > .2 ? mixc(dark[1], dusk[1], (k - .2) / .4) : dark[1];
  const ink = night ? '#1b1a2a' : rgb(mixc([92, 74, 66], [150, 128, 112], .35));
  const far = night ? '#262640' : 'rgba(140,120,105,.45)';
  const t = ((minute % 1440) - 360) / 900, sx = 40 + Math.max(0, Math.min(1, t)) * 360, sy = 110 - Math.sin(Math.max(0, Math.min(1, t)) * Math.PI) * 80;
  let svg = `<defs><linearGradient id="sky${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${rgb(top)}"/><stop offset="1" stop-color="${rgb(bottom)}"/></linearGradient></defs><rect width="${W}" height="${H}" fill="url(#sky${id})"/>`;
  if (night) for (let i = 0; i < 40; i++) svg += `<circle cx="${r() * W}" cy="${r() * 90}" r="${r() * 1.1 + .3}" fill="#fff" opacity="${.4 + r() * .6}"/>`;
  svg += night ? `<circle cx="${360}" cy="34" r="12" fill="#f4efd8"/><circle cx="366" cy="30" r="11" fill="${rgb(top)}"/>` : `<circle cx="${sx}" cy="${sy}" r="14" fill="#ffe7a0" opacity=".95"/><circle cx="${sx}" cy="${sy}" r="24" fill="#ffe7a0" opacity=".25"/>`;
  // colinas lejanas
  svg += `<path d="M0 ${base - 30} ${Array.from({length: 9}, (_, i) => `Q${i * 55 + 27} ${base - 50 - r() * 30} ${(i + 1) * 55} ${base - 30 - r() * 10}`).join(' ')} V${H} H0 Z" fill="${far}"/>`;
  if (COAST.has(id)) svg += `<rect x="0" y="${base - 6}" width="${W}" height="${H}" fill="${night ? '#1d2a48' : '#7fb3c2'}"/><path d="M0 ${base - 6} ${Array.from({length: 22}, (_, i) => `q10 -3 20 0`).join(' ')}" stroke="${night ? '#3a4a70' : '#bfe0e6'}" fill="none"/>`;
  // edificios
  const count = Math.min(26, 8 + Math.round(Math.sqrt(pop) / 3)), maxH = Math.min(80, 26 + Math.sqrt(pop) * 0.9);
  let x = 0;
  for (let i = 0; i < count && x < W; i++) {
    const w = 14 + r() * 22, h = 14 + r() * maxH, c = night ? '#22213a' : rgb(mixc([206, 178, 150], [236, 220, 196], r()));
    svg += `<rect x="${x}" y="${base - h}" width="${w}" height="${h}" fill="${c}"/>`;
    if (r() > .5) svg += `<path d="M${x - 2} ${base - h} L${x + w / 2} ${base - h - 8} L${x + w + 2} ${base - h} Z" fill="${night ? '#1b1a2a' : '#b8634a'}"/>`;
    for (let wy = base - h + 5; wy < base - 6; wy += 8) for (let wx = x + 3; wx < x + w - 4; wx += 6) if (r() > (night ? .55 : .35)) svg += `<rect x="${wx}" y="${wy}" width="3" height="4" fill="${night ? '#ffd27a' : 'rgba(80,90,100,.5)'}"/>`;
    x += w + 2 + r() * 10;
  }
  const lm = LANDMARK[id] || (pop > 150 ? 'gothic' : 'church');
  svg += landmark(lm, 250 + r() * 30, base, ink);
  // estación, vías y un tren esperando
  svg += station(level, 18, base + 18, night);
  svg += `<rect x="0" y="${base + 18}" width="${W}" height="${H - base - 18}" fill="${night ? '#211d26' : '#b9a786'}"/><rect x="0" y="${base + 26}" width="${W}" height="2" fill="${night ? '#5b5560' : '#6f665b'}"/><rect x="0" y="${base + 33}" width="${W}" height="2" fill="${night ? '#5b5560' : '#6f665b'}"/>`;
  svg += `<g transform="translate(250 ${base + 6})"><path d="M0 22 V6 Q0 2 6 2 H150 Q176 2 186 16 L188 22 Z" fill="#f4f1ea" stroke="#3a3128" stroke-width="1"/><rect x="0" y="16" width="188" height="3" fill="#5d2477"/>${[12, 30, 48, 66, 84, 102, 120, 138].map(wx => `<rect x="${wx}" y="6" width="12" height="6" rx="1.5" fill="${night ? '#ffd27a' : '#26323c'}"/>`).join('')}<path d="M160 5 Q174 6 180 14 L162 14 Z" fill="#26323c"/>${night ? '<ellipse cx="186" cy="18" rx="3" ry="2" fill="#fff6c8"/><path d="M188 18 L240 10 L240 26 Z" fill="rgba(255,240,180,.25)"/>' : ''}</g>`;
  return `<svg class="city-art" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice" role="img" aria-label="Ilustración de ${name}">${svg}</svg>`;
}
