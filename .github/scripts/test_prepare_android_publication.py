import importlib.util
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "prepare_android_publication", Path(__file__).with_name("prepare_android_publication.py")
)
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class ConcurrentPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="android-publication-test-")
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        publication.git(self.root, "init", "-b", "main")
        publication.git(self.root, "config", "user.name", "Android release test")
        publication.git(self.root, "config", "user.email", "android-release@example.invalid")
        (self.root / "mobile").mkdir()
        (self.root / "mobile/pubspec.yaml").write_text("version: 3.1.93+5151\n")
        (self.root / "server").mkdir()
        (self.root / "server/service.ts").write_text("const original = true;\n")
        (self.root / "server/package.json").write_text('{"version": "3.1.96"}\n')
        (self.root / "i18n").mkdir()
        (self.root / "i18n/es.json").write_text('{}\n')
        (self.root / "AGENTS.md").write_text("Use the permanent Android key.\n")
        for artifact in publication.ARTIFACTS:
            if artifact != "mobile/pubspec.yaml":
                (self.root / artifact).write_bytes(b"previous published artifact")
        self.source = self.commit("Source to build")

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self, message):
        publication.git(self.root, "add", ".")
        publication.git(self.root, "commit", "-m", message)
        return publication.git(self.root, "rev-parse", "HEAD")

    def test_new_server_changes_are_preserved_without_touching_build_checkout(self):
        (self.root / "server/service.ts").write_text("const recoverBacklog = true;\n")
        (self.root / "server/new-test.ts").write_text("verifyRecovery();\n")
        latest = self.commit("Concurrent server fix")
        publication.git(self.root, "checkout", "--detach", self.source)
        for artifact in publication.ARTIFACTS:
            (self.root / artifact).write_bytes(b"verified new Android artifact")
        # An unrelated local file must also survive publication staging.
        (self.root / "local-build-output.txt").write_text("keep this file\n")
        staged = Path(self.temporary.name) / "publication"
        parent = publication.stage_publication(self.root, self.source, latest, staged)
        self.assertEqual(parent, latest)
        self.assertEqual((staged / "server/service.ts").read_text(), "const recoverBacklog = true;\n")
        self.assertEqual((staged / "server/new-test.ts").read_text(), "verifyRecovery();\n")
        self.assertEqual(publication.git(self.root, "rev-parse", "HEAD"), self.source)
        self.assertEqual((self.root / "local-build-output.txt").read_text(), "keep this file\n")
        self.assertEqual(set(publication.git(staged, "diff", "--name-only").splitlines()), set(publication.ARTIFACTS))
        for artifact in publication.ARTIFACTS:
            self.assertEqual((staged / artifact).read_bytes(), b"verified new Android artifact")

    def test_mobile_changes_require_a_new_build(self):
        (self.root / "mobile/pubspec.yaml").write_text("version: 3.1.95+5153\n")
        latest = self.commit("Newer mobile version")
        with self.assertRaisesRegex(ValueError, "new build is required"):
            publication.require_same_android_inputs(self.root, self.source, latest)

    def test_public_server_version_cannot_change_during_a_unified_build(self):
        (self.root / "server/package.json").write_text('{"version": "3.1.97"}\n')
        latest = self.commit("Change shared public version")
        with self.assertRaisesRegex(ValueError, "server/package.json"):
            publication.require_same_android_inputs(self.root, self.source, latest)

    def test_verified_windows_runtime_pins_can_advance_during_android_build(self):
        (self.root / "desktop").mkdir()
        (self.root / "desktop/RuntimeUpdates.cs").write_text('const string LatestVersion="3.1.96";\n')
        latest = self.commit("Pin verified runtime image for Windows")
        publication.require_same_android_inputs(self.root, self.source, latest)

    def test_translation_changes_require_a_new_build(self):
        (self.root / "i18n/es.json").write_text('{"backup": "Nueva traducción"}\n')
        latest = self.commit("New translation")
        with self.assertRaisesRegex(ValueError, "i18n/es.json"):
            publication.require_same_android_inputs(self.root, self.source, latest)

    def test_concurrent_manifest_publication_is_never_overwritten(self):
        (self.root / "android-update.json").write_text('{"version": "3.1.95"}\n')
        latest = self.commit("Another Android publication")
        with self.assertRaisesRegex(ValueError, "android-update.json"):
            publication.require_same_android_inputs(self.root, self.source, latest)

    def test_updated_release_policy_cannot_be_skipped(self):
        (self.root / "AGENTS.md").write_text("Also verify a new release requirement.\n")
        latest = self.commit("Update publication policy")
        with self.assertRaisesRegex(ValueError, "AGENTS.md"):
            publication.require_same_android_inputs(self.root, self.source, latest)

    def test_changed_publication_script_requires_a_new_build(self):
        scripts = self.root / ".github/scripts"
        scripts.mkdir(parents=True)
        (scripts / "package_inhouse_android.py").write_text("verify_new_identity()\n")
        latest = self.commit("Update APK verification")
        with self.assertRaisesRegex(ValueError, "package_inhouse_android.py"):
            publication.require_same_android_inputs(self.root, self.source, latest)


if __name__ == "__main__":
    unittest.main()
