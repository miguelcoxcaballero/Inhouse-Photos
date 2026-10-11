# Inhouse Photos Android release policy

This file is mandatory guidance for any AI or developer publishing this repository.

## Every Android publication must advance the updater manifest

For every APK update published to GitHub:

1. Increment the semantic version and base build number in `mobile/pubspec.yaml`.
2. Set the same semantic version in `android-update.json`.
3. Set `android-update.json.versionCode` to the ARM64 split APK version code (the base Flutter build number plus 2000).
4. Build `mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` with the permanent Inhouse signing key.
5. Replace both `Inhouse-Photos.apk` and the APK inside `Inhouse-Photos-Android.zip` in the same commit as the manifest.
6. Publish a new GitHub Release and mark it as latest.

Never publish a manifest that points at an APK with a different version, package name, or signing certificate. The app intentionally blocks use when `required` is true and the manifest semantic version is newer.

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

- All new changes and automatic releases go to **A** (rapid changes/testing).
- **B** (reviewed releases) requires the user's **explicit request**. Tests passing is not permission to promote.
- Every release needs a tiny changelog: preferably 2–10 words, maximum 120 characters.
- Never independently edit updater copies. Change the canonical repository first, test, commit, and sync the SAME revision into YouTube, Instagram, Notes, Photos and Read using its `tools/sync.py`.
- Commit `inhouse-updater.lock.json` and shared files together. Build checks must reject drift. App identity and host integration are the only permitted differences.
- Updates are optional. Later snoozes automatic prompts for 14 days; manual updates remain available in settings. The popup and settings both expose A/B selection.
- Keep APK package and signing key; increment Android versionCode globally across A/B. Switching channels never downgrades or deletes user data.
- Publish each exact signed APK before its matching channel catalog. Use `updates/A.json` and `updates/B.json`; never mix channels using generic GitHub latest. B initially has no releases until explicitly requested.
- See the central `AGENTS.md`, `docs/PROTOCOL.md` and `tools/catalog.py` before changing publication logic.

This section supersedes older instructions that mandate blocking update gates, independently copied updaters, or unconditional latest/stable publication. Existing signature and integrity requirements remain in force.
