# Inhouse Photos Server 1.2.15

- Automatically detects physically present Android/iPhone USB devices before a
  network-sharing interface exists. Unplugged historical devices are excluded.
- Shows live cable status in Overview, Connect mobile and Settings. A charging
  or file-transfer connection is never reported as an active app upload.
- Explains unlock/trust permissions, missing drivers, USB sharing and network
  preparation separately. Preparation is offered only when a verified USB
  network exists and still needs it; it never silently changes the PC network.
- Adds administrator-only read-only USB diagnostics at
  `/inhouse-manager/v1/usb`, including server-calculated freshness. Existing
  web sessions can read diagnostics; all remote mutations still require an
  explicit bearer token and the private proxy bridge.
- Adds the live web panel at `/descargas/servidor/`. Errors do not masquerade as
  an unplugged phone, and stale snapshots are not shown as a ready connection.
- Preserves the current library, accounts, services and normal network.

Connecting a cable automatically starts detection, not an unconditional import
of every file on a phone. OS permission is still required: Android USB network
sharing, or iPhone Personal Hotspot/trust and Apple Devices/iTunes on Windows.
The existing 3.1.93 mobile app selects a verified USB route when available;
keep it open for direct transfers. No USB drivers, ADB or VPN are installed.

Validation: Windows build, fixture-based USB and read-only web-auth self-tests,
installer payload verification and browser panel state tests. Physical transfer
requires a connected phone; no phone was present during this release's PC checks.
