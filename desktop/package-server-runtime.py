#!/usr/bin/env python3
"""Package the verified runtime and Windows updater as one download."""
import argparse
import hashlib
import json
import pathlib
import zipfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def package(directory, performance):
    desktop = pathlib.Path(__file__).resolve().parent
    manifest_data = (directory / "server-runtime-update.json").read_bytes()
    manifest = json.loads(manifest_data)
    archive = directory / manifest["archiveFile"]
    if file_sha(archive) != manifest["archiveSha256"]:
        raise ValueError("Runtime archive checksum mismatch")
    payload = {"server-runtime-update.json": manifest_data,
               "storage-saver-performance.json": performance.read_bytes(),
               "LEEME-Actualizar.md": (desktop / "SERVER-RUNTIME-UPDATES.md").read_bytes()}
    for filename in ["server-runtime-update.ps1", "server-runtime-queue-handoff.cjs"]:
        data = (desktop / filename).read_bytes()
        # Windows PowerShell 5.1 needs a BOM to display Spanish UTF-8 correctly.
        if filename.endswith(".ps1") and not data.startswith(b"\xef\xbb\xbf"):
            data = b"\xef\xbb\xbf" + data
        payload[filename] = data
    checksums = {name: sha(data) for name, data in payload.items()}
    checksums[archive.name] = manifest["archiveSha256"]
    launcher = """#Requires -Version 5.1
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$expected = @{
"""
    for filename in ["server-runtime-update.json", "server-runtime-update.ps1", "server-runtime-queue-handoff.cjs"]:
        launcher += "  '" + filename + "' = '" + checksums[filename] + "'\n"
    launcher += """}
foreach ($name in $expected.Keys) {
  $path = Join-Path $PSScriptRoot $name
  if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]) {
    throw ('El archivo no coincide con la publicacion: ' + $name)
  }
}
$parameters = @{
  ManifestPath = (Join-Path $PSScriptRoot 'server-runtime-update.json')
  ManifestSha256 = $expected['server-runtime-update.json']
"""
    launcher += "  ArchivePath = (Join-Path $PSScriptRoot '" + archive.name + "')\n"
    launcher += """  Apply = (-not $CheckOnly)
}
& (Join-Path $PSScriptRoot 'server-runtime-update.ps1') @parameters
"""
    payload["Actualizar-servidor.ps1"] = b"\xef\xbb\xbf" + launcher.encode()
    checksums["Actualizar-servidor.ps1"] = sha(payload["Actualizar-servidor.ps1"])
    payload["SHA256SUMS.txt"] = "".join(value + "  " + name + "\n" for name, value in sorted(checksums.items())).encode()
    package_name = "Inhouse-Photos-Server-Runtime-" + manifest["version"] + ".zip"
    output = directory / package_name
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as z:
        z.write(archive, archive.name)
        for filename, data in payload.items():
            z.writestr(filename, data)
    with zipfile.ZipFile(output) as z:
        if z.testzip() is not None:
            raise ValueError("Package ZIP validation failed")
    (directory / "Actualizar-servidor.ps1").write_bytes(payload["Actualizar-servidor.ps1"])
    (directory / "storage-saver-performance.json").write_bytes(payload["storage-saver-performance.json"])
    external = {output.name: file_sha(output), "server-runtime-update.json": sha(manifest_data),
                "storage-saver-performance.json": sha(payload["storage-saver-performance.json"])}
    (directory / "SHA256SUMS.txt").write_text("".join(value + "  " + name + "\n" for name, value in sorted(external.items())))
    print(json.dumps({"package": str(output), "checksums": external}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("performance", type=pathlib.Path)
    args = parser.parse_args()
    package(args.directory, args.performance)
