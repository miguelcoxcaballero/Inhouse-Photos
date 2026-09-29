# Inhouse Photos containers

The Windows manager installs or adopts the supported server configuration. For most users, download it from the [Inhouse Photos page](https://fotos.miguelcoxcaballero.com/descargas/) instead of editing Compose files manually.

The Compose services retain their existing internal names and API paths for compatibility with libraries already in use. Do not rename a database, volume, service, or media path merely to change the visible product branding. Back up the database and photos before changing a running installation.

The underlying server is based on Immich and retains its required source and license notices; see the [project README](../README.md) and [AGPL license](../LICENSE).

For the local hotpatch image, build the server and web client first (`pnpm --dir server run build` and `pnpm --dir web run build`). `Dockerfile.inhouse-server-hotpatch` copies both outputs into the existing production image; it does not include or modify database and media volumes.
