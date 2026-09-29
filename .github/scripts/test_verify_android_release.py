import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify_android_release.py")
SPEC = importlib.util.spec_from_file_location("verify_android_release", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

URL = "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/v3.1.84-pairing/Inhouse-Photos.apk"
SHA = "a" * 64


def fixture():
    manifest = {"version": "3.1.84", "apkUrl": URL, "sha256": SHA, "sizeBytes": 75_000_000}
    release = {
        "tag_name": "v3.1.84-pairing",
        "draft": False,
        "assets": [
            {
                "name": "Inhouse-Photos.apk",
                "label": "An APK",
                "size": 75_000_000,
                "state": "uploaded",
                "digest": f"sha256:{SHA}",
                "browser_download_url": URL,
            }
        ],
    }
    return manifest, release


class VerifyAndroidReleaseTest(unittest.TestCase):
    def validate(self, manifest, release, *, size=75_000_000):
        return MODULE.validate_release(
            manifest,
            release,
            public_url="https://release-assets.githubusercontent.com/file",
            public_size=size,
            public_host="release-assets.githubusercontent.com",
        )

    def test_valid_asset(self):
        self.assertEqual(self.validate(*fixture()), [])

    def test_label_is_not_filename(self):
        manifest, release = fixture()
        release["assets"][0]["name"] = "app-arm64-v8a-release.apk"
        release["assets"][0]["label"] = "Inhouse-Photos.apk"
        self.assertIn("does not exist", " ".join(self.validate(manifest, release)))

    def test_detects_digest_and_size_mismatch(self):
        manifest, release = fixture()
        release["assets"][0]["digest"] = "sha256:" + "b" * 64
        errors = self.validate(manifest, release, size=74_000_000)
        self.assertTrue(any("digest" in error for error in errors))
        self.assertTrue(any("public download size" in error for error in errors))

    def test_rejects_wrong_repository_and_host(self):
        manifest, release = fixture()
        manifest["apkUrl"] = URL.replace("miguelcoxcaballero", "other")
        errors = self.validate(manifest, release)
        self.assertTrue(any("different repository" in error for error in errors))
        self.assertRaises(ValueError, MODULE.release_coordinates, "http://github.com/o/r/releases/download/v/a.apk")


if __name__ == "__main__":
    unittest.main()
