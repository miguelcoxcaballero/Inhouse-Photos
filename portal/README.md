# Public download portal

This is the static page served by the existing Caddy route at `/descargas/`.
The files in `servidor/` provide the administrator's existing USB status panel.
`downloads/public-site` is generated from this same source.

Run `node portal/package-downloads.mjs` from the repository root to refresh the
static download fallbacks and `download-catalogue.js` from the verified Windows
and Android manifests. The Windows manager embeds this package and publishes
it only to the already recognised, persistent Caddy download directory. It
preserves the LAN hint, Caddy settings, photographs and account data.

The manager refreshes the public catalogue approximately every ten minutes,
independently of a pending engine update. It updates the static HTML download
links as well, so a stricter existing CSP or disabled JavaScript does not retain
an old installer link. It preserves unknown customised resources, keeps private
HTML backups and replaces recognised files atomically after checking hashes,
the existing route, the receipt and persistent writable Caddy mounts. No Caddy
configuration change or reload is needed.

The manager can replace `download-catalogue.js` with newer validated manifest
data without rebuilding the page. Its format is:

```js
window.InhousePhotosDownloads.applyLatest({
  windows: {Version: "3.1.96", InstallerUrl: "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.96/Inhouse-Photos-Server-Setup.exe", Sha256: "<64 lowercase hexadecimal characters>"},
  android: {version: "3.1.96", apkUrl: "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/v3.1.96-unified/Inhouse-Photos.apk", sha256: "<64 lowercase hexadecimal characters>"}
});
```

`downloads.js` loads that same-origin file with a fresh query string and checks
the version, checksum and exact release URL before changing any link. It uses
the current `script-src 'self'` policy and needs no fetch permission or Caddy
reload. The page remains usable with JavaScript disabled or offline catalogue
refreshes, using the last verified static links.

Only public HTML, styles, scripts and marks belong in this package. The
catalogue contains no credentials, settings, tokens, library paths or photos.

## Full Windows installation and compact updates

The Windows update manifest keeps `InstallerUrl` and `Sha256` for the compact
installer used by existing automatic updaters. Do not replace that URL with the
large installer: older clients enforce a small update-download limit.

For a complete first download, the same manifest may also contain
`FullInstallerUrl` and `FullInstallerSha256`. Both fields must be present and
valid together. The URL must be the exact same-version GitHub asset
`server-v<Version>/Inhouse-Photos-Server-Full-Setup.exe`, and the checksum must
be 64 lowercase hexadecimal characters. Partial or invalid full metadata is
rejected rather than silently advertising a different download.

The website, offline HTML package and public catalogue prefer that verified
full installer, including the photo engine. Manifests without either optional
field remain compatible with the legacy compact download. A catalogue at the
same version may add a full installer, but an older compact-only response
cannot remove one already verified. Never publish either download field until
its corresponding public asset has been verified.

## Repairing a PC still installing 3.1.96

Use the [Windows 3.1.97 installer](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.97/Inhouse-Photos-Server-Setup.exe)
directly if the public page still offers an older installer. Close the manager
using its tray menu's **Salir del gestor**, then install with the same Windows
account. If the old busy manager cannot exit, temporarily disable only the
**Inhouse Photos Server** scheduled task after checking that its action is
`%LOCALAPPDATA%\Programs\Inhouse Photos Server\Inhouse Photos.exe --startup`.
Restart Windows, run the new installer before opening the old manager and
re-enable automatic startup from the new manager. The stored library and
pending update remain available for recovery.

Installing the new manager triggers local publication of the nine public
resources. Publishing a GitHub release alone does not change the PC's web
storage. `public-downloads/last-publication.txt` in the manager's private
settings directory records `files-verified`, which confirms local file hashes;
check the public `/descargas/` response separately to confirm delivery through
the user's domain. No remote deployment credentials are assumed.
