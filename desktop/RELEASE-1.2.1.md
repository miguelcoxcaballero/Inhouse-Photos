# Inhouse Photos Server 1.2.1 (Windows)

The manager is now organized around five simple areas: server overview, mobile
connection, backups, storage, and settings. The overview shows server health,
free space, backup status, and the next useful action in visual cards. The
backup and connection screens use short numbered steps and keep technical
controls separate. The installer, existing-library adoption, and new-server
wizard have matching progress and confirmation screens.

The app now fits within the usable desktop area at higher Windows display
scaling. Local-only addresses such as 127.0.0.1 are no longer presented as
mobile login URLs. The HTTPS address is visible in Settings, but a successful
check there only proves it responds from that PC; test outside access on mobile
data. If the backup destination changes, the earlier completed copy remains
visible while the newly selected destination is marked as pending. Changing the
managed server folder explicitly warns that it disables weekly backups.

This update does not migrate, move, delete, or re-encode existing photos. It
does not stop or replace the running photo server. Closing the manager does not
stop the server. Windows 10/11 and .NET Framework 4.8 are required. The binaries
are not Authenticode-signed. SHA-256 checksums are included as a separate asset.
