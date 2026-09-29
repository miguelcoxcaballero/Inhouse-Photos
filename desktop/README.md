# Inhouse Photos Server for Windows

Native WPF management application for an existing Inhouse Photos library or a
compatible installation.
It adopts the existing Compose project without replacing images, accounts or
volumes. Closing the app does not stop the server. No credentials are embedded
in the executable. Requires Windows 10/11 with .NET Framework 4.8.

Build: `powershell -File desktop/build.ps1`. Run `--self-test` for non-mutating
checks. `--render-preview PATH.png` renders the application's own window offscreen.

Implemented: per-user installer with SHA-256 validation and versioned files,
installation discovery, health checks, hidden engine start, start
existing services, tray supervisor, opt-in Windows sign-in startup, disk usage,
physical-disk inventory, database snapshots,
copy-only media backup to a separate volume, endpoint validation and mobile linking.
Database snapshots alone are not a backup of the photos. The UI explicitly says
so. Copy-only backups never mirror deletions or overwrite existing files.

Adoption exports a consistent PostgreSQL snapshot, restores it to an isolated,
labelled disposable database, compares asset/user/album counts, and rechecks
container identities and configuration hashes before saving a receipt. Original
containers and media stay in place. Configuration copies use current-user DPAPI.
The database snapshot does not include media files.

Manager 1.2.3 uses five clear destinations: Overview, Connect mobile, Backups,
Storage, and Settings. Its restrained light interface uses typography, spacing,
and a small number of status surfaces instead of a dense list of technical
controls or decorative cards. The installer, existing-library adoption, and
new-server wizard follow the same visual hierarchy. Windows and the setup
wizard fit within the available desktop area at higher display scaling. A
loopback-only new server is never offered as a mobile address; the HTTPS
address can be configured from the main Settings page. Changing backup
destination leaves the previous copy visible but marks the selected destination
as pending until a full backup completes there.

For an already linked server, the manager accepts routine replacement of the
web, machine-learning, Redis, and Caddy containers and images. It still requires
the original Compose project and service set, every storage mount, the database
image, and configuration-file hashes to match the migration receipt. The database
must retain a writable persistent mount at `/var/lib/postgresql/data`, and the
web server a writable persistent media mount at `/data`. During a
new migration snapshot, the exact container IDs and images must remain unchanged.

Manager 1.2.0 introduced four main areas: Overview, Backups, Storage, and Settings.
The overview prioritizes local availability, free space on the actual library
disk, the last completed full backup, and a contextual next action. A public
URL responding from the PC is labelled as such; it is not proof of access from
outside the home. Device connection is an Overview action. Raw service status,
database-only snapshots, and Storage Spaces are under technical/advanced
controls, not the normal route through the product.

Full backup now records a success marker only after both a database SQL dump
and a media copy have completed. The database is captured before the media
copy to preserve a consistent recovery point while uploads may continue. The
copy checks source/target names, sizes and timestamps before marking success;
it refuses to overwrite an existing file that changed, to protect the prior
copy. This is not a checksum audit or a tested full restore. Optional weekly
copies are disabled by default, require a separate volume (ideally a different
physical disk) and the manager running, and never enable themselves during
migration or upgrade. Failed scheduled runs have bounded retry delays; they
are not marked successful.

Existing-server setup (1.1.1): the home screen can discover a running Compose
library automatically. The user checks the folder and presses one button. Five
visible stages explain the safe snapshot/restore verification; failure leaves
the existing server untouched and offers a retry. If a server image changed
after the initial adoption, re-verification creates a new receipt without
discarding the old one until the isolated restore succeeds. The installer
validates its embedded payload and, if an older manager is open, explains how
to close only that manager and retry. This does not stop the photo server.

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
