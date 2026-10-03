# Download page

Published at https://fotos.miguelcoxcaballero.com/descargas/ without changing the
main website or gallery. Source originated in the Sites workspace at
`D:\InhousePhotos-Downloads`; the user explicitly requested their existing domain.
The registered Sites draft is not a second public deployment.

The current source is `../portal/`, including the existing USB status panel.
Package it with Node: `node package-public.mjs`. This reads the verified Windows
and Android update manifests, so rebuilding cannot restore old version links.
No installation of this older development project's dependencies is needed.
`public-site` contains only public HTML, CSS, scripts and marks, with no Node
server, React hydration, credentials, analytics or private data. Only this
directory is served by Caddy. The build dependencies are not deployed.

The starter's dependency audit reports development/server package advisories.
Do not expose the development server publicly or deploy its server bundle.

Download links should be published only after their GitHub assets are verified.
The Windows manager publishes this same static portal to an already recognised
download directory after installation, and refreshes its public download
catalogue from the update manifests. See `../portal/README.md`.

If Windows 3.1.96 remains in **Installing**, use the
[3.1.97 installer directly](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v3.1.97/Inhouse-Photos-Server-Setup.exe)
with the same Windows account after closing the manager from its tray menu.
If the busy old manager cannot close, the recovery steps in
`../desktop/RELEASE-3.1.97.md` explain how to disable only its verified startup
task temporarily, restart Windows, install and restore automatic startup.
Library data and queued processing are preserved. The PC publishes its local
web files after the new manager starts; a release publication does not itself
update the public Caddy page.
