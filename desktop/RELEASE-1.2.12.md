# Inhouse Photos Server 1.2.12

- Adds administrator-only remote status for the managed Windows server, disks and full backups.
- Allows the mobile app to select a connected backup drive, run or cancel a full backup, schedule weekly backups, create a database snapshot and manage Windows startup.
- Every remote request is checked against the active administrator session and the private HTTPS bridge key. Requests cannot carry a shell command, arbitrary path or request body.
- Physical disk and RAID changes remain local-only. The photo service and active uploads are not restarted by these management actions.
