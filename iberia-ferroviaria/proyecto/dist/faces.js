// Retratos ilustrados de los personajes: un dibujo vectorial por personaje y tres caras por emoción
// (happy: contento, angry: enfadado, worried: agobiado). Se generan como SVG y se usan como imagen.
const INK = '#2a1f1a';
const SKIN = {light: ['#f2cdaa', '#dcae88'], medium: ['#e6b48d', '#cd9670'], tan: ['#cf9469', '#b47a52'], rosy: ['#f0c3a0', '#d9a07c']};

// ---------------------------------------------------------------- personajes
export const LOOKS = {
  president: {eye: '#3b2a1f', age: 1, skin: 'medium', face: [78, 70, 30], hair: 'swept', hairColor: '#2e241f', grey: '#8d8780', brows: '#2e241f', nose: 'straight', bg: ['#6e1d33', '#8a2a46'], clothes: 'suit', suit: '#1e2b4a', shirt: '#f4f1ea', tie: '#a3123a', pattern: 'stripes'},
  minister: {eye: '#6a5a2e', skin: 'rosy', face: [74, 60, 24], hair: 'wavy', hairColor: '#6a4630', brows: '#5a3a27', nose: 'small', bg: ['#22557c', '#2f6f9f'], clothes: 'blazer', suit: '#d8c6a6', shirt: '#28323c', earrings: '#d9b45a', lips: '#b5524f', lashes: true, pattern: 'dots'},
  successor: {eye: '#4f6474', age: 2, skin: 'light', face: [84, 80, 40], hair: 'crop', hairColor: '#4d3d33', brows: '#4d3d33', beard: '#8f877e', nose: 'round', bg: ['#2d3c5e', '#3c4f7a'], clothes: 'suit', suit: '#26314a', shirt: '#dfe7f2', tie: '#2c4f8a', phone: true, pattern: 'stripes'},
  treasury: {eye: '#5d6466', age: 2, skin: 'light', face: [72, 60, 26], hair: 'bob', hairColor: '#b7b2ab', brows: '#8e8881', nose: 'small', bg: ['#4a3c30', '#5f4d3d'], clothes: 'blazer', suit: '#3a3c42', shirt: '#ece6da', glasses: '#9a1f2f', pearls: true, lips: '#a5525a', lashes: true, scissors: true, pattern: 'grid'},
  adif: {eye: '#3a2a20', age: 1, skin: 'tan', face: [80, 74, 34], hair: 'helmet', hairColor: '#3a2d25', brows: '#3a2d25', moustache: '#3a2d25', nose: 'round', bg: ['#3f5a30', '#4f6b3a'], clothes: 'vest', suit: '#53606b', shirt: '#cfd6dd', pattern: 'hatch'},
  workshop: {eye: '#4a6a86', age: 3, skin: 'rosy', face: [82, 72, 34], hair: 'bald', hairColor: '#d6d2cb', brows: '#d6d2cb', moustache: '#e3dfd8', nose: 'big', bg: ['#4b5057', '#5c636b'], clothes: 'overalls', suit: '#2f5d8a', shirt: '#e9e2d2', grease: true, pencil: true, pattern: 'hatch'},
  riders: {eye: '#2a1d16', skin: 'medium', face: [72, 58, 22], hair: 'curls', hairColor: '#2b201b', brows: '#2b201b', nose: 'small', bg: ['#8c4a24', '#a0562a'], clothes: 'cardigan', suit: '#4f7a5a', shirt: '#efe6d4', glasses: '#2a1f1a', round: true, lips: '#a84a43', lashes: true, badge: true, pattern: 'dots'},
  mayor: {eye: '#4a3426', age: 3, skin: 'rosy', face: [86, 80, 42], hair: 'combover', hairColor: '#ece8e0', brows: '#d9d4cc', nose: 'big', bg: ['#6b5c22', '#7f6d2a'], clothes: 'sash', suit: '#3a3330', shirt: '#f2ede2', tie: '#6b4a2a', cheeks: true, pattern: 'grid'},
  rival: {eye: '#3f5a3a', skin: 'tan', face: [76, 66, 28], hair: 'slick', hairColor: '#1f1a17', brows: '#1f1a17', moustache: '#1f1a17', thin: true, nose: 'straight', bg: ['#255a56', '#2f6f6a'], clothes: 'suit', suit: '#d9d2c4', shirt: '#2b3a4a', tie: '#2fa39b', shades: true, pattern: 'stripes'},
};

