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


if __name__ == "__main__":
    unittest.main()
