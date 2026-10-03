"""Stage verified Android artifacts on a newer branch without losing server edits."""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path


ARTIFACTS = ("mobile/pubspec.yaml", "Inhouse-Photos.apk", "Inhouse-Photos-Android.zip", "android-update.json")
PUBLICATION_INPUTS = (
    "mobile",
    "i18n",
    "server/package.json",
    "AGENTS.md",
    ".github/workflows/publish-inhouse-android.yml",
    ".github/scripts/package_inhouse_android.py",
    ".github/scripts/test_package_inhouse_android.py",
    ".github/scripts/prepare_android_publication.py",
    ".github/scripts/test_prepare_android_publication.py",
    *ARTIFACTS,
)


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ("git", "-C", str(root), *arguments), text=True, stderr=subprocess.STDOUT
    ).strip()


def require_same_android_inputs(root: Path, source: str, target: str) -> None:
    changed = git(root, "diff", "--name-only", source, target, "--", *PUBLICATION_INPUTS)
    if changed:
        raise ValueError(
            "Android source, publication policy or existing artifacts changed during the build; "
            f"a new build is required: {changed}"
        )


def stage_publication(root: Path, source: str, target: str, directory: Path) -> str:
    root, directory = root.resolve(), directory.resolve()
    source = git(root, "rev-parse", "--verify", f"{source}^{{commit}}")
    target = git(root, "rev-parse", "--verify", f"{target}^{{commit}}")
    require_same_android_inputs(root, source, target)
    for artifact in ARTIFACTS:
        if not (root / artifact).is_file():
            raise ValueError(f"Verified publication artifact is missing: {artifact}")
    # The source checkout retains its built files. Only the verified publication
    # artifacts are copied into this separate checkout of the latest branch.
    git(root, "worktree", "add", "--detach", str(directory), target)
    try:
        for artifact in ARTIFACTS:
            shutil.copyfile(root / artifact, directory / artifact)
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
    print(f"Staged verified Android artifacts on {parent}; all other branch changes are preserved")


if __name__ == "__main__":
    main()
