import {mkdir, copyFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
// The public portal is maintained in one place. Rebuilding this older project
// must never replace it with a stale installer link or remove the USB panel.
await import('../portal/package-downloads.mjs');
const downloads = path.dirname(fileURLToPath(import.meta.url));
const portal = path.join(downloads, '../portal');
for (const file of ['index.html', 'style.css', 'mark.svg', 'downloads.js', 'download-catalogue.js',
  'privacidad/index.html', 'servidor/index.html', 'servidor/usb.css', 'servidor/usb.js']) {
  const target = path.join(downloads, 'public-site', file);
  await mkdir(path.dirname(target), {recursive: true});
  await copyFile(path.join(portal, file), target);
}
console.log('Static /descargas package ready from the canonical portal and verified manifests.');
