# Inhouse Photos Server for Windows

Native WPF management application for an existing Inhouse/Immich installation.
It adopts the existing Compose project without replacing images, accounts or
volumes. Closing the app does not stop the server. No credentials are embedded
in the executable. Requires Windows 10/11 with .NET Framework 4.8.

Build: `powershell -File desktop/build.ps1`. Run `--self-test` for non-mutating
checks. `--render-preview PATH.png` renders the application's own window offscreen.

Implemented: per-user installer with SHA-256 validation and versioned files,
installation discovery, health checks, hidden engine start, start
existing services, tray supervisor, opt-in Windows sign-in startup, disk usage,
physical-disk inventory, database snapshots,
copy-only media backup to a separate drive, endpoint validation and mobile linking.
Database snapshots alone are not a backup of the photos. The UI explicitly says
so. Copy-only backups never mirror deletions or overwrite existing files.

Adoption exports a consistent PostgreSQL snapshot, restores it to an isolated,
labelled disposable database, compares asset/user/album counts, and rechecks
container identities and configuration hashes before saving a receipt. Original
containers and media stay in place. Configuration copies use current-user DPAPI.
The database snapshot does not include media files.

The startup switch uses a limited, interactive scheduled task: it starts after
Windows sign-in, not before login. It preserves the independent DDNS task.
Disabling startup does not stop a running server. Unlinking restores the prior
startup configuration. There is no forced Docker/WSL restart or container recreation.

Storage Spaces supports mirror/parity creation using only uniquely verified,
empty, poolable disks, with typed confirmation and Windows elevation. Only the
newly created virtual disk can be formatted; existing partitions are refused.
Adding a disk increases pool capacity, not an existing volume automatically.
No existing-data RAID conversion, delete-volume, prune or uninstall-data action
is provided. Real RAID creation requires eligible empty disks and has not been
hardware-tested on this installation.

New-server wizard (1.1): selects an empty local media folder, prepares the engine
with explicit license acceptance, pins and verifies the Inhouse server image,
creates independent service/volume names, creates and verifies the administrator
over loopback, then verifies recovery before taking ownership. Failed setup can
be resumed in the same folder without overwriting its configuration. Passwords
are not stored by the wizard. Windows prerequisite installation requests UAC and
never automatically reboots. Engine installation is only attempted when absent.

The optional domain enables Caddy HTTPS only after the administrator is created.
DNS and router ports 80/443 must point to that PC; the wizard does not bypass CGNAT
or claim remote access before it is reachable. Without a domain the new server is
loopback-only. Media uses the selected disk; database/model volumes use Docker's
configured Linux data disk. The engine component is downloaded separately.

The program is not Authenticode-signed. Do not instruct people to disable
SmartScreen or their antivirus. Publish the SHA-256 with the download.
