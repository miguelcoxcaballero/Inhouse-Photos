# Contributing to Inhouse Photos

Thank you for helping improve Inhouse Photos. Keep changes focused, describe the user-visible effect, and include the checks you ran. For bugs, open an issue in this repository with reproduction steps and logs after removing credentials, private URLs, and photo metadata.

For Android releases, follow [AGENTS.md](AGENTS.md) exactly: the update manifest, signed APK, and release must agree. For Windows changes, build with `powershell -File desktop/build.ps1` and run the executable's `--self-test` and the installer's `--verify-payload`. For web and server changes, run the relevant package checks before publishing.

This project is an independent, AGPL-licensed fork. Keep the upstream copyright and license notices intact, and keep protocol and storage identifiers compatible with existing libraries unless a tested migration is part of the change.
