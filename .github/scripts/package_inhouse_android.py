"""Verify the permanent Android identity before staging updater artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


PACKAGE = "com.inhousesoftware.photos"
CERTIFICATE = "121395b18aaeb64ed2b5753eae1d8ac4ad3d2616d459bfcb0e217e679a1b0766"
JNI_SYMBOLS = {
    "Java_com_inhousesoftware_photos_NativeBuffer_allocate",
    "Java_com_inhousesoftware_photos_NativeBuffer_free",
    "Java_com_inhousesoftware_photos_NativeBuffer_realloc",
    "Java_com_inhousesoftware_photos_NativeBuffer_wrap",
    "Java_com_inhousesoftware_photos_NativeBuffer_copy",
    "Java_com_inhousesoftware_photos_NativeBuffer_createGlobalRef",
    "Java_com_inhousesoftware_photos_NativeImage_rotate",
    "Java_com_inhousesoftware_photos_NativeImage_convert1010102",
}


def run(*arguments: str) -> str:
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def version_from_pubspec(path: Path) -> tuple[str, int]:
    match = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", path.read_text(), re.MULTILINE)
    if not match:
        raise ValueError("pubspec.yaml must specify a semantic version and base build number")
    return match.group(1), int(match.group(2))


def verify_identity(badging: str, certificates: str, symbols: str, version: str, version_code: int) -> None:
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.MULTILINE)
    if not package or package.groups() != (PACKAGE, str(version_code), version):
        raise ValueError("APK package/version does not match the updater and pubspec.yaml")
    signers = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F:]+)", certificates)
    if len(signers) != 1 or signers[0].replace(":", "").lower() != CERTIFICATE:
        raise ValueError("APK must use the permanent Inhouse signing certificate")
    if "native-code: 'arm64-v8a'" not in badging:
        raise ValueError("APK must be the ARM64 split build")
    present_symbols = set(re.findall(r"\bJava_com_inhousesoftware_photos_\w+\b", symbols))
    missing = JNI_SYMBOLS - present_symbols
    if missing:
        raise ValueError(f"APK is missing required JNI symbols: {', '.join(sorted(missing))}")


def stage(args: argparse.Namespace) -> dict:
    root = args.root.resolve()
    apk = args.apk.resolve()
    version, base_build = version_from_pubspec(root / "mobile/pubspec.yaml")
    version_code = base_build + 2000
    if args.tag != f"v{version}-durable-upload":
        raise ValueError("Release tag must match the pubspec version")
    old_manifest = json.loads((root / "android-update.json").read_text())
    if tuple(map(int, version.split("."))) <= tuple(map(int, old_manifest["version"].split("."))):
        raise ValueError("Android publication must advance the updater semantic version")
    if version_code <= old_manifest["versionCode"]:
        raise ValueError("Android publication must advance the updater ARM64 version code")

    with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory(prefix="inhouse-android-verify-") as temporary:
        if archive.testzip() is not None:
            raise ValueError("APK ZIP integrity check failed")
        native = Path(temporary) / "libnative_buffer.so"
        native.write_bytes(archive.read("lib/arm64-v8a/libnative_buffer.so"))
        symbols = run(args.nm, "-D", "--defined-only", str(native))
    verify_identity(
        run(str(args.build_tools / "aapt"), "dump", "badging", str(apk)),
        run(str(args.build_tools / "apksigner"), "verify", "--print-certs", str(apk)),
        symbols,
        version,
        version_code,
    )
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    manifest = {
        "version": version,
        "versionCode": version_code,
        "required": True,
        "apkUrl": f"https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/{args.tag}/Inhouse-Photos.apk",
        "sizeBytes": apk.stat().st_size,
        "sha256": digest,
    }
    destination = root / "Inhouse-Photos.apk"
    shutil.copyfile(apk, destination)
    bundle = root / "Inhouse-Photos-Android.zip"
    with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.write(destination, "Inhouse-Photos.apk")
        archive.writestr(
            "LEEME.txt",
            f"Inhouse Photos {version} (Android ARM64, versionCode {version_code})\n\n"
            "Instala Inhouse-Photos.apk sobre la aplicación existente.\n"
            "La copia de seguridad continúa después de guardar cada archivo en el servidor; "
            "la optimización se completa allí por separado.\n\n"
            f"SHA-256 APK: {digest}\nCertificado SHA-256: {CERTIFICATE}\n",
        )
    with zipfile.ZipFile(bundle) as archive:
        if archive.testzip() is not None or hashlib.sha256(archive.read("Inhouse-Photos.apk")).hexdigest() != digest:
            raise ValueError("The ZIP does not contain the verified APK")
    (root / "android-update.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report = {
        "sourceCommit": args.source_commit,
        "version": version,
        "versionCode": version_code,
        "package": PACKAGE,
        "certificateSha256": CERTIFICATE,
        "apkSha256": digest,
        "apkSizeBytes": apk.stat().st_size,
        "jniSymbols": sorted(JNI_SYMBOLS),
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--build-tools", type=Path, required=True)
    parser.add_argument("--nm", default="nm")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--report", type=Path, required=True)
    report = stage(parser.parse_args())
    print(f"Verified signed Android {report['version']} ({report['versionCode']}), all eight JNI symbols present")


if __name__ == "__main__":
    main()
