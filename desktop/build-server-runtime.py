#!/usr/bin/env python3
"""Create a Docker-loadable runtime from the verified, published server.

The filesystem and dependencies are preserved except for the eight compiled
modules in PR #16 and the startup script. Flattening avoids layer snapshots
on VFS Docker engines. No credentials, media, database, or host files are added.
Build server/dist first with the repository's pinned pnpm lockfile.
"""
import argparse
import copy
import gzip
import hashlib
import io
import json
import pathlib
import re
import shutil
import tarfile
import tempfile

BASE_SHA = "3218c14df0af80c85c5b01d2631ae8341294393f50f9eae05b4505c34b735541"
BASE_INDEX = "283fb546c253d70c3e984062a2d2ebc08ce4547ef799e0ffba634222e4b5c16d"
MODULES = ["enum", "types", "dtos/queue-legacy.dto", "repositories/media.repository",
           "services/asset-media.service", "services/media.service",
           "services/queue.service", "utils/storage-saver"]
PREFIX = "usr/src/app/server/dist/"


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def name(value):
    normalized = str(pathlib.PurePosixPath(value.removeprefix("./")))
    if normalized.startswith("/") or ".." in pathlib.PurePosixPath(normalized).parts:
        raise ValueError("Unsafe archive path")
    return normalized


def add_bytes(out, path, data):
    entry = tarfile.TarInfo(path)
    entry.size, entry.mode = len(data), 0o644
    out.addfile(entry, io.BytesIO(data))


