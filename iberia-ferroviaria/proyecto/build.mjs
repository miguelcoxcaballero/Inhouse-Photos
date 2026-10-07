// Genera el juego en dos formas:
//  · ../outputs/Iberia-Ferroviaria.html: un único archivo jugable sin conexión, con todas las muestras de la banda sonora.
//  · ../outputs/web/: la misma página sin las muestras dentro (index.html) y, a su lado, los ficheros de muestras
//    (muestras-orquesta.js, muestras-teclas.js, muestras-percusion.js), que la música pide cuando los necesita.
// Cada módulo de dist/ se envuelve en su propio ámbito (mini-empaquetador ES → IIFE),
// y las tipografías e ilustraciones se incrustan como data URI.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, 'dist');
const order = ['assets/geography.js', 'assets/realdata.js', 'assets/railways.js', 'assets/timetable.js', 'data.js', 'story.js', 'schedule.js', 'network.js',
  'engine.js', 'operations.js', 'gtfs.js', 'map-v3.js', 'train-art.js', 'train3d.js', 'city-art.js', 'assets/samples-index.js', 'music.js', 'assets/voices.js', 'voice.js', 'app.js'];

function bundle(file) {
  let text = fs.readFileSync(path.join(dist, file), 'utf8');
  const dir = path.posix.dirname(file);
  const resolve = spec => path.posix.normalize(path.posix.join(dir, spec));
  text = text.replace(/^import\s+\*\s+as\s+(\w+)\s+from\s+'([^']+)';?\s*$/gm, (_, name, spec) => `const ${name} = __m[${JSON.stringify(resolve(spec))}];`);
  text = text.replace(/^import\s+\{([^}]*)\}\s+from\s+'([^']+)';?\s*$/gm, (_, names, spec) => `const {${names.replace(/\s+as\s+/g, ': ')}} = __m[${JSON.stringify(resolve(spec))}];`);
  const exported = new Set();
  text = text.replace(/^export\s+\{([^}]*)\};?\s*$/gm, (_, names) => { names.split(',').map(x => x.trim()).filter(Boolean).forEach(x => exported.add(x)); return ''; });
  text = text.replace(/\bexport\s+((?:async\s+)?function\*?|const|let|class)\s+(\w+)/g, (_, kind, name) => { exported.add(name); return `${kind} ${name}`; });
  if (/^\s*(import|export)\s/m.test(text)) throw Error('Sintaxis de módulo no admitida en ' + file);
  return `// ---- ${file}\n__m[${JSON.stringify(file)}] = (() => {\n${text}\nreturn {${[...exported].join(', ')}};\n})();\n`;
}

let code = 'const __m = {};\n' + order.map(bundle).join('\n');
new Function(code); // validación sintáctica
let html = fs.readFileSync(path.join(dist, 'index.html'), 'utf8');
let css = fs.readFileSync(path.join(dist, 'style-v3.css'), 'utf8');
const mime = {png: 'image/png', jpg: 'image/jpeg', woff2: 'font/woff2'};
css = css.replace(/url\('assets\/([^']+)'\)/g, (_, asset) => {
  const data = fs.readFileSync(path.join(dist, 'assets', asset)).toString('base64');
  return `url('data:${mime[asset.split('.').pop()]};base64,${data}')`;
});
html = html.replace('<link rel="stylesheet" href="style-v3.css">', () => '<style>' + css + '</style>')
  .replace('<script src="assets/three.min.js"></script>', () => '<script>' + fs.readFileSync(path.join(dist, 'assets/three.min.js'), 'utf8').replaceAll('</script', '<\\/script') + '</script>')
  .replace('<script type="module" src="app.js"></script>', () => '<script>\n(() => {\n' + code.replaceAll('</script', '<\\/script') + '\n})();\n</script>')
  .replace('</body>', () => '<script type="text/plain" id="geodata-license">' + fs.readFileSync(path.join(root, 'LICENSE-GEODATA.txt'), 'utf8').replaceAll('</script', '<\\/script') + '</script></body>');
const GROUPS = ['orquesta', 'teclas', 'percusion'], BASE = `<script>globalThis.IBERIA_SAMPLE_BASE = 'assets/';</script>`;
if (!html.includes(BASE)) throw Error('index.html no declara IBERIA_SAMPLE_BASE');
const inline = file => '<script>' + fs.readFileSync(path.join(dist, file), 'utf8').replaceAll('</script', '<\\/script') + '</script>';
const full = html.replace(BASE, () => GROUPS.map(g => inline(`assets/muestras-${g}.js`)).join(''));
const web = html.replace(BASE, () => `<script>globalThis.IBERIA_SAMPLE_BASE = '';</script>`);
const out = path.join(root, '../outputs'), webDir = path.join(out, 'web');
fs.mkdirSync(webDir, {recursive: true});
fs.writeFileSync(path.join(out, 'Iberia-Ferroviaria.html'), full);
fs.writeFileSync(path.join(webDir, 'index.html'), web);
for (const g of GROUPS) fs.copyFileSync(path.join(dist, `assets/muestras-${g}.js`), path.join(webDir, `muestras-${g}.js`));
const mb = n => (n / 1e6).toLocaleString('es-ES', {maximumFractionDigits: 2}) + ' MB';
console.log(`HTML autónomo: ${mb(Buffer.byteLength(full))}, sin dependencias de red para jugar.`);
console.log(`Versión web: index.html ${mb(Buffer.byteLength(web))} + ${GROUPS.map(g => `muestras-${g}.js ${mb(fs.statSync(path.join(webDir, `muestras-${g}.js`)).size)}`).join(', ')}.`);
