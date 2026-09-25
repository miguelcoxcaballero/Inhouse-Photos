# Inhouse Photos Server 1.1 — Windows

An integrated wizard can now create a new library, in addition to linking an
existing server. Choose an empty local folder, enter your account details, and
follow the preparation steps. Existing libraries are never overwritten.

- Missing engine: official signed Docker Desktop download with explicit license
  acceptance. Windows prerequisite preparation requests normal administrator
  approval and never automatically reboots the computer.
- Inhouse server component: separate one-time download, pinned SHA-256 and Docker
  image identity. The small desktop installer does not contain private accounts.
- New library: separate services and Linux database volume, loopback-only until
  an administrator account is created and verified. Setup can be resumed using
  the same folder and password.
- Optional HTTPS domain: Caddy starts only after account setup. Point DNS at the
  PC and forward router ports 80/443. Without a domain access is local to the PC;
  the installer cannot bypass CGNAT or configure arbitrary routers automatically.
- Recovery verification now waits for final PostgreSQL TCP readiness, avoiding
  the temporary initialization server shutting down during restore.

Start-at-sign-in, disk inventory, protected storage and existing-library adoption
remain available. Photo files use the selected folder; database and model volumes
use the engine's configured Linux data disk. No automatic disk formatting occurs.

Requirements: supported x64 Windows, virtualization and sufficient free disk
space. Windows may require a reboot or permission approval on first installation.
The installer is unsigned; do not disable Windows security protections.

The Inhouse server image is based on Immich 3.1.0. Corresponding modified source
and licensing are available in this repository; third-party notices remain in
the distributed image. This Windows release does not change Android updates.
