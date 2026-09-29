# Inhouse Photos Server 1.2.9

- Settings now checks for Windows manager updates and installs a verified release from inside the program.
- An administrator can request that same update from App Health on Android or iPhone. The PC verifies the administrator session before accepting it.
- The phone sees download and verification progress. The manager restarts itself after installation; the photo API, Docker containers, and uploads stay running.
- Update downloads are restricted to the Inhouse Photos GitHub release path and checked against the published SHA-256, assembly version and embedded payload hash.
- A failed manager installation reopens the previous verified version. The Windows manager never migrates or deletes media as part of an update.

The remote control requires the Windows manager to be running and the public HTTPS domain to route to the managed Caddy proxy. It is not a remote Docker or server-image update mechanism.
