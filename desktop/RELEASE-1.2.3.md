# Inhouse Photos Server 1.2.3 (Windows)

Fixes an existing-library check that treated a normal application image rollout
as a change of library identity. An already linked server can now keep its
verified connection when Docker recreates the web, machine-learning, Redis, or
Caddy container. Database container IDs may also change without invalidating
the connection, provided its image and storage mounts remain the same.

The safety checks still require the original Compose project, the exact service
set, every storage mount and its access attributes, the database image, and the
saved configuration-file hashes. In particular, the database must retain a
writable bind/volume mount at `/var/lib/postgresql/data`, and the web server a
writable bind/volume media mount at `/data`. A new migration still requires the
exact same containers and images throughout its snapshot and isolated restore.
The manager does not recreate containers or modify library data as part of this check.

Windows 10/11 and .NET Framework 4.8 are required. The binaries are not
Authenticode-signed; SHA-256 checksums are published separately.
