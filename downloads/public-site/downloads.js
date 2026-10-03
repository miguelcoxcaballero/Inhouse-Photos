(() => {
  'use strict';
  const repository = 'https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/';
  const source = document.currentScript;
  if (!source) return;
  const catalogueUrl = new URL('download-catalogue.js', source.src);
  if (catalogueUrl.origin !== window.location.origin) return;
  const latest = Object.create(null);
  const fullInstaller = Object.create(null);
  const versionPattern = /^\d+\.\d+\.\d+$/;
  const hashPattern = /^[a-f0-9]{64}$/;
  for (const platform of ['windows', 'android']) {
    for (const link of document.querySelectorAll('[data-download="' + platform + '"]')) {
      const version = link.dataset.version;
      if (typeof version === 'string' && versionPattern.test(version) &&
          version.split('.').every(value => Number.isSafeInteger(Number(value))) &&
          newerOrEqual(version, latest[platform])) {
        if (version !== latest[platform]) fullInstaller[platform] = false;
        latest[platform] = version;
        if (platform === 'windows' && link.href === repository + 'server-v' + version + '/Inhouse-Photos-Server-Full-Setup.exe') {
          fullInstaller[platform] = true;
        }
      }
    }
  }

  function newerOrEqual(next, previous) {
    if (!previous) return true;
    const a = next.split('.').map(Number), b = previous.split('.').map(Number);
    for (let i = 0; i < 3; i++) {
      if (!Number.isSafeInteger(a[i]) || !Number.isSafeInteger(b[i])) return false;
      if (a[i] !== b[i]) return a[i] > b[i];
    }
    return true;
  }
  function valid(platform, item) {
    if (!item || typeof item !== 'object') return null;
    const version = platform === 'windows' ? item.Version : item.version;
    let url = platform === 'windows' ? item.InstallerUrl : item.apkUrl;
    let hash = platform === 'windows' ? item.Sha256 : item.sha256;
    let full = false;
    if (typeof version !== 'string' || !versionPattern.test(version) ||
        version.split('.').some(value => !Number.isSafeInteger(Number(value))) ||
        typeof hash !== 'string' || !hashPattern.test(hash) || typeof url !== 'string') return null;
    if (platform === 'windows') {
      if (url !== repository + 'server-v' + version + '/Inhouse-Photos-Server-Setup.exe') return null;
      if (item.FullInstallerUrl != null || item.FullInstallerSha256 != null) {
        if (item.FullInstallerUrl !== repository + 'server-v' + version + '/Inhouse-Photos-Server-Full-Setup.exe' ||
            typeof item.FullInstallerSha256 !== 'string' || item.FullInstallerSha256.length !== 64 || !hashPattern.test(item.FullInstallerSha256)) return null;
        url = item.FullInstallerUrl;
        hash = item.FullInstallerSha256;
        full = true;
      }
    } else {
      const escapedVersion = version.replaceAll('.', '\\.');
      const apkPattern = new RegExp('^v' + escapedVersion + '(?:-[a-zA-Z0-9._-]+)?/Inhouse-Photos\\.apk$');
      if (!url.startsWith(repository) || !apkPattern.test(url.slice(repository.length))) return null;
    }
    return {version, url, hash, full, checksums: url.slice(0, url.lastIndexOf('/') + 1) + 'SHA256SUMS.txt'};
  }
  function applyLatest(catalogue) {
    if (!catalogue || typeof catalogue !== 'object') return;
    for (const platform of ['windows', 'android']) {
      const item = valid(platform, catalogue[platform]);
      if (!item || !newerOrEqual(item.version, latest[platform])) continue;
      if (platform === 'windows' && item.version === latest[platform] && fullInstaller[platform] && !item.full) continue;
      latest[platform] = item.version;
      fullInstaller[platform] = item.full;
      for (const link of document.querySelectorAll('[data-download="' + platform + '"]')) {
        link.href = item.url;
        link.dataset.version = item.version;
        link.dataset.sha256 = item.hash;
      }
      for (const link of document.querySelectorAll('[data-download-checksum="' + platform + '"]')) link.href = item.checksums;
      for (const label of document.querySelectorAll('[data-download-version="' + platform + '"]')) {
        label.textContent = platform === 'windows' ? 'Windows 10 y 11 · Versión ' + item.version + (item.full ? ' · Instalación completa' : '') :
          'Android 8 o posterior · ARM64 · Versión ' + item.version;
      }
    }
  }
  Object.defineProperty(window, 'InhousePhotosDownloads', {
    value: Object.freeze({applyLatest}), writable: false, configurable: false,
  });
  // Caddy permits local scripts but deliberately disables fetch on this page.
  // The manager writes only validated, public manifest data to this callback.
  // A unique URL prevents a previously cached catalogue keeping an old link.
  catalogueUrl.searchParams.set('v', String(Date.now()));
  const script = document.createElement('script');
  script.src = catalogueUrl.href;
  script.async = true;
  document.head.appendChild(script);
})();
