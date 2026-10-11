# Inhouse Photos Android release policy

This file is mandatory guidance for any AI or developer publishing this repository.

## Every Android publication must advance the updater manifest

For every APK update published to GitHub:

1. Increment the semantic version and base build number in `mobile/pubspec.yaml`.
2. Set the same semantic version in `android-update.json`.
3. Set `android-update.json.versionCode` to the ARM64 split APK version code (the base Flutter build number plus 2000).
4. Build `mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` with the permanent Inhouse signing key.
5. Replace both `Inhouse-Photos.apk` and the APK inside `Inhouse-Photos-Android.zip` in the same commit as the manifest.
6. Publish a new channel A prerelease with `--latest=false`; B requires the user's explicit request.

Never publish a manifest that points at an APK with a different version, package name, or signing certificate. Legacy APKs read `required:true` to discover the migration. Inhouse services updater uses channel catalogs and never blocks use.

## Required checks

- Run the update-gate and authentication tests.
- Run `dart analyze --fatal-infos` from `mobile/`.
- Build from a clean tree with JDK 21.
- Verify the APK package is `com.inhousesoftware.photos`.
- Verify the APK signature certificate SHA-256 is `121395b18aaeb64ed2b5753eae1d8ac4ad3d2616d459bfcb0e217e679a1b0766`.
- Verify all eight `Java_com_inhousesoftware_photos_*` JNI symbols are present.
- Download the public ZIP after publishing, extract it, and compare the APK SHA-256 with the local build.

# Inhouse services updater — mandatory shared updater policy

Canonical repository: https://github.com/miguelcoxcaballero/inhouse-services-updater

Every AI/developer working in this app must read this section even without opening the updater repository:

- **B is the default update channel.** A requires an English development warning, explicit acknowledgement and slide confirmation. Legacy implicit A preferences migrate to B; choosing B clears A consent. This does not authorize publishing or promoting a B release.
- New changes and automatic releases go to **A** unless the user explicitly requests B.
- **A receives all A and B releases; B receives only B releases.** The highest global Android versionCode wins: a newer B supersedes an older A for A users, while an older B never displaces a newer A.
- **B** (reviewed releases) requires the user's **explicit request**. Tests passing is not permission to publish or promote. B may promote an existing A release or publish a new verified APK directly; a previous A publication is not required.
- Every release needs a tiny changelog: preferably 2–10 words, maximum 120 characters.
- Never independently edit updater copies. Change the canonical repository first, test, commit, and sync the SAME revision into YouTube, Instagram, Notes, Photos and Read using its `tools/sync.py`.
- Commit `inhouse-updater.lock.json` and shared files together. Build checks must reject drift. App identity and host integration are the only permitted differences.
- Updates are optional. Later snoozes automatic prompts for 14 days; manual updates remain available in settings. The popup and settings both expose A/B selection.
- Keep APK package and signing key; increment Android versionCode globally across A/B. Switching channels never downgrades or deletes user data.
- Publish each exact verified signed APK before its matching channel catalog. Never replace a published binary or its immutable metadata. Use `updates/A.json` and `updates/B.json`.
- The publisher mirrors every B release and its exact metadata into A, preserving a newer A as latest. Existing clients therefore receive B releases through A without an APK update. B never falls back to A; neither channel uses generic GitHub latest. B initially has no releases until explicitly requested.
- See the central `AGENTS.md`, `docs/PROTOCOL.md` and `tools/catalog.py` before changing publication logic.

This section supersedes older instructions that mandate blocking update gates, independently copied updaters, unconditional latest/stable publication, disjoint A/B catalogs, or publication in A before an explicitly requested B release. Existing signature and integrity requirements remain in force.
