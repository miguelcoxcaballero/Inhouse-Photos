"""Fail before advertising an Android APK that is missing or mismatched.

Run after uploading the release assets and before publishing android-update.json:
    python .github/scripts/verify_android_release.py

The GitHub release asset *name*, not its optional display label, forms the
/releases/download/... URL. This check deliberately verifies both metadata and
the public HTTP endpoint that the installed Android app will use.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, urlopen


MINIMUM_APK_BYTES = 100_000
ALLOWED_DOWNLOAD_HOSTS = {
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
}
RELEASE_PATH = re.compile(r"^/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$")


def release_coordinates(apk_url: str) -> tuple[str, str, str, str]:
    """Return owner/repository/tag/filename from a direct GitHub asset URL."""
    parsed = urlparse(apk_url)
    match = RELEASE_PATH.fullmatch(parsed.path)
    if parsed.scheme != "https" or parsed.hostname != "github.com" or not match or parsed.query or parsed.fragment:
        raise ValueError("apkUrl must be a direct HTTPS GitHub release asset URL")
    return tuple(unquote(part) for part in match.groups())  # type: ignore[return-value]


def validate_release(
    manifest: dict,
    release: dict,
    *,
    public_url: str,
    public_size: int,
    public_host: str,
) -> list[str]:
    """Compare manifest, release metadata, and the final public response."""
    errors: list[str] = []
    try:
        owner, repository, tag, filename = release_coordinates(str(manifest.get("apkUrl", "")))
    except ValueError as error:
        return [str(error)]

    if (owner, repository) != ("miguelcoxcaballero", "Inhouse-Photos"):
        errors.append("apkUrl points to a different repository")
    if release.get("tag_name") != tag:
        errors.append(f"release tag {release.get('tag_name')!r} does not match URL tag {tag!r}")
    if release.get("draft"):
        errors.append("release is still a draft and cannot be downloaded publicly")

    assets = release.get("assets")
    if not isinstance(assets, list):
        return errors + ["release API did not return an assets list"]
    asset = next((item for item in assets if isinstance(item, dict) and item.get("name") == filename), None)
    if asset is None:
        labels = [item.get("label") for item in assets if isinstance(item, dict)]
        errors.append(
            f"release asset named {filename!r} does not exist; an asset label does not change its download URL "
            f"(labels: {labels!r})"
        )
        return errors

    if asset.get("state") != "uploaded":
        errors.append(f"asset state is {asset.get('state')!r}, not 'uploaded'")
    if asset.get("browser_download_url") != manifest.get("apkUrl"):
        errors.append("manifest apkUrl differs from the asset's browser_download_url")
    asset_size = asset.get("size")
    if not isinstance(asset_size, int) or asset_size < MINIMUM_APK_BYTES:
        errors.append(f"asset size {asset_size!r} is too small for an APK")
    elif public_size != asset_size:
        errors.append(f"public download size {public_size} differs from release asset size {asset_size}")
    expected_size = manifest.get("sizeBytes")
    if expected_size is not None and expected_size != asset_size:
        errors.append(f"manifest sizeBytes {expected_size!r} differs from release asset size {asset_size}")

    sha256 = str(manifest.get("sha256", "")).lower()
    digest = asset.get("digest")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        errors.append("manifest sha256 must contain exactly 64 hexadecimal characters")
    elif digest != f"sha256:{sha256}":
        errors.append(f"release asset digest {digest!r} does not match manifest sha256")

    if public_host not in ALLOWED_DOWNLOAD_HOSTS:
        errors.append(f"public download redirected to unexpected host {public_host!r}")
    if not public_url.startswith("https://"):
        errors.append("public download did not resolve over HTTPS")
    return errors


def request_json(url: str) -> dict:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Inhouse-Photos-release-preflight"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def public_download_metadata(apk_url: str) -> tuple[str, int, str]:
    with urlopen(Request(apk_url, method="HEAD", headers={"User-Agent": "Inhouse-Photos-release-preflight"}), timeout=45) as response:
        if response.status != 200:
            raise ValueError(f"public APK URL returned HTTP {response.status}")
        length = response.headers.get("Content-Length")
        if length is None or not length.isdigit():
            raise ValueError("public APK URL did not provide a Content-Length")
        final_url = response.geturl()
        return final_url, int(length), urlparse(final_url).hostname or ""


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    manifest_path = Path(sys.argv[1]) if len(sys.argv) > 1 else repo_root / "android-update.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        owner, repository, tag, filename = release_coordinates(manifest["apkUrl"])
        release = request_json(
            f"https://api.github.com/repos/{quote(owner)}/{quote(repository)}/releases/tags/{quote(tag)}"
        )
        # Report the common label/filename mistake before contacting a URL
        # which necessarily returns 404. This gives the publisher an actionable
        # error instead of only a generic HTTPError.
        if not any(asset.get("name") == filename for asset in release.get("assets", []) if isinstance(asset, dict)):
            errors = validate_release(
                manifest, release, public_url=manifest["apkUrl"], public_size=0, public_host="github.com"
            )
            for error in errors:
                print(f"Android release preflight failed: {error}", file=sys.stderr)
            return 1
        final_url, public_size, public_host = public_download_metadata(manifest["apkUrl"])
        errors = validate_release(
            manifest, release, public_url=final_url, public_size=public_size, public_host=public_host
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError, HTTPError, URLError) as error:
        print(f"Android release preflight failed: {error}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"Android release preflight failed: {error}", file=sys.stderr)
        return 1
    print(f"Android release preflight passed: {manifest['version']} ({public_size:,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
