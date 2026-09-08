# Inhouse Photos Server for Windows

Native WPF management application for an existing Inhouse/Immich installation.
It adopts the existing Compose project without replacing images, accounts or
volumes. Closing the app does not stop the server. No credentials are embedded
in the executable. Requires Windows 10/11 with .NET Framework 4.8.

Build: `powershell -File desktop/build.ps1`. Run `--self-test` for non-mutating
checks. `--render-preview PATH.png` renders the application's own window offscreen.

Implemented: installation discovery, health checks, hidden engine start, start
existing services, disk usage, physical-disk inventory, database snapshots,
copy-only media backup to a separate drive, endpoint validation and mobile linking.
Database snapshots alone are not a backup of the photos. The UI explicitly says
so. Copy-only backups never mirror deletions or overwrite existing files.

Safety boundary: there is no format, delete-volume, prune or uninstall-data action.
Storage Spaces management opens the Windows control panel; this version does not
automatically create a RAID pool or redistribute the library. New server
provisioning and transparent engine installation are not implemented yet.

The program is not Authenticode-signed. Do not instruct people to disable
SmartScreen or their antivirus. Publish the SHA-256 with the download.
