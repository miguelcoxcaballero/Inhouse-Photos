# Inhouse Photos

A private photo and video library for your own computer. Browse from Android or the web, back up new files, and manage the Windows server from one clear dashboard.

[Download Inhouse Photos](https://fotos.miguelcoxcaballero.com/descargas/) · [Windows server installer](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v1.2.5/Inhouse-Photos-Server-Setup.exe) · [Latest Android APK](https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/latest/download/Inhouse-Photos.apk)

## Get started

1. Install Inhouse Photos Server on a Windows 10/11 computer. Choose an empty folder for a new library, or connect an existing library without moving its photos or changing its accounts.
2. Open **Conectar móvil** in the Windows manager. Sign in as an administrator there once; the manager saves only a Windows-encrypted session, not the password. Show the temporary QR code.
3. In the updated Android or iOS app, scan the QR (or open the link with the phone camera), check the matching six-digit number and approve on both phone and PC. The QR expires after three minutes and cannot be reused. Manual HTTPS address and account sign-in remain available. On iPhone, an unsigned build is available through the [SideStore source](https://raw.githubusercontent.com/miguelcoxcaballero/Inhouse-Photos/main/altstore-source.json), which requires SideStore setup and periodic signing renewal; the in-app scanner works even when iOS does not open an unsigned app directly from a web link.

The computer must remain on for remote access. Check the address from the phone using mobile data; a successful test on the PC alone does not prove that it works outside your home. The Windows manager keeps your existing library in place and makes backup status and disk space visible, but a second copy on another disk is still recommended.

## Building

The Windows manager builds with `powershell -File desktop/build.ps1`. Its non-mutating checks are `--self-test`, `--verify-installation`, and the installer's `--verify-payload`.

For Android, install Flutter and run:

```sh
cd mobile
flutter pub get
dart run easy_localization:generate -S ../i18n
dart run bin/generate_keys.dart
flutter build apk --release
```

Published Android APKs must follow [AGENTS.md](AGENTS.md), including the permanent signing certificate and update-manifest checks. The unsigned iOS package is built by the `Build Inhouse Photos iOS (unsigned)` GitHub Action.

## Source and acknowledgements

Inhouse Photos is an independent fork based on [Immich](https://github.com/immich-app/immich) v3.1.0. The underlying compatibility protocol and some internal service identifiers remain unchanged so existing libraries and clients continue to work. This project is not affiliated with or endorsed by the upstream project. The corresponding source is available here under the [GNU AGPL v3](LICENSE); copyright and third-party notices remain in the source and the app's legal information.
