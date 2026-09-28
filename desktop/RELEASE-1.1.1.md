# Inhouse Photos Server 1.1.1 (Windows)

The existing-server setup is now guided: discover the library on this PC,
confirm its folder, and follow five visible verification stages. The manager
checks a consistent database snapshot by restoring it to an isolated temporary
instance. It does not move media, change accounts, recreate production
containers, or stop the server. If a server update changes its container
identity, the manager can re-verify it while keeping the previous connection
record until verification succeeds.

The installer validates its embedded application before installation. When an
older manager is open, it explains how to close only the manager and retry;
the photo server continues running. No credentials are bundled in the installer.

Download `Inhouse-Photos-Server-Setup.exe` on Windows 10/11. The application
requires .NET Framework 4.8. The binaries are not Authenticode-signed.