def build(args):
    if not re.fullmatch(r"[a-f0-9]{40}", args.source_commit):
        raise ValueError("Expected exact source commit")
    if digest(args.base_archive) != BASE_SHA:
        raise ValueError("Published base archive checksum mismatch")
    args.output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output_directory, prefix="runtime-build-") as tmp:
        tmp = pathlib.Path(tmp)
        # Save regular blobs only; never extract paths or follow archive links.
        with tarfile.open(args.base_archive, "r|gz") as archive:
            for entry in archive:
                path = name(entry.name)
                if entry.isfile():
                    target = tmp / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open("wb") as f:
                        shutil.copyfileobj(archive.extractfile(entry), f)
        manifest = json.loads((tmp / "manifest.json").read_text())[0]
        config_path = tmp / name(manifest["Config"])
        config = json.loads(config_path.read_text())
        index = json.loads((tmp / "index.json").read_text())
        if index["manifests"][0]["digest"] != "sha256:" + BASE_INDEX:
            raise ValueError("Published base image identity mismatch")
        entries = {}
        handles = []
        try:
            for number, layer_path in enumerate(manifest["Layers"]):
                # OCI layers are gzip-compressed. Inflate once: random file reads
                # from gzip would repeatedly decompress a multi-GB layer.
                raw_path = tmp / ("uncompressed-" + str(number) + ".tar")
                with gzip.open(tmp / name(layer_path), "rb") as source, raw_path.open("wb") as target:
                    shutil.copyfileobj(source, target)
                layer = tarfile.open(raw_path, "r:")
                handles.append(layer)
                pending = []
                # Whiteouts apply to the preceding layer, not current entries.
                for original in layer:
                    entry = copy.copy(original)
                    entry.name = name(entry.name)
                    if entry.name == ".":
                        continue
                    parts = pathlib.PurePosixPath(entry.name)
                    if parts.name.startswith(".wh."):
                        target = str(parts.parent / parts.name[4:])
                        if parts.name == ".wh..wh..opq":
                            target = str(parts.parent)
                            victims = [p for p in entries if p.startswith(target + "/")]
                        else:
                            victims = [p for p in entries if p == target or p.startswith(target + "/")]
                        for victim in victims:
                            del entries[victim]
                    else:
                        pending.append(entry)
                for entry in pending:
                    if not entry.isdir() and entry.name in entries and entries[entry.name][0].isdir():
                        for victim in [p for p in entries if p.startswith(entry.name + "/")]:
                            del entries[victim]
                    body = (layer, entry)
                    if entry.islnk():
                        target = name(entry.linkname)
                        if target not in entries:
                            raise ValueError("Unsupported forward hard link: " + target)
                        linked, body = entries[target]
                        entry.type, entry.size, entry.linkname = tarfile.REGTYPE, linked.size, ""
                    entries[entry.name] = (entry, body)
            schema = hashlib.sha256()
            for path in sorted(entries):
                if path.startswith(PREFIX + "schema/") or path in [PREFIX + "database.js", PREFIX + "repositories/database.repository.js"]:
                    entry, (layer, source) = entries[path]
                    if entry.isfile():
                        schema.update(path.encode() + b"\0")
                        schema.update(layer.extractfile(source).read())
            schema_sha = schema.hexdigest()
            # Exactly the PR's runtime modules; unchanged schema/deps remain base bytes.
            for module in MODULES:
                for suffix in [".js", ".js.map", ".d.ts"]:
                    source = args.dist / (module + suffix)
                    if not source.is_file():
                        raise ValueError("Missing compiled module: " + str(source))
                    path = PREFIX + module + suffix
                    entry = copy.copy(entries[path][0]) if path in entries else tarfile.TarInfo(path)
                    entry.name, entry.type, entry.size = path, tarfile.REGTYPE, source.stat().st_size
                    entry.mode, entry.uid, entry.gid = 0o644, 0, 0
                    entry.linkname = ""
                    entries[path] = (entry, source)
            startup = args.dist.parent / "bin/start.sh"
            path = "usr/src/app/server/bin/start.sh"
            entry = copy.copy(entries[path][0])
            entry.size = startup.stat().st_size
            entries[path] = (entry, startup)
            flat_path = tmp / "layer.tar"
            with tarfile.open(flat_path, "w", format=tarfile.PAX_FORMAT) as flat:
                for path in sorted(entries):
                    entry, body = entries[path]
                    if entry.isfile():
                        if isinstance(body, pathlib.Path):
                            with body.open("rb") as f:
                                flat.addfile(entry, f)
                        else:
                            layer, source = body
                            flat.addfile(entry, layer.extractfile(source))
                    else:
                        flat.addfile(entry)
        finally:
            for layer in handles:
                layer.close()
        config["rootfs"] = {"type": "layers", "diff_ids": ["sha256:" + digest(flat_path)]}
        config["history"] = [{"created_by": "Inhouse Photos verified storage saver runtime; original filesystem plus PR16 modules"}]
        env = config["config"]["Env"]
        env[:] = [item for item in env if not item.startswith(("UV_THREADPOOL_SIZE=", "IMMICH_SOURCE_COMMIT=", "IMMICH_SOURCE_URL=", "IMMICH_SOURCE_REF="))]
        env += ["UV_THREADPOOL_SIZE=16", "IMMICH_SOURCE_COMMIT=" + args.source_commit,
                "IMMICH_SOURCE_REF=perf/storage-saver-throughput",
                "IMMICH_SOURCE_URL=https://github.com/miguelcoxcaballero/Inhouse-Photos/commit/" + args.source_commit]
        labels = config["config"].setdefault("Labels", {})
        labels.update({"org.opencontainers.image.revision": args.source_commit,
                       "org.opencontainers.image.version": args.version,
                       "org.opencontainers.image.source": "https://github.com/miguelcoxcaballero/Inhouse-Photos",
                       "inhouse.runtime.base-image": "sha256:" + BASE_INDEX,
                       "inhouse.runtime.database-schema-sha256": schema_sha})
        config_data = json.dumps(config, separators=(",", ":")).encode()
        image_id = hashlib.sha256(config_data).hexdigest()
        filename = "inhouse-server-" + args.version + ".tar.gz"
        output = args.output_directory / filename
        with output.open("wb") as f, gzip.GzipFile(fileobj=f, mode="wb", mtime=0, compresslevel=1) as gz:
            with tarfile.open(fileobj=gz, mode="w|") as out:
                add_bytes(out, image_id + ".json", config_data)
                entry = out.gettarinfo(flat_path, arcname="layer.tar")
                entry.uid, entry.gid, entry.uname, entry.gname, entry.mtime = 0, 0, "", "", 0
                with flat_path.open("rb") as source:
                    out.addfile(entry, source)
                add_bytes(out, "manifest.json", json.dumps([{"Config": image_id + ".json", "RepoTags": [args.image], "Layers": ["layer.tar"]}]).encode())
        release = {"format": 1, "version": args.version, "sourceCommit": args.source_commit,
                   "image": args.image, "imageId": "sha256:" + image_id,
                   "archiveFile": filename, "archiveSha256": digest(output), "platform": "linux/amd64",
                   "compatibleServerImageIds": ["sha256:" + BASE_INDEX, "sha256:" + config_path.name],
                   "databaseMigrations": "unchanged", "databaseSchemaSha256": schema_sha}
        (args.output_directory / "server-runtime-update.json").write_text(json.dumps(release, indent=2) + "\n")
        print(json.dumps(release, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_archive", type=pathlib.Path)
    parser.add_argument("dist", type=pathlib.Path)
    parser.add_argument("output_directory", type=pathlib.Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--version", default="3.1.0-storage-saver-20261002")
    parser.add_argument("--image", default="inhouse-photos-server:v3.1.0-storage-saver-20261002")
    build(parser.parse_args())
