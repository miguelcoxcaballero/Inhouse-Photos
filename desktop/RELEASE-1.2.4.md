# Inhouse Photos Server 1.2.4 (Windows)

The everyday manager now uses a flatter, more legible layout. Overview gives
server availability one primary action, followed by space, backup, and mobile
access without nested cards or a duplicate next-step section. Backup and
connection instructions read as simple sequences. The new-library wizard and
existing-library adoption screen use the same visual structure, and the
advanced disk window is consistent with the rest of the app.

Changing pages uses a short fade-and-slide transition; changing setup steps
uses a short fade. Both follow Windows' client-area animation preference and
are disabled for deterministic previews. Health, backup, and error updates
remain immediate. Connection and startup checks no longer hold the entire
page while network or Windows responds.

This release changes only the Windows manager and setup UI. It does not move
photos, replace the server, alter the database, or require another migration.
The existing server can remain online while installing the manager. The old
manager must be closed first; the installer will explain this if necessary.

Requires Windows 10/11 and .NET Framework 4.8. The binaries are not
Authenticode-signed; SHA-256 checksums are published separately.
