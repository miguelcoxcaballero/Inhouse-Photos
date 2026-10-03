import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("package_inhouse_android", Path(__file__).with_name("package_inhouse_android.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class AndroidIdentityTests(unittest.TestCase):
    def setUp(self):
        self.badging = "package: name='com.inhousesoftware.photos' versionCode='7152' versionName='3.1.94'\nnative-code: 'arm64-v8a'"
        self.certificates = f"Signer #1 certificate SHA-256 digest: {release.CERTIFICATE}"
        self.symbols = "\n".join(f"00000000 T {symbol}" for symbol in release.JNI_SYMBOLS)

    def check_identity(self, **changes):
        parameters = dict(badging=self.badging, certificates=self.certificates, symbols=self.symbols, version="3.1.94", version_code=7152)
        parameters.update(changes)
        release.verify_identity(**parameters)

    def test_valid_permanent_identity(self):
        self.check_identity()

    def test_different_package_fails(self):
        with self.assertRaisesRegex(ValueError, "package/version"):
            self.check_identity(badging=self.badging.replace("com.inhousesoftware.photos", "app.alextran.immich"))

    def test_base_version_code_cannot_replace_arm64_split_code(self):
        with self.assertRaisesRegex(ValueError, "package/version"):
            self.check_identity(badging=self.badging.replace("7152", "5152"))

    def test_wrong_version_fails(self):
        with self.assertRaisesRegex(ValueError, "package/version"):
            self.check_identity(badging=self.badging.replace("3.1.94", "3.1.93"))

    def test_debug_certificate_fails(self):
        with self.assertRaisesRegex(ValueError, "permanent"):
            self.check_identity(certificates=f"Signer #1 certificate SHA-256 digest: {'a' * 64}")

    def test_multiple_signers_fail(self):
        with self.assertRaisesRegex(ValueError, "permanent"):
            self.check_identity(certificates=self.certificates + f"\nSigner #2 certificate SHA-256 digest: {release.CERTIFICATE}")

    def test_missing_jni_symbol_fails(self):
        with self.assertRaisesRegex(ValueError, "missing required JNI"):
            self.check_identity(symbols=self.symbols.replace("Java_com_inhousesoftware_photos_NativeImage_rotate", "Java_app_alextran_immich_NativeImage_rotate"))

    def test_wrong_abi_fails(self):
        with self.assertRaisesRegex(ValueError, "ARM64"):
            self.check_identity(badging=self.badging.replace("arm64-v8a", "armeabi-v7a"))


class AtomicVersionPublicationTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {"version": "3.1.93", "versionCode": 7151}

    def test_clean_published_source_can_build_next_version_with_explicit_flags(self):
        release.validate_target("3.1.94", 5152, "3.1.93", 5151, self.manifest)

    def test_server_update_advances_from_the_published_durable_upload_release(self):
        release.validate_target("3.1.95", 5153, "3.1.94", 5152, {"version": "3.1.94", "versionCode": 7152})

    def test_unified_release_advances_from_the_published_server_update_release(self):
        release.validate_target("3.1.96", 5154, "3.1.95", 5153, {"version": "3.1.95", "versionCode": 7153})

    def test_source_version_cannot_advance_before_its_verified_artifacts(self):
        with self.assertRaisesRegex(ValueError, "currently published Android manifest must match"):
            release.validate_target("3.1.94", 5152, "3.1.94", 5152, self.manifest)

    def test_release_must_advance_semantic_version(self):
        with self.assertRaisesRegex(ValueError, "advance the updater semantic"):
            release.validate_target("3.1.93", 5152, "3.1.93", 5151, self.manifest)

    def test_release_must_advance_base_build_and_arm64_code(self):
        with self.assertRaisesRegex(ValueError, "advance the updater ARM64"):
            release.validate_target("3.1.94", 5151, "3.1.93", 5151, self.manifest)

    def test_target_version_must_be_semantic(self):
        with self.assertRaisesRegex(ValueError, "semantic version"):
            release.validate_target("latest", 5152, "3.1.93", 5151, self.manifest)

    def test_staged_version_preserves_newlines_and_all_other_pubspec_fields(self):
        original = "name: immich_mobile\nversion: 3.1.93+5151\n\nenvironment:\n  flutter: 3.44.8\n"
        self.assertEqual(
            release.updated_pubspec(original, "3.1.94", 5152),
            "name: immich_mobile\nversion: 3.1.94+5152\n\nenvironment:\n  flutter: 3.44.8\n",
        )


class AndroidReleaseTagTests(unittest.TestCase):
    def test_existing_durable_upload_tag_matches_its_version(self):
        self.assertEqual(release.release_feature("v3.1.94-durable-upload", "3.1.94"), "durable-upload")

    def test_server_update_release_tag_matches_its_version(self):
        self.assertEqual(release.release_feature("v3.1.95-server-update", "3.1.95"), "server-update")

    def test_unified_release_tag_matches_its_product_version(self):
        self.assertEqual(release.release_feature("v3.1.96-unified", "3.1.96"), "unified")

    def test_unified_release_requires_the_actual_server_package_version(self):
        release.validate_shared_version("unified", "3.1.96", "3.1.96")
        with self.assertRaisesRegex(ValueError, "server package versions must match"):
            release.validate_shared_version("unified", "3.1.96", "3.1.0")

    def test_previous_release_features_preserve_their_independent_version_policy(self):
        release.validate_shared_version("server-update", "3.1.95", "3.1.0")

    def test_tag_cannot_advertise_a_different_version(self):
        with self.assertRaisesRegex(ValueError, "target Android version"):
            release.release_feature("v3.1.94-server-update", "3.1.95")

    def test_tag_cannot_use_an_unknown_release_feature(self):
        with self.assertRaisesRegex(ValueError, "supported release feature"):
            release.release_feature("v3.1.95-unsigned-test", "3.1.95")

    def test_tag_cannot_include_a_different_download_path(self):
        with self.assertRaisesRegex(ValueError, "supported release feature"):
            release.release_feature("v3.1.95-server-update/another-asset", "3.1.95")


if __name__ == "__main__":
    unittest.main()
