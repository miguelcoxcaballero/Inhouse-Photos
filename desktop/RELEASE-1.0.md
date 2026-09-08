# Inhouse Photos Server 1.0 for Windows

Download **Inhouse-Photos-Server-Setup.exe** to install the Windows manager.
Existing media, accounts, addresses and containers remain in place. No personal
credentials or database snapshots are included in the download.

- Verified adoption: consistent database snapshot, isolated test restore and
  inventory checks before taking over management.
- Start at Windows sign-in switch, tray operation and background health checks.
- Disk capacity and protected Storage Spaces setup for eligible empty disks.
- Versioned installation with SHA-256 validation.

Validated on the existing installation: 28,406 assets, 1 account, 12 albums;
restore matched; startup enable/disable/enable and scheduled launch passed;
existing server remained online. No production disk was formatted or moved.

Requires an existing compatible Docker Desktop server and .NET Framework 4.8.
This release does not provision a new server or install the engine from scratch.
Startup is after Windows sign-in, not before login. Storage Spaces creation
has safety checks but has not been tested with physical empty disks on this PC.
Database snapshots do not include photo/video files; keep a separate media backup.

The installer is not digitally signed. Keep Windows security protections enabled.
SHA256SUMS.txt contains the download hashes. This separate Windows release does
not change the Android update channel.
