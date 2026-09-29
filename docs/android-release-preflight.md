# Android release preflight

Upload the signed APK to the GitHub release first. GitHub download links use
the asset's actual **filename**, not the optional display label. Set
`android-update.json` to that exact `/releases/download/<tag>/<filename>` URL,
and put the APK's SHA-256 in `sha256` (optionally add `sizeBytes`).

Before publishing the updated manifest, run:

```sh
python -m unittest discover -s .github/scripts -p 'test_verify_android_release.py'
python .github/scripts/verify_android_release.py
```

The second command checks the release tag, exact asset name, published state,
digest, size, and that the public URL resolves to a reachable HTTPS file with
the same byte count. It exits nonzero if any check fails. GitHub Actions repeats
both checks whenever the manifest or preflight code changes on `main`.
