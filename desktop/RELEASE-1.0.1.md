# Windows 1.0.1

- Prepare the engine before attempting server adoption.
- Reuse verified adoption rather than repeat the database migration.
- Refresh saved settings when displaying a page; an old window must not report
  a previously adopted server as unlinked.
- Simple home screen and preparation flow, clearer navigation, technical settings
  and recovery controls collapsed by default.
- Remove timed full-page rebuilds and enforce a five-second connection timeout.
- Changing installations clears the old receipt and pauses automatic startup.

Verified existing-server adoption, integrity checks, installer update and UI render
on this PC. Existing library preserved. New-server provisioning is still not
supported. Startup requires Windows sign-in. Installer remains unsigned.
