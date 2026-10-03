import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("windows_publication", Path(__file__).with_name("prepare_windows_publication.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class WindowsPublicationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "repository"
        self.root.mkdir()
        self.run_git("init", "--quiet")
        self.run_git("config", "user.name", "Verification")
        self.run_git("config", "user.email", "verification@example.invalid")
        (self.root / "desktop").mkdir()
        (self.root / "desktop" / "ServerApp.cs").write_text("verified Windows source")
        (self.root / publication.MANIFEST).write_text("old update manifest")
        self.source = self.commit("base")
        self.staged = {
            "Version": "1.2.17",
            "InstallerUrl": "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/server-v1.2.17/Inhouse-Photos-Server-Setup.exe",
            "Sha256": "a" * 64,
            "Notes": "Verified Windows release",
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_git(self, *args):
        return subprocess.check_output(("git", "-C", str(self.root), *args), text=True, stderr=subprocess.STDOUT).strip()

    def commit(self, message):
        self.run_git("add", ".")
        self.run_git("commit", "--quiet", "-m", message)
        return self.run_git("rev-parse", "HEAD")

    def write_manifest(self):
        (self.root / publication.MANIFEST).write_text(json.dumps(self.staged))

    def test_preserves_a_newer_android_publication(self):
        (self.root / "android-update.json").write_text("new Android manifest")
        target = self.commit("publish Android")
        self.write_manifest()
        directory = self.root.parent / "publication"
        self.assertEqual(publication.stage_publication(self.root, self.source, target, directory), target)
        self.assertEqual((directory / "android-update.json").read_text(), "new Android manifest")
        self.assertEqual(json.loads((directory / publication.MANIFEST).read_text()), self.staged)
        self.assertEqual(self.run_git("-C", str(directory), "diff", "--name-only"), publication.MANIFEST)

    def test_refuses_changed_windows_source(self):
        (self.root / "desktop" / "ServerApp.cs").write_text("changed Windows source")
        target = self.commit("change Windows")
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "rebuild required"):
            publication.stage_publication(self.root, self.source, target, self.root.parent / "publication")

    def test_refuses_a_concurrent_windows_pointer_update(self):
        (self.root / publication.MANIFEST).write_text("another published manifest")
        target = self.commit("update pointer")
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "rebuild required"):
            publication.stage_publication(self.root, self.source, target, self.root.parent / "publication")

    def test_rejects_an_untrusted_installer_url(self):
        self.staged["InstallerUrl"] = "https://example.invalid/installer.exe"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "incompatible"):
            publication.validate_manifest(self.root / publication.MANIFEST)

    def test_rejects_malformed_or_oversized_manifests(self):
        for field, value in (("Version", "1.2"), ("Sha256", "A" * 64), ("Notes", "a" * 501)):
            with self.subTest(field=field):
                old = self.staged[field]
                self.staged[field] = value
                self.write_manifest()
                with self.assertRaises(ValueError):
                    publication.validate_manifest(self.root / publication.MANIFEST)
                self.staged[field] = old
        (self.root / publication.MANIFEST).write_text(" " * 4097)
        with self.assertRaisesRegex(ValueError, "download limit"):
            publication.validate_manifest(self.root / publication.MANIFEST)


if __name__ == "__main__":
    unittest.main()
