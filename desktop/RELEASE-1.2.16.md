# Inhouse Photos Server 1.2.16

Includes the automatic physical USB detection and clear live status introduced
in 1.2.15, plus a verified web integration fix:

- The live diagnostics page alone can fetch same-origin authenticated USB
  status. The download landing page keeps its restrictive security policy.
- The narrower `/descargas/servidor/*` route is installed by the manager's
  existing validated, backed-up and hot-reloaded configuration workflow.
- Browser cookies remain read-only; commands still require an explicit bearer
  token, administrator validation and the private proxy bridge.
- No photo containers, storage, account credentials or network interfaces are
  stopped, migrated or changed by the manager update.

USB presence is automatically detected. Actual app transfer still requires
the phone's USB network permission and the existing mobile app 3.1.93 open.
Charging/MTP is not falsely reported as uploading. No phone was present in
the PC during release verification, so physical USB transfer remains untested.
