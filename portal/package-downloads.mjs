import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const portal = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(portal);
const repository = 'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/';
const windows = JSON.parse(await readFile(path.join(root, 'windows-server-update.json'), 'utf8'));
const android = JSON.parse(await readFile(path.join(root, 'android-update.json'), 'utf8'));
for (const [version, hash] of [[windows.Version, windows.Sha256], [android.version, android.sha256]]) {
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version) ||
      version.split('.').some(value => !Number.isSafeInteger(Number(value))) ||
      typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash)) throw new Error('Invalid public download manifest');
}
if (windows.InstallerUrl !== repository + 'server-v' + windows.Version + '/Inhouse-Photos-Server-Setup.exe') {
  throw new Error('Windows download does not match the verified release');
}
const hasFullInstaller = windows.FullInstallerUrl != null || windows.FullInstallerSha256 != null;
if (hasFullInstaller && (windows.FullInstallerUrl !== repository + 'server-v' + windows.Version + '/Inhouse-Photos-Server-Full-Setup.exe' ||
    typeof windows.FullInstallerSha256 !== 'string' || windows.FullInstallerSha256.length !== 64 || !/^[a-f0-9]{64}$/.test(windows.FullInstallerSha256))) {
  throw new Error('Full Windows download URL and checksum must match the same verified release');
}
const windowsDownload = hasFullInstaller ? windows.FullInstallerUrl : windows.InstallerUrl;
const apkPattern = new RegExp('^v' + android.version.replaceAll('.', '\\.') + '(?:-[a-zA-Z0-9._-]+)?/Inhouse-Photos\\.apk$');
if (typeof android.apkUrl !== 'string' || !android.apkUrl.startsWith(repository) ||
    !apkPattern.test(android.apkUrl.slice(repository.length))) throw new Error('Android download does not match the verified release');

const catalogue = {
  windows: {Version: windows.Version, InstallerUrl: windows.InstallerUrl, Sha256: windows.Sha256},
  android: {version: android.version, apkUrl: android.apkUrl, sha256: android.sha256},
};
if (hasFullInstaller) {
  catalogue.windows.FullInstallerUrl = windows.FullInstallerUrl;
  catalogue.windows.FullInstallerSha256 = windows.FullInstallerSha256;
}
// Serialize only explicitly selected public fields, never complete settings or
// API responses. These validated values contain no executable characters.
await writeFile(path.join(portal, 'download-catalogue.js'),
  'window.InhousePhotosDownloads.applyLatest(' + JSON.stringify(catalogue) + ');\n');

for (const filename of ['index.html', 'servidor/index.html']) {
  const file = path.join(portal, filename);
  let html = await readFile(file, 'utf8');
  for (const [platform, version, url] of [
    ['windows', windows.Version, windowsDownload], ['android', android.version, android.apkUrl],
  ]) {
    const linkPattern = new RegExp('(<a\\b[^>]*\\bdata-download="' + platform + '"[^>]*\\bhref=")[^"]*(")', 'g');
    html = html.replace(linkPattern, (_whole, prefix, suffix) => prefix + url + suffix);
    const versionPattern = new RegExp('(<a\\b[^>]*\\bdata-download="' + platform + '")(?: data-version="[^"]*")?', 'g');
    html = html.replace(versionPattern, (_whole, prefix) => prefix + ' data-version="' + version + '"');
    const checksum = url.slice(0, url.lastIndexOf('/') + 1) + 'SHA256SUMS.txt';
    const checksumPattern = new RegExp('(<a\\b[^>]*\\bdata-download-checksum="' + platform + '"[^>]*\\bhref=")[^"]*(")', 'g');
    html = html.replace(checksumPattern, (_whole, prefix, suffix) => prefix + checksum + suffix);
    const labelPattern = new RegExp('(<small\\b[^>]*\\bdata-download-version="' + platform + '"[^>]*>)[^<]*(</small>)', 'g');
    const label = platform === 'windows' ? 'Windows 10 y 11 · Versión ' + version + (hasFullInstaller ? ' · Instalación completa' : '') :
      'Android 8 o posterior · ARM64 · Versión ' + version;
    html = html.replace(labelPattern, (_whole, prefix, suffix) => prefix + label + suffix);
  }
  if (!html.includes('data-download="windows"')) throw new Error('Missing Windows download in ' + filename);
  await writeFile(file, html);
}
console.log('Public download package follows the verified Windows and Android manifests.');
