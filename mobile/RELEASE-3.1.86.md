# Inhouse Photos 3.1.86

Foreground backups now try a direct connection to the computer when the phone
is on an unmetered local network. The request still uses the normal public
HTTPS hostname and certificate; the app never sends photos to an unverified
plain-HTTP address. If the local route is absent or stops responding, the
same upload automatically continues through the public server.

For large libraries, a verified local route starts eight upload transfers
immediately and adapts up to sixteen. Server-side compression remains bounded
separately so the phone cannot create an unlimited queue on the computer.

No account, photo, album or storage migration is required. The server manager
1.2.6 advertises the current LAN address and refreshes it after network changes.
