# Inhouse Photos Server 1.2.0 (Windows)

The manager now answers the important questions first: is the local photo
server available, how much space is left on the actual library disk, and is
there a completed second copy of the photos and database? Its four main areas
are Overview, Backups, Storage, and Settings. Device connection is one action
from Overview. RAID, raw disk inventory, service details, and database-only
snapshots are under advanced controls.

The backup screen records the last successful media-and-database copy and
shows when its destination is unavailable. It never counts the adoption check
or a database-only snapshot as a photo backup. New backups capture the database
before copying media and check file names, sizes, and timestamps before
marking success. Changed files in an earlier backup are never silently skipped
or overwritten: the manager asks for a fresh destination. An optional weekly
schedule can be enabled after choosing a separate volume (ideally a different
physical disk); it is off by default and requires the manager to be running.
Failed or interrupted runs are not marked complete. A completed run is not a
checksum audit or proof of a tested restore.

The server, library paths, accounts, and existing photos are not migrated by
this update. Closing the manager does not stop the photo server. Windows 10/11
and .NET Framework 4.8 are required. The binaries are not Authenticode-signed.
