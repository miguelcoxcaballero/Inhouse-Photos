import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const code = await readFile(new URL('downloads.js', import.meta.url), 'utf8');
const base = 'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/';
const digest = 'a'.repeat(64);
function browser(version = '3.1.96', scriptPath = '/descargas/downloads.js') {
  const links = {}, scripts = [];
  for (const platform of ['windows', 'android']) {
    links['[data-download="' + platform + '"]'] = [{href: 'unchanged', dataset: {version}}];
    links['[data-download-checksum="' + platform + '"]'] = [{href: 'unchanged'}];
    links['[data-download-version="' + platform + '"]'] = [{textContent: 'unchanged'}];
  }
  const window = {location: {origin: 'https://photos.example.com'}};
  const document = {
    currentScript: {src: window.location.origin + scriptPath},
    querySelectorAll: selector => links[selector] || [],
    createElement: () => ({}),
    head: {appendChild: element => scripts.push(element)},
  };
  vm.runInNewContext(code, {window, document, URL, Date});
  return {window, links, scripts, apply: window.InhousePhotosDownloads.applyLatest};
}
function catalogue(version = '3.1.97') {
  return {
    windows: {Version: version, InstallerUrl: base + 'server-v' + version + '/Inhouse-Photos-Server-Setup.exe', Sha256: digest},
    android: {version, apkUrl: base + 'v' + version + '-unified/Inhouse-Photos.apk', sha256: digest},
  };
}

test('verified manifests update both downloads, versions and checksum links', () => {
  const page = browser(), data = catalogue();
  page.apply(data);
  assert.equal(page.links['[data-download="windows"]'][0].href, data.windows.InstallerUrl);
  assert.equal(page.links['[data-download="android"]'][0].href, data.android.apkUrl);
  assert.equal(page.links['[data-download="windows"]'][0].dataset.sha256, digest);
  assert.equal(page.links['[data-download-version="windows"]'][0].textContent, 'Windows 10 y 11 · Versión 3.1.97');
  assert.equal(page.links['[data-download-checksum="windows"]'][0].href, base + 'server-v3.1.97/SHA256SUMS.txt');
});

test('cached metadata cannot downgrade the static page or a newer response', () => {
  const page = browser();
  page.apply(catalogue('1.2.16'));
  assert.equal(page.links['[data-download="windows"]'][0].href, 'unchanged');
  page.apply(catalogue('3.1.98'));
  page.apply(catalogue('3.1.97'));
  assert.equal(page.links['[data-download="windows"]'][0].dataset.version, '3.1.98');
});

test('arbitrary URLs, cross-version releases and invalid checksums cannot change a download', () => {
  for (const change of [
    data => { data.windows.InstallerUrl = 'javascript:alert(1)'; },
    data => { data.windows.InstallerUrl += '?redirect=https://example.com'; },
    data => { data.windows.InstallerUrl = data.windows.InstallerUrl.replace('github.com/', 'github.com.evil.example/'); },
    data => { data.windows.InstallerUrl = data.windows.InstallerUrl.replace('v3.1.97/', 'v1.2.16/'); },
    data => { data.windows.Sha256 = 'x'.repeat(64); },
    data => { data.windows.Version = '999999999999999999999.1.1'; },
  ]) {
    const page = browser(), data = catalogue();
    change(data); page.apply(data);
    assert.equal(page.links['[data-download="windows"]'][0].href, 'unchanged');
  }
  const page = browser(), data = catalogue();
  data.android.apkUrl = data.android.apkUrl.replace('v3.1.97-', 'v3.1.80-');
  page.apply(data);
  assert.equal(page.links['[data-download="android"]'][0].href, 'unchanged');
});

test('catalogue loading stays same-origin and uses a fresh URL without fetch permission', () => {
  for (const path of ['/descargas/downloads.js', '/descargas/servidor/../downloads.js']) {
    const page = browser('3.1.96', path);
    assert.equal(page.scripts.length, 1);
    const url = new URL(page.scripts[0].src);
    assert.equal(url.origin, 'https://photos.example.com');
    assert.equal(url.pathname, '/descargas/download-catalogue.js');
    assert.match(url.searchParams.get('v'), /^\d+$/);
    assert.equal(page.scripts[0].async, true);
  }
});