// ---------------------------------------------------------------- piezas
const f = n => Math.round(n * 10) / 10;
function facePath([w, jaw, chin], top = 50, chinY = 146) {
  const cx = 100, hw = w / 2, jw = jaw / 2, cw = chin / 2;
  return `M${cx},${top} C${f(cx + hw * .78)},${top} ${f(cx + hw)},${top + 22} ${f(cx + hw)},${top + 46} C${f(cx + hw)},${top + 64} ${f(cx + jw + 5)},${top + 76} ${f(cx + jw)},${top + 82} C${f(cx + jw - 6)},${top + 90} ${f(cx + cw + 6)},${chinY} ${cx},${chinY} C${f(cx - cw - 6)},${chinY} ${f(cx - jw + 6)},${top + 90} ${f(cx - jw)},${top + 82} C${f(cx - jw - 5)},${top + 76} ${f(cx - hw)},${top + 64} ${f(cx - hw)},${top + 46} C${f(cx - hw)},${top + 22} ${f(cx - hw * .78)},${top} ${cx},${top} Z`;
}
function background(L, id) {
  const [a, b] = L.bg;
  const pat = {
    stripes: `<pattern id="p${id}" width="10" height="10" patternUnits="userSpaceOnUse" patternTransform="rotate(35)"><rect width="10" height="10" fill="none"/><path d="M0 0V10" stroke="#fff" stroke-opacity=".07" stroke-width="3"/></pattern>`,
    dots: `<pattern id="p${id}" width="12" height="12" patternUnits="userSpaceOnUse"><circle cx="6" cy="6" r="1.6" fill="#fff" fill-opacity=".09"/></pattern>`,
    grid: `<pattern id="p${id}" width="14" height="14" patternUnits="userSpaceOnUse"><path d="M14 0H0V14" fill="none" stroke="#fff" stroke-opacity=".07" stroke-width="1"/></pattern>`,
    hatch: `<pattern id="p${id}" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(-30)"><path d="M0 4H8" stroke="#000" stroke-opacity=".12" stroke-width="2"/></pattern>`,
  }[L.pattern];
  return `<defs><radialGradient id="g${id}" cx="50%" cy="38%" r="75%"><stop offset="0" stop-color="${b}"/><stop offset="1" stop-color="${a}"/></radialGradient>${pat}
  <clipPath id="c${id}"><rect x="0" y="0" width="200" height="240" rx="14"/></clipPath></defs>
  <rect width="200" height="240" rx="14" fill="url(#g${id})"/><rect width="200" height="240" rx="14" fill="url(#p${id})"/>
  <circle cx="100" cy="104" r="78" fill="#fff" fill-opacity=".07"/><circle cx="100" cy="104" r="78" fill="none" stroke="#f6e3b4" stroke-opacity=".28" stroke-width="1.2"/>
  <circle cx="100" cy="104" r="86" fill="none" stroke="#f6e3b4" stroke-opacity=".14" stroke-width=".8" stroke-dasharray="2 4"/>`;
}
function clothes(L, mood) {
  const s = L.suit, sh = L.shirt;
  const body = `M4,240 C8,204 30,186 66,178 L86,172 L114,172 L134,178 C170,186 192,204 196,240 Z`;
  const shade = `<path d="M150,240 C150,212 160,196 176,192 C188,204 194,220 196,240 Z" fill="#000" opacity=".16"/><path d="M14,226 C24,204 40,192 62,186" fill="none" stroke="#fff" stroke-opacity=".14" stroke-width="3" stroke-linecap="round"/>`;
  if (L.clothes === 'overalls') return `<path d="${body}" fill="${sh}" stroke="${INK}" stroke-width="1.6"/>
    <path d="M52,240 L58,194 L142,194 L148,240 Z" fill="${s}" stroke="${INK}" stroke-width="1.6"/><path d="M66,194 L72,172 M134,194 L128,172" stroke="${s}" stroke-width="9" stroke-linecap="round"/>
    <path d="M66,194 L72,172 M134,194 L128,172" stroke="${INK}" stroke-width="1.2" fill="none" opacity=".6"/><rect x="86" y="206" width="28" height="18" rx="3" fill="#000" opacity=".14"/>
    <circle cx="72" cy="197" r="3" fill="#d9b45a" stroke="${INK}"/><circle cx="128" cy="197" r="3" fill="#d9b45a" stroke="${INK}"/>${L.pencil ? '' : ''}${shade}`;
  if (L.clothes === 'vest') return `<path d="${body}" fill="${sh}" stroke="${INK}" stroke-width="1.6"/>
    <path d="M34,240 C36,210 48,192 72,182 L86,176 L92,240 Z M166,240 C164,210 152,192 128,182 L114,176 L108,240 Z" fill="#f0c419" stroke="${INK}" stroke-width="1.6"/>
    <path d="M40,222 L90,222 M110,222 L160,222" stroke="#d5dbe0" stroke-width="7"/><path d="M40,222 L90,222 M110,222 L160,222" stroke="${INK}" stroke-width=".8" opacity=".4"/>${shade}`;
  if (L.clothes === 'cardigan') return `<path d="${body}" fill="${s}" stroke="${INK}" stroke-width="1.6"/>
    <path d="M82,172 L100,206 L118,172 Z" fill="${sh}" stroke="${INK}" stroke-width="1.4"/><path d="M100,206 L100,240" stroke="${INK}" stroke-width="1.2"/>
    ${[214, 228].map(y => `<circle cx="104" cy="${y}" r="2.2" fill="#e8dcc4" stroke="${INK}" stroke-width=".8"/>`).join('')}
    ${L.badge ? `<circle cx="138" cy="210" r="11" fill="#f2e6c8" stroke="${INK}" stroke-width="1.4"/><path d="M132,210 h12 M138,204 v12" stroke="#a0562a" stroke-width="3"/>` : ''}${shade}`;
  const lapelL = `M88,170 L74,178 L86,218 L100,190 Z`, lapelR = `M112,170 L126,178 L114,218 L100,190 Z`;
  let out = `<path d="${body}" fill="${s}" stroke="${INK}" stroke-width="1.6"/>`;
  out += L.clothes === 'blazer' ? `<path d="M84,170 L100,200 L116,170 Z" fill="${sh}" stroke="${INK}" stroke-width="1.4"/>` : `<path d="M86,170 L100,196 L114,170 Z" fill="${sh}" stroke="${INK}" stroke-width="1.4"/>`;
  if (L.tie) out += `<path d="M96,180 L104,180 L107,214 L100,224 L93,214 Z" fill="${L.tie}" stroke="${INK}" stroke-width="1.3"/><path d="M95,172 L105,172 L104,181 L96,181 Z" fill="${L.tie}" stroke="${INK}" stroke-width="1.3"/>`;
  out += `<path d="${lapelL}" fill="${s}" stroke="${INK}" stroke-width="1.4"/><path d="${lapelR}" fill="${s}" stroke="${INK}" stroke-width="1.4"/>`;
  out += `<path d="M76,180 L86,218" stroke="#fff" stroke-opacity=".12" stroke-width="2"/>`;
  if (L.clothes === 'sash') out += `<path d="M64,180 L150,240 L132,240 L58,190 Z" fill="#b2222c" stroke="${INK}" stroke-width="1.3"/><path d="M61,185 L141,240" stroke="#e2b23c" stroke-width="4"/>`;
  if (L.pearls) out += `<path d="M84,171 Q100,190 116,171" fill="none" stroke="#f4efe6" stroke-width="4.2" stroke-dasharray="0.1 5" stroke-linecap="round"/>`;
  if (L.scissors) out += `<g transform="translate(132 202) rotate(-25)"><circle cx="-5" cy="6" r="3.6" fill="none" stroke="#d9b45a" stroke-width="2"/><circle cx="5" cy="6" r="3.6" fill="none" stroke="#d9b45a" stroke-width="2"/><path d="M-3,3 L4,-12 M3,3 L-4,-12" stroke="#d9b45a" stroke-width="2"/></g>`;
  if (L.phone) out += `<g transform="translate(150 196) rotate(12)"><rect x="-9" y="-16" width="18" height="30" rx="3.5" fill="#1d2230" stroke="${INK}" stroke-width="1.4"/><rect x="-6.5" y="-12" width="13" height="21" rx="1.5" fill="#6fb4e8"/><path d="M-3,-6 q3,-3 6,0 q-3,4 -6,0" fill="#fff"/></g>`;
  return out + shade;
}
function neck(L) {
  const [skin, dark] = SKIN[L.skin];
  return `<path d="M82,132 L82,174 Q100,186 118,174 L118,132 Z" fill="${skin}" stroke="${INK}" stroke-width="1.5"/><path d="M82,150 Q100,168 118,150 L118,136 L82,136 Z" fill="${dark}" opacity=".6"/>`;
}
function ears(L) {
  const [skin, dark] = SKIN[L.skin], w = L.face[0] / 2;
  return [-1, 1].map(sd => { const x = 100 + sd * (w - 1); return `<path d="M${x},92 C${x + sd * 12},86 ${x + sd * 13},110 ${x + sd * 2},114 Z" fill="${skin}" stroke="${INK}" stroke-width="1.5"/><path d="M${x + sd * 2},98 C${x + sd * 7},97 ${x + sd * 7},106 ${x + sd * 2},108" fill="none" stroke="${dark}" stroke-width="1.6"/>`; }).join('')
    + (L.earrings ? [-1, 1].map(sd => `<circle cx="${100 + sd * (w + 3)}" cy="119" r="3.6" fill="${L.earrings}" stroke="${INK}" stroke-width="1"/>`).join('') : '');
}
function hairBack(L) {
  const c = L.hairColor;
  switch (L.hair) {
    case 'wavy': return `<path d="M54,96 C46,58 70,34 100,34 C134,34 156,58 148,98 C152,126 158,150 150,172 C140,182 126,176 120,168 L82,168 C74,178 58,182 50,172 C42,150 48,126 54,96 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/>`;
    case 'bob': return `<path d="M56,92 C52,56 74,38 100,38 C128,38 150,56 146,94 C148,116 150,134 146,144 L54,144 C50,134 52,116 56,92 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/>`;
    case 'curls': return `<g fill="${c}" stroke="${INK}" stroke-width="1.5">${[[64, 70, 18], [136, 70, 18], [58, 98, 14], [142, 98, 14], [62, 122, 12], [138, 122, 12], [100, 40, 22], [78, 46, 18], [122, 46, 18]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}"/>`).join('')}<circle cx="100" cy="22" r="16"/></g>`;
    default: return '';
  }
}
function hairFront(L) {
  const c = L.hairColor, w = L.face[0] / 2;
  switch (L.hair) {
    case 'swept': return `<path d="M${100 - w + 1},92 C${100 - w - 6},70 ${100 - w},40 88,30 C104,22 128,24 ${100 + w - 4},40 C${100 + w + 4},50 ${100 + w + 2},72 ${100 + w - 1},92 C${100 + w - 4},80 ${100 + w - 8},70 ${100 + w - 14},66 C122,58 108,58 96,56 C90,62 82,64 ${100 - w + 12},70 C${100 - w + 6},76 ${100 - w + 3},84 ${100 - w + 1},92 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/>
      <path d="M${100 - w + 1},92 C${100 - w},84 ${100 - w + 2},78 ${100 - w + 6},74 L${100 - w + 7},94 Z M${100 + w - 1},92 C${100 + w},84 ${100 + w - 2},78 ${100 + w - 6},74 L${100 + w - 7},94 Z" fill="${L.grey}"/>
      <path d="M96,56 C104,44 122,38 136,44 M92,50 C102,38 118,32 132,34 M84,44 C92,34 104,30 116,30" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="2" stroke-linecap="round"/><path d="M96,56 C92,48 92,40 96,32" fill="none" stroke="${INK}" stroke-width="1.1" opacity=".6"/>`;
    case 'wavy': return `<path d="M${100 - w},96 C${100 - w - 4},60 80,42 104,42 C126,42 ${100 + w + 6},58 ${100 + w},96 C${100 + w - 8},74 128,62 112,58 C98,70 82,72 ${100 - w + 10},78 C${100 - w + 4},84 ${100 - w + 2},90 ${100 - w},96 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/>
      <path d="M92,50 C106,46 122,50 132,60" fill="none" stroke="#fff" stroke-opacity=".2" stroke-width="3" stroke-linecap="round"/>`;
    case 'crop': return `<path d="M${100 - w + 3},84 C${100 - w},56 78,42 100,42 C124,42 ${100 + w},56 ${100 + w - 3},84 C${100 + w - 8},66 120,60 100,60 C80,60 ${100 - w + 8},66 ${100 - w + 3},84 Z" fill="${c}" stroke="${INK}" stroke-width="1.5"/><path d="M${100 - w + 6},70 L${100 - w + 6},90 M${100 + w - 6},70 L${100 + w - 6},90" stroke="${L.beard}" stroke-width="5" stroke-linecap="round"/>`;
    case 'bob': return `<path d="M${100 - w - 2},106 C${100 - w - 6},62 80,44 102,44 C126,44 ${100 + w + 6},62 ${100 + w + 2},106 L${100 + w - 4},106 C${100 + w - 4},84 ${100 + w - 10},74 ${100 + w - 16},70 C112,76 88,76 ${100 - w + 14},70 C${100 - w + 8},76 ${100 - w + 4},86 ${100 - w + 4},106 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/><path d="M80,58 C96,52 116,54 128,62" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="3" stroke-linecap="round"/>`;
    case 'helmet': return `<path d="M${100 - w + 4},92 C${100 - w + 4},82 ${100 - w + 6},76 ${100 - w + 8},74 L${100 - w + 8},94 Z M${100 + w - 4},92 C${100 + w - 4},82 ${100 + w - 6},76 ${100 + w - 8},74 L${100 + w - 8},94 Z" fill="${c}"/>
      <path d="M${100 - w - 10},74 C${100 - w - 6},70 ${100 + w + 6},70 ${100 + w + 10},74 L${100 + w + 6},80 C${100 + w},77 ${100 - w},77 ${100 - w - 6},80 Z" fill="#e8a417" stroke="${INK}" stroke-width="1.6"/>
      <path d="M${100 - w + 2},74 C${100 - w + 2},44 80,30 100,30 C120,30 ${100 + w - 2},44 ${100 + w - 2},74 Z" fill="#f2b51f" stroke="${INK}" stroke-width="1.6"/><path d="M94,31 L94,72 M106,31 L106,72" stroke="#c98a12" stroke-width="2"/><path d="M78,44 C86,38 96,36 104,36" stroke="#fff" stroke-opacity=".45" stroke-width="3" fill="none" stroke-linecap="round"/>`;
    case 'bald': return `<path d="M${100 - w + 1},96 C${100 - w - 2},84 ${100 - w + 2},72 ${100 - w + 8},68 C${100 - w + 10},76 ${100 - w + 8},86 ${100 - w + 6},98 Z M${100 + w - 1},96 C${100 + w + 2},84 ${100 + w - 2},72 ${100 + w - 8},68 C${100 + w - 10},76 ${100 + w - 8},86 ${100 + w - 6},98 Z" fill="${c}" stroke="${INK}" stroke-width="1.4"/><path d="M80,58 C90,52 104,51 114,54" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="4" stroke-linecap="round"/>`;
    case 'curls': return `<g fill="${c}" stroke="${INK}" stroke-width="1.4">${[[74, 60, 11], [88, 52, 11], [102, 50, 11], [116, 52, 11], [128, 60, 11], [100 - w + 4, 76, 9], [100 + w - 4, 76, 9]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}"/>`).join('')}</g>`;
    case 'combover': return `<path d="M${100 - w + 1},98 C${100 - w - 2},84 ${100 - w + 2},72 ${100 - w + 9},66 C${100 - w + 12},76 ${100 - w + 10},88 ${100 - w + 7},100 Z M${100 + w - 1},98 C${100 + w + 2},84 ${100 + w - 2},72 ${100 + w - 9},66 C${100 + w - 12},76 ${100 + w - 10},88 ${100 + w - 7},100 Z" fill="${c}" stroke="${INK}" stroke-width="1.3"/>
      <path d="M${100 - w + 8},68 C84,52 108,46 ${100 + w - 8},62 M${100 - w + 10},64 C88,50 110,46 ${100 + w - 10},58 M${100 - w + 12},72 C88,58 110,54 ${100 + w - 6},66" fill="none" stroke="${c}" stroke-width="2.4" stroke-linecap="round"/><path d="M${100 - w + 8},68 C84,52 108,46 ${100 + w - 8},62" fill="none" stroke="${INK}" stroke-width=".8" opacity=".35"/>`;
    case 'slick': return `<path d="M${100 - w + 2},86 C${100 - w - 2},56 78,40 102,40 C126,40 ${100 + w},54 ${100 + w - 2},86 C${100 + w - 8},68 ${100 + w - 14},60 118,58 C104,56 90,58 80,62 C${100 - w + 8},68 ${100 - w + 4},76 ${100 - w + 2},86 Z" fill="${c}" stroke="${INK}" stroke-width="1.6"/>
      <path d="M78,52 C94,44 116,44 130,52 M82,58 C96,50 114,50 128,56" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="2" stroke-linecap="round"/>
      ${L.shades ? `<g transform="translate(100 47)"><path d="M-25,-4 Q-15,-7 -5,-4 Q-6,5 -15,5 Q-24,5 -25,-4 Z M25,-4 Q15,-7 5,-4 Q6,5 15,5 Q24,5 25,-4 Z" fill="#33414e" stroke="#c9a24a" stroke-width="1.6"/><path d="M-5,-3 Q0,-6 5,-3" fill="none" stroke="#c9a24a" stroke-width="1.6"/><path d="M-21,-2 l6,-1.5 M9,-2 l6,-1.5" stroke="#fff" stroke-opacity=".55" stroke-width="1.6" stroke-linecap="round"/></g>` : ''}`;
    default: return '';
  }
}

// ---------------------------------------------------------------- expresiones
const MOODS = {
  happy: {brow: -4, tilt: -3, lid: .32, lower: .5, mouth: 'smile', blush: .32},
  angry: {brow: 6, tilt: 13, lid: .62, lower: .1, mouth: 'shout', blush: .55, flush: true},
  worried: {brow: -3, tilt: -14, lid: .02, lower: 0, mouth: 'wobble', sweat: true, pale: true},
};
function eyes(L, m) {
  const out = [];
  for (const sd of [-1, 1]) {
    const x = 100 + sd * 16, y = 98, w = 10.5, h = 6.2 + (m.lid < .1 ? 1.4 : 0);
    const lidY = y - h + h * 2 * m.lid * (sd === -1 ? 1 : 1), inner = m.tilt > 6 ? 3.5 : 0;
    out.push(`<path d="M${x - w},${y} Q${x},${y - h * 1.7} ${x + w},${y} Q${x},${y + h * 1.25} ${x - w},${y} Z" fill="#fbf8f2" stroke="${INK}" stroke-width="1.2"/>`);
    const ix = x + sd * -0.8, iy = y + (m.lid < .1 ? -0.5 : 0.6);
    out.push(`<circle cx="${ix}" cy="${iy}" r="4.6" fill="${L.eye || '#4a3426'}"/><circle cx="${ix}" cy="${iy}" r="2.2" fill="#140e0b"/><circle cx="${ix + 1.4}" cy="${iy - 1.6}" r="1.2" fill="#fff"/>`);
    // párpado superior: baja con el enfado (más por dentro) y con la sonrisa
    if (m.lid > .05) out.push(`<path d="M${x - w - 1},${y - .5} Q${x},${y - h * 1.7 - 1} ${x + w + 1},${y - .5} L${x + w + 1},${y - h * 1.9} L${x - w - 1},${y - h * 1.9} Z" fill="${SKIN[L.skin][0]}" transform="translate(0 ${f(h * 1.15 * m.lid)}) rotate(${sd * (m.tilt > 6 ? -m.tilt * .9 : 0)} ${x} ${y})"/>`);
    out.push(`<path d="M${x - w - 1},${y - .4 + h * 1.15 * m.lid * .95 + (sd === -1 ? inner : 0) * 0} Q${x},${y - h * 1.7 + h * 1.6 * m.lid} ${x + w + 1},${y - .4 + h * 1.15 * m.lid * .95}" fill="none" stroke="${INK}" stroke-width="2.2" stroke-linecap="round" transform="rotate(${sd * (m.tilt > 6 ? -m.tilt * .9 : 0)} ${x} ${y})"/>`);
    if (L.lashes) out.push(`<path d="M${x + sd * w},${y - 1 + h * 1.15 * m.lid * .9} l${sd * 4},-3" stroke="${INK}" stroke-width="1.6" stroke-linecap="round" transform="rotate(${sd * (m.tilt > 6 ? -m.tilt * .9 : 0)} ${x} ${y})"/>`);
    // mejilla que empuja el párpado inferior al sonreír
    if (m.lower > .2) out.push(`<path d="M${x - w - 2},${y + 6.5} Q${x},${y - 1} ${x + w + 2},${y + 6.5} L${x + w + 2},${y + 10} L${x - w - 2},${y + 10} Z" fill="${SKIN[L.skin][0]}"/><path d="M${x - w + 1},${y + 4.5} Q${x},${y + .5} ${x + w - 1},${y + 4.5}" fill="none" stroke="${INK}" stroke-width="1.1" stroke-linecap="round" opacity=".8"/>`);
    else out.push(`<path d="M${x - w + 2},${y + 5.5} Q${x},${y + 8} ${x + w - 2},${y + 5.5}" fill="none" stroke="${SKIN[L.skin][1]}" stroke-width="1.4" stroke-linecap="round"/>`);
  }
  return out.join('');
}
function brows(L, m) {
  const c = L.brows, thick = L.hair === 'bald' ? 6 : 4.4;
  return [-1, 1].map(sd => {
    const x = 100 + sd * 16, y = 84 + m.brow, inner = x - sd * 11, outer = x + sd * 12, dy = m.tilt * .55;
    return `<path d="M${inner},${y + dy} Q${x},${y - 5 - (m.tilt < 0 ? 2 : 0)} ${outer},${y - dy * .3 + 1}" fill="none" stroke="${c}" stroke-width="${thick}" stroke-linecap="round"/>`;
  }).join('');
}
function nose(L) {
  const [skin, dark] = SKIN[L.skin];
  const shapes = {
    straight: `<path d="M98,100 C97,108 94,114 95,118 C97,121 103,121 106,118" fill="none" stroke="${INK}" stroke-width="1.5" stroke-linecap="round"/>`,
    small: `<path d="M99,104 C98,110 96,114 97,116 C99,118 102,118 104,116" fill="none" stroke="${INK}" stroke-width="1.4" stroke-linecap="round"/>`,
    round: `<path d="M98,100 C96,108 92,113 93,117 C95,122 105,122 107,117 C108,114 105,112 103,113" fill="${dark}" fill-opacity=".35" stroke="${INK}" stroke-width="1.5" stroke-linecap="round"/>`,
    big: `<path d="M97,98 C95,108 89,114 91,119 C94,125 106,125 109,119 C111,115 107,112 104,113" fill="${dark}" fill-opacity=".45" stroke="${INK}" stroke-width="1.6" stroke-linecap="round"/>`,
  };
  return shapes[L.nose];
}
function mouth(L, m) {
  const y = 128, lip = L.lips || '#9a4a42';
  if (m.mouth === 'smile') return `<path d="M84,${y - 2} Q100,${y + 15} 116,${y - 2} Q100,${y + 4} 84,${y - 2} Z" fill="#5a1f1c" stroke="${INK}" stroke-width="1.4" stroke-linejoin="round"/><path d="M87,${y - .5} Q100,${y + 4.6} 113,${y - .5} L112,${y + 2.6} Q100,${y + 6.2} 88,${y + 2.6} Z" fill="#fbf8f2"/><path d="M84,${y - 2} Q100,${y + 15} 116,${y - 2}" fill="none" stroke="${lip}" stroke-width="2.2" stroke-linecap="round"/><path d="M82,${y - 4} q2,1 3,3 M118,${y - 4} q-2,1 -3,3" stroke="${INK}" stroke-width="1.3" fill="none" stroke-linecap="round"/>`;
  if (m.mouth === 'shout') return `<path d="M86,${y + 4} Q86,${y - 5} 100,${y - 5} Q114,${y - 5} 114,${y + 4} Q114,${y + 13} 100,${y + 13} Q86,${y + 13} 86,${y + 4} Z" fill="#4a1714" stroke="${INK}" stroke-width="1.5"/><path d="M88,${y - 1.5} Q100,${y - 4} 112,${y - 1.5} L111,${y + 1.8} Q100,${y} 89,${y + 1.8} Z" fill="#fbf8f2"/><path d="M90,${y + 9} Q100,${y + 6} 110,${y + 9}" fill="#c0504a" opacity=".9"/>`;
  return `<path d="M88,${y + 3} q4,-3.5 8,0 t8,0 t8,0" fill="none" stroke="${INK}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M95,${y + 7} q5,2 10,0" fill="none" stroke="${lip}" stroke-width="1.6" stroke-linecap="round" opacity=".7"/>`;
}
function facialHair(L, m) {
  let out = '';
  if (L.beard) out += `<path d="M${100 - L.face[1] / 2 - 1},112 C${100 - L.face[1] / 2},132 82,150 100,150 C118,150 ${100 + L.face[1] / 2},132 ${100 + L.face[1] / 2 + 1},112 C${100 + L.face[1] / 2 - 4},124 112,${m.mouth === 'shout' ? 132 : 136} 100,${m.mouth === 'shout' ? 132 : 136} C88,${m.mouth === 'shout' ? 132 : 136} ${100 - L.face[1] / 2 + 4},124 ${100 - L.face[1] / 2 - 1},112 Z" fill="${L.beard}" stroke="${INK}" stroke-width="1.4"/><path d="M84,122 C90,117 96,118 100,120 C104,118 110,117 116,122 C110,121 104,123 100,123 C96,123 90,121 84,122 Z" fill="${L.beard}" stroke="${INK}" stroke-width="1.2"/>`;
  if (L.moustache && !L.beard) out += L.thin ? `<path d="M88,121 Q100,117 112,121" fill="none" stroke="${L.moustache}" stroke-width="2.4" stroke-linecap="round"/>` : `<path d="M80,124 C86,116 96,116 100,119 C104,116 114,116 120,124 C114,123 106,124 100,123 C94,124 86,123 80,124 Z" fill="${L.moustache}" stroke="${INK}" stroke-width="1.3"/>`;
  return out;
}
function extras(L, m) {
  const [skin] = SKIN[L.skin];
  let out = '';
  if (m.blush) out += [-1, 1].map(sd => `<ellipse cx="${100 + sd * 24}" cy="114" rx="8" ry="4.5" fill="#e0675a" opacity="${m.blush * (L.cheeks ? 1.4 : 1) * .55}"/>`).join('');
  if (m.flush) out += `<ellipse cx="100" cy="112" rx="${L.face[0] * .42}" ry="16" fill="#d9483c" opacity=".16"/><path d="M${100 + L.face[0] / 2 - 14},70 q3,4 1,9" fill="none" stroke="#b03a30" stroke-width="1.6" opacity=".6" stroke-linecap="round"/>`;
  if (m.sweat) out += `<path d="M${100 + L.face[0] / 2 - 9},70 C${100 + L.face[0] / 2 - 3},78 ${100 + L.face[0] / 2 - 2},84 ${100 + L.face[0] / 2 - 7},86 C${100 + L.face[0] / 2 - 12},86 ${100 + L.face[0] / 2 - 13},80 ${100 + L.face[0] / 2 - 9},70 Z" fill="#cfe9f7" stroke="${INK}" stroke-width="1.1"/><path d="M84,62 q4,-2 8,0 M108,62 q4,-2 8,0" stroke="${INK}" stroke-width="1" fill="none" opacity=".45"/>`;
  if (L.glasses) out += `<g fill="none" stroke="${L.glasses}" stroke-width="2.6">${L.round ? '<circle cx="84" cy="98" r="11"/><circle cx="116" cy="98" r="11"/>' : '<rect x="71" y="89" width="26" height="18" rx="5"/><rect x="103" y="89" width="26" height="18" rx="5"/>'}<path d="M95,97 Q100,94 105,97"/></g><path d="M74,94 l6,-3 M106,94 l6,-3" stroke="#fff" stroke-opacity=".55" stroke-width="2" stroke-linecap="round"/>`;
  if (L.grease) out += `<path d="M118,122 q6,2 9,-1" stroke="#3a3530" stroke-width="3" stroke-linecap="round" opacity=".55"/>`;
  if (L.pencil) out += `<g transform="translate(${100 + L.face[0] / 2 + 6} 88) rotate(28)"><rect x="-2.6" y="-16" width="5.2" height="30" fill="#f2b51f" stroke="${INK}" stroke-width="1.1"/><path d="M-2.6,14 L0,20 L2.6,14 Z" fill="#e8c9a0" stroke="${INK}" stroke-width="1"/></g>`;
  return out;
}

// ---------------------------------------------------------------- composición
function contours(L, m) {
  const w = L.face[0] / 2, [, dark] = SKIN[L.skin], age = L.age || 0;
  let out = `<path d="M${100 - w + 8},112 Q${100 - w + 12},126 ${100 - L.face[1] / 2 + 6},134" fill="none" stroke="${dark}" stroke-width="1.6" opacity=".55" stroke-linecap="round"/>`;
  if (age >= 1) out += `<path d="M88,115 Q85,122 86,128 M112,115 Q115,122 114,128" fill="none" stroke="${dark}" stroke-width="1.5" opacity=".7" stroke-linecap="round"/>`;
  if (age >= 2) out += `<path d="M86,70 Q100,66 114,70 M89,76 Q100,73 111,76" fill="none" stroke="${dark}" stroke-width="1.2" opacity=".6" stroke-linecap="round"/><path d="M${100 - 30},100 l-4,2 M${100 - 30},96 l-4,-1 M${100 + 30},100 l4,2 M${100 + 30},96 l4,-1" stroke="${dark}" stroke-width="1.1" opacity=".7" stroke-linecap="round"/>`;
  if (age >= 3) out += `<path d="M84,108 q-3,4 -1,8 M116,108 q3,4 1,8" fill="none" stroke="${dark}" stroke-width="1.2" opacity=".6"/><path d="M92,140 q8,4 16,0" fill="none" stroke="${dark}" stroke-width="1.2" opacity=".5"/>`;
  if (m.tilt > 6) out += `<path d="M96,88 l1,6 M104,88 l-1,6" stroke="${dark}" stroke-width="1.4" opacity=".8" stroke-linecap="round"/>`;
  return out;
}
let uid = 0;
/** SVG de un personaje con una emoción. */
export function faceSVG(person, mood = 'happy') {
  const L = LOOKS[person] || LOOKS.minister, m = MOODS[mood] || MOODS.happy, id = 'f' + (uid++);
  const [skin, dark] = SKIN[L.skin], w = L.face[0] / 2, face = facePath(L.face);
  const fill = m.pale ? mixColor(skin, '#e6ebe2', .22) : skin;
  const head = `<g transform="translate(100 120) scale(1.24) translate(-100 -112)">${ears(L)}
  <path d="${face}" fill="${fill}" stroke="${INK}" stroke-width="1.5"/>
  <path d="M${100 - w + 10},84 Q${100 - w + 14},70 ${100 - w + 22},64" fill="none" stroke="#fff" stroke-opacity=".25" stroke-width="4" stroke-linecap="round"/>
  ${contours(L, m)}${hairFront(L)}${brows(L, m)}${eyes(L, m)}${nose(L)}${facialHair(L, m)}${mouth(L, m)}${extras(L, m)}
  <g clip-path="url(#k${id})" style="mix-blend-mode:multiply"><ellipse cx="${100 + w * 1.25}" cy="108" rx="${w * .88}" ry="80" fill="${dark}" opacity=".5" filter="url(#s${id})"/></g></g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 240" role="img"><defs>
  <filter id="w${id}" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency=".045" numOctaves="2" seed="${(id.length * 7) % 9 + 2}"/><feDisplacementMap in="SourceGraphic" scale="1.7"/></filter>
  <filter id="s${id}" x="-60%" y="-30%" width="220%" height="160%"><feGaussianBlur stdDeviation="8"/></filter>
  <filter id="n${id}"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 .2  0 0 0 0 .15  0 0 0 0 .1  0 0 0 .55 0"/></filter>
  <clipPath id="k${id}"><path d="${face}"/></clipPath></defs>
  <g clip-path="url(#c${id})">${background(L, id)}<g filter="url(#w${id})">
  <g transform="translate(100 120) scale(1.24) translate(-100 -112)">${hairBack(L)}</g>${clothes(L, mood)}${neck(L)}${head}</g>
  <rect width="200" height="240" filter="url(#n${id})" opacity=".35"/>
  <rect x="1" y="1" width="198" height="238" rx="13" fill="none" stroke="#f6e3b4" stroke-opacity=".4" stroke-width="2"/></g></svg>`;
}
function mixColor(a, b, t) {
  const p = x => [1, 3, 5].map(i => parseInt(x.slice(i, i + 2), 16)), A = p(a), B = p(b);
  return '#' + A.map((v, i) => Math.round(v + (B[i] - v) * t).toString(16).padStart(2, '0')).join('');
}
const cache = new Map();
/** URL de imagen (data URI) del retrato, para usar como fondo. */
export function faceURL(person, mood = 'happy') {
  const k = person + mood;
  if (!cache.has(k)) cache.set(k, 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(faceSVG(person, mood)));
  return cache.get(k);
}
export const MOOD_LIST = Object.keys(MOODS);
