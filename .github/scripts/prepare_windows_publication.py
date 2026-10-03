"""Stage a verified Windows update manifest without losing newer Android changes."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path


MANIFEST = "windows-server-update.json"
PUBLICATION_INPUTS = (
    "desktop",
    "AGENTS.md",
    MANIFEST,
    ".github/workflows/publish-inhouse-windows.yml",
    ".github/scripts/prepare_windows_publication.py",
    ".github/scripts/test_prepare_windows_publication.py",
)


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ("git", "-C", str(root), *arguments), text=True, stderr=subprocess.STDOUT
    ).strip()


def require_same_windows_inputs(root: Path, source: str, target: str) -> None:
    changed = git(root, "diff", "--name-only", source, target, "--", *PUBLICATION_INPUTS)
    if changed:
        raise ValueError(f"Windows source or update manifest changed during the build; rebuild required: {changed}")


def validate_manifest(path: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) > 4096:
        raise ValueError("Manifest exceeds the installed manager's download limit")
    manifest = json.loads(raw)
    version = manifest.get("Version", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid Windows version")
    if not re.fullmatch(r"[a-f0-9]{64}", manifest.get("Sha256", "")):
        raise ValueError("Invalid verified installer checksum")
    expected_url = (
        "https://github.com/miguelcoxcaballero/Inhouse-Photos/releases/download/"
        f"server-v{version}/Inhouse-Photos-Server-Setup.exe"
    )
    if manifest.get("InstallerUrl") != expected_url:
        raise ValueError("Installer URL is incompatible with the installed updater")
    if not isinstance(manifest.get("Notes", ""), str) or len(manifest.get("Notes", "")) > 500:
        raise ValueError("Windows release notes exceed the updater limit")
    return manifest


def stage_publication(root: Path, source: str, target: str, directory: Path) -> str:
    root, directory = root.resolve(), directory.resolve()
    source = git(root, "rev-parse", "--verify", f"{source}^{{commit}}")
    target = git(root, "rev-parse", "--verify", f"{target}^{{commit}}")
    require_same_windows_inputs(root, source, target)
    validate_manifest(root / MANIFEST)
    git(root, "worktree", "add", "--detach", str(directory), target)
    try:
        shutil.copyfile(root / MANIFEST, directory / MANIFEST)
    except Exception:
        git(root, "worktree", "remove", "--force", str(directory))
        raise
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    parent = stage_publication(args.root, args.source, args.target, args.directory)
    print(f"Staged the verified Windows manifest on {parent}; other branch changes are preserved")


if __name__ == "__main__":
    main()
