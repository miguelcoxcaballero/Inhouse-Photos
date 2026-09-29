# Inhouse Photos 3.1.85

Fixes QR pairing on Android and iPhone. After both devices approve the matching
code, the mobile app now places the new session in its native network client
before requesting account details. Previously that request could return 401 and
leave the phone on “Could not complete sign-in”.

The server and photo library do not need to be migrated. QR invitations are
single-use: if an earlier attempt failed, open **Connect phone** on the PC and
scan a fresh QR after updating the app.
