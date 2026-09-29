# Inhouse Photos 3.1.87

Faster foreground backups on the same home network: the app obtains the PC's
LAN address from the existing HTTPS server, verifies that the local connection
still presents the normal public-domain certificate, and uploads directly over
the LAN. If the local route is unavailable or fails, uploads continue through
the public server without changing accounts or moving existing photos.

This release corrects discovery for the normal saved server endpoint ending in
`/api`, so the LAN route activates for already-linked phones. It also avoids
resetting an active local upload connection when another upload starts.

On a verified LAN, backup begins with eight concurrent transfers and adapts to
the measured throughput, up to sixteen, while server compression remains
bounded separately. No migration or re-linking is required.
