# Inhouse Photos Server 1.2.11

- Detects verified Windows manager releases and installs them from the Settings screen.
- Lets a signed-in server administrator request the same update from App Health on Android or iPhone.
- Shows download and verification progress. The manager closes its remote-control listener before the installer hand-off, then reopens it after updating.
- The photo server, Docker containers, active uploads, HTTPS address, accounts, and library remain running throughout the manager restart.
- Installer SHA-256, embedded version and payload are checked before execution; failed installation reopens the previous verified manager.

This updates only the Windows manager, not the photo server container or database. Remote control requires the manager to be running and the HTTPS domain to reach its managed Caddy proxy.
