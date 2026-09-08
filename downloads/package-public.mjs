import { readFile, mkdir, copyFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
// This page only contains navigation/download links. No client runtime is
// needed; removing hydration also avoids loading any server-related packages.
const source = await readFile('dist/client/index.html', 'utf8');
let html = source.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
  .replace(/<link\b(?=[^>]*\brel="modulepreload")[^>]*>/gi, '')
  .replace(/<link\b(?=[^>]*\brel="(?:modulepreload|preload)")(?=[^>]*\bas="script")[^>]*>/gi, '')
  .replaceAll('href="/_next/', 'href="/descargas/_next/');
const styles = [...html.matchAll(/href="\/descargas\/(_next\/[^"?]+\.css)"/g)].map(m => m[1]);
if (!html.includes('Descargar APK') || !html.includes('Descargar para Windows') || styles.length === 0) throw new Error('Download page is incomplete');
await mkdir('public-site', { recursive: true });
for (const file of new Set(styles)) {
  await mkdir(path.dirname(path.join('public-site', file)), { recursive: true });
  await copyFile(path.join('dist/client', file), path.join('public-site', file));
}
await copyFile('public/inhouse.svg', 'public-site/inhouse.svg');
await writeFile('public-site/index.html', html);
console.log('Static /descargas package ready; no JavaScript runtime or private files included.');
