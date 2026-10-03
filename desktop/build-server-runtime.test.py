#!/usr/bin/env python3
"""Exercise archive completeness and safety without Docker or production data."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import pathlib
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("runtime_builder", pathlib.Path(__file__).with_name("build-server-runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.dist = self.root / "server/dist"
        for filename in ["main.js", "app.module.js", "schema/index.js",
                         "schema/migrations/" + runtime.UPLOAD_MIGRATION + ".js",
                         "schema/tables/asset-upload-processing.table.js",
                         "schema/tables/asset-upload-receipt.table.js"]:
            target = self.dist / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// " + filename + "\n")
        (self.root / "server/bin").mkdir(parents=True)
        (self.root / "server/bin/start.sh").write_text("#!/bin/sh\nexec node dist/main.js\n")

    def tearDown(self):
        self.temporary.cleanup()

    def test_missing_migration_is_rejected(self):
        (self.dist / "schema/migrations" / (runtime.UPLOAD_MIGRATION + ".js")).unlink()
        with self.assertRaisesRegex(ValueError, "Missing compiled.*migrations"):
            runtime.compiled_files(self.dist)

    def test_stale_artifacts_and_symlinks_are_rejected(self):
        stale = self.dist / "media.baseline.cjs"
        stale.write_text("test fixture")
        with self.assertRaisesRegex(ValueError, "Unexpected compiled artifact"):
            runtime.compiled_files(self.dist)
        stale.unlink()
        stale.symlink_to(self.dist / "main.js")
        with self.assertRaisesRegex(ValueError, "symbolic links"):
            runtime.compiled_files(self.dist)

    def test_changed_dependency_input_is_rejected(self):
        paths = ["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml", "server/package.json",
                 "packages/plugin-sdk/package.json", "packages/sdk/package.json"]
        for filename in paths:
            target = self.root / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"verified dependency input")
        (self.root / "pnpm-lock.yaml").write_bytes(b"changed dependency input")
        with patch.object(runtime.subprocess, "check_output", return_value=b"verified dependency input"):
            with self.assertRaisesRegex(ValueError, "Runtime dependencies differ.*pnpm-lock.yaml"):
                runtime.verify_dependency_inputs(self.root, "a" * 40)

    def test_archive_replaces_complete_application_and_hashes_final_schema(self):
        old = {
            runtime.PREFIX + "schema/index.js": b"old schema",
            runtime.PREFIX + "obsolete-service.js": b"obsolete compiled application",
            "usr/src/app/server/node_modules/retained/dependency.js": b"verified published dependency",
            "usr/src/app/server/bin/start.sh": b"old startup",
        }
        layer = io.BytesIO()
        with tarfile.open(fileobj=layer, mode="w") as archive:
            for filename, content in old.items():
                runtime.add_bytes(archive, filename, content)
        config = {"config": {"Env": ["UNCHANGED=yes"]}, "rootfs": {}, "history": []}
        config_bytes = json.dumps(config).encode()
        config_id = hashlib.sha256(config_bytes).hexdigest()
        image_index = "b" * 64
        base = self.root / "published-base.tar.gz"
        with tarfile.open(base, "w:gz") as archive:
            runtime.add_bytes(archive, config_id, config_bytes)
            runtime.add_bytes(archive, "layer.gz", gzip.compress(layer.getvalue()))
            runtime.add_bytes(archive, "manifest.json", json.dumps([{"Config": config_id, "Layers": ["layer.gz"]}]).encode())
            runtime.add_bytes(archive, "index.json", json.dumps({"manifests": [{"digest": "sha256:" + image_index}]}).encode())
        baseline_schema = hashlib.sha256()
        baseline_schema.update((runtime.PREFIX + "schema/index.js").encode() + b"\0" + b"old schema")
        output = self.root / "release"
        args = argparse.Namespace(base_archive=base, dist=self.dist, output_directory=output,
                                  source_commit="a" * 40, version="3.1.0-durable-upload-test",
                                  image="inhouse-photos-server:durable-upload-test")
        with patch.object(runtime, "BASE_SHA", runtime.digest(base)), \
                patch.object(runtime, "BASE_INDEX", image_index), \
                patch.object(runtime, "BASE_SCHEMA_SHA", baseline_schema.hexdigest()), \
                patch.object(runtime, "verify_dependency_inputs"):
            with patch("builtins.print"):
                runtime.build(args)
        manifest = json.loads((output / "server-runtime-update.json").read_text())
        with tarfile.open(output / manifest["archiveFile"], "r:gz") as archive:
            layer_bytes = archive.extractfile("layer.tar").read()
        with tarfile.open(fileobj=io.BytesIO(layer_bytes), mode="r:") as archive:
            files = {entry.name: archive.extractfile(entry).read() for entry in archive if entry.isfile()}
        self.assertNotIn(runtime.PREFIX + "obsolete-service.js", files)
        self.assertEqual(files["usr/src/app/server/node_modules/retained/dependency.js"], b"verified published dependency")
        for filename, source in runtime.compiled_files(self.dist).items():
            self.assertEqual(files[filename], source.read_bytes())
        final_schema = hashlib.sha256()
        for filename in sorted(files):
            if filename.startswith(runtime.PREFIX + "schema/"):
                final_schema.update(filename.encode() + b"\0" + files[filename])
        self.assertEqual(manifest["databaseSchemaSha256"], final_schema.hexdigest())
        self.assertEqual(manifest["databaseMigrations"], "additive-upload-outbox")
        self.assertEqual(manifest["addedDatabaseMigrations"], [runtime.UPLOAD_MIGRATION])
        self.assertIn("sha256:" + runtime.STORAGE_SAVER_IMAGE, manifest["compatibleServerImageIds"])


if __name__ == "__main__":
    unittest.main()
