# Inhouse Photos Server for Windows

Native WPF management application for an existing Inhouse Photos library or a
compatible installation.
It adopts the existing Compose project without replacing images, accounts or
volumes. Closing the app does not stop the server. No credentials are embedded
in the executable. Requires Windows 10/11 with .NET Framework 4.8.

Build: `powershell -File desktop/build.ps1`. Run `--self-test` for non-mutating
checks. `--render-preview PATH.png` renders the application's own window offscreen.
The build downloads QRCoder 1.8.0 from NuGet, verifies the pinned SHA-512 from
NuGet's catalog, and embeds its .NET Framework DLL in the manager and installer.
The installed program does not need a QR service or a separate DLL.

Connect mobile now starts a three-minute, one-use QR invite after an admin signs
in once on the PC. Only the access token is saved, encrypted for the current
Windows user with DPAPI; the password is never saved. The QR uses the public
`/vincular` landing page with the configured HTTPS server origin and invite in
the URL fragment. Pairing API calls go only to the manager's loopback endpoint.
Both devices must show the same six-digit code before the PC authorizes the
phone. The page supports expiry and cancellation. Manual address-and-password
connection remains available under a secondary disclosure. New-server setup
stores its already-verified admin session for this flow when possible.

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

Manager 1.2.13 starts the remote management bridge immediately when opened,
including a normal visible launch. It validates and hot-reloads the existing
HTTPS route once per launch or proxy/configuration change, so a saved Caddyfile
is not mistaken for an active route. The photo server remains running.

Manager 1.2.15 detects present USB phones independently of network sharing.
Overview, Connect mobile and Settings show whether Windows sees the cable and
the exact next step. The live web panel at `/descargas/servidor/` uses the
existing administrator web session for read-only diagnostics. USB presence,
network availability and actual transfer are separate: an MTP/charging phone
is not reported as uploading. Detection never changes routes or installs
drivers; the explicit preparation action remains limited to a verified phone
network. The existing mobile version 3.1.93 needs no rebuild for these changes.

Manager 1.2.12 extends the administrator-only HTTPS bridge with read-only
server, drive and backup status, plus fixed actions for full backup, weekly
schedule, snapshot, backup-drive selection and Windows startup. The mobile app
cannot send an arbitrary command or filesystem path. Physical disk and RAID
changes remain on the PC because they can irreversibly affect data.

Manager 1.2.7 keeps the same five destinations and publishes a private-network
route for the mobile uploader. The phone still authenticates the public HTTPS
hostname; the manager only refreshes the computer's LAN address, and public
access remains the fallback. New managed servers include the discovery route.

Manager 1.2.11 checks `windows-server-update.json` over HTTPS, verifies the
published installer SHA-256, embedded version and payload, and offers an Update
button in Settings. A helper waits for the manager to exit, switches only its
versioned executable, then reopens it. Docker, Caddy and media are not stopped.
The manager also exposes a narrowly scoped remote update route through Caddy.
Only a signed-in server administrator can read its status or request the latest
published manager version; the phone cannot choose a command, URL or version.
Caddy supplies a per-installation bridge secret, and the manager validates the
administrator token against the local photo API. The route is inserted only
after validation, hot-reloaded, and reflected in the adoption receipt. A
failed route change restores the prior Caddyfile. If the manager installation
fails, the previous verified executable is reopened. The photo API remains
independent of the manager throughout the hand-off.

Inhouse Photos 3.1.96 uses one public version for Android and Windows and one
**Update** button in **Settings > Server management**. The PC installs the
required components and persists the continuation before its manager restarts;
the phone can disconnect without cancelling it. Completion requires the real
engine identity, health, installation receipt and recovery journal to agree.
Interrupted operations have bounded automatic retries, with the same button
available to continue. Windows PowerShell 5.1's normal native stderr progress
is handled separately from JSON output and failure exit codes. An already
blocked 1.2.17 installation needs a one-time Windows installer repair because
that old executable rejects its own remote upgrade while a journal is pending.
The engine restart briefly interrupts the photo API. See
[SERVER-RUNTIME-UPDATES.md](SERVER-RUNTIME-UPDATES.md) for the identity checks
and recovery rules.

Manager 1.2.5 uses five clear destinations: Overview, Connect mobile, Backups,
Storage, and Settings. Its layout gives the server state one primary action,
shows space and backup facts without nested cards, and moves technical controls
out of the everyday flow. Page and setup-step transitions are brief and respect
Windows reduced-motion preferences. The installer, existing-library adoption,
and new-server wizard follow the same visual hierarchy. Windows and the setup
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
