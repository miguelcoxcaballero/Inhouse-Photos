# Download page

Published at https://fotos.miguelcoxcaballero.com/descargas/ without changing the
main website or gallery. Source originated in the Sites workspace at
`D:\InhousePhotos-Downloads`; the user explicitly requested their existing domain.
The registered Sites draft is not a second public deployment.

Build using Node 22: `npm ci`, `npm run build`, `node package-public.mjs`.
`public-site` contains only HTML, CSS and the existing logo, with no Node server,
JavaScript hydration, credentials, analytics or private data. Only this directory
is served by Caddy. The build dependencies are not deployed.

The starter's dependency audit reports development/server package advisories.
Do not expose the development server publicly or deploy its server bundle.

Download links should be published only after their GitHub assets are verified.
Windows 0.1 currently manages an existing installation; provisioning a new server
and an integrated RAID wizard are still pending.
