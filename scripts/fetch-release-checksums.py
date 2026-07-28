#!/usr/bin/env python3
"""Resolve the darwin archive SHA-256s for a forge3 release.

Emits `name=value` lines for GITHUB_OUTPUT:

    aarch64_sha=<64 hex>
    x86_64_sha=<64 hex>

Source of truth, in order:

1. The per-asset `<archive>.sha256` files. These are what the SDK actually
   publishes for the darwin archives.
2. The combined `sha256.sum`, if it happens to list the archives.

The combined file is checked *second* deliberately: as of v0.1.190 it contains
only `source.tar.gz`, so a workflow that trusted it alone would find nothing and
either fail or — worse, if written carelessly — pin an empty checksum.

Finally each resolved digest is cross-checked against the `digest` field the
GitHub API reports for the asset, so a tampered checksum file alone cannot move
a pin.

Requires GH_TOKEN (the SDK repository is private).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
ARCHIVES = {
    "aarch64": "forge3-aarch64-apple-darwin.tar.xz",
    "x86_64": "forge3-x86_64-apple-darwin.tar.xz",
}


def fail(message: str):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def request(url: str, token: str, accept: str) -> bytes:
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}", "Accept": accept, "User-Agent": "forgecode-releases-ci"}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        # A private repo answers an unauthenticated/underscoped request with
        # 404, so say so rather than reporting a missing release.
        hint = " (the repository is private: check the token has Contents:read)" if error.code == 404 else ""
        fail(f"GET {url} failed: {error.code} {error.reason}{hint}")
    except urllib.error.URLError as error:
        fail(f"GET {url} failed: {error.reason}")


def parse_checksum_file(text: str, wanted: str) -> str | None:
    """Read a `<sha>  <name>` / `<sha> *<name>` checksum listing."""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        digest, name = parts
        if name.lstrip("*") == wanted and SHA_RE.match(digest):
            return digest
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="tailcallhq/forgecode-sdk")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--require-published", action="store_true", help="fail if the release is still a draft")
    args = parser.parse_args()

    if not TAG_RE.match(args.tag):
        fail(f"tag must match ^v[0-9]+\\.[0-9]+\\.[0-9]+$, got {args.tag!r}")

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        fail("GH_TOKEN is required (the SDK repository is private)")

    release = json.loads(request(f"{API}/repos/{args.repository}/releases/tags/{args.tag}", token, "application/vnd.github+json"))

    # The SDK's flow is: push to main -> release-drafter opens a DRAFT ->
    # artifacts upload -> a human publishes. Only a published release is real.
    if args.require_published:
        if release.get("draft"):
            fail(f"release {args.tag} is still a draft; nothing is released until a human publishes it")
        if release.get("prerelease"):
            fail(f"release {args.tag} is marked prerelease; refusing to ship it to desktop users")

    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    resolved: dict[str, str] = {}
    combined_text = None

    for arch, archive in ARCHIVES.items():
        if archive not in assets:
            fail(f"release {args.tag} has no asset named {archive}")

        digest = None
        sidecar = f"{archive}.sha256"
        if sidecar in assets:
            text = request(assets[sidecar]["url"], token, "application/octet-stream").decode("utf-8", "replace")
            digest = parse_checksum_file(text, archive)
            if digest is None:
                fail(f"{sidecar} does not list a checksum for {archive}")

        if digest is None:
            if combined_text is None:
                if "sha256.sum" not in assets:
                    fail(f"release {args.tag} has neither {sidecar} nor sha256.sum")
                combined_text = request(assets["sha256.sum"]["url"], token, "application/octet-stream").decode("utf-8", "replace")
            digest = parse_checksum_file(combined_text, archive)
        if digest is None:
            fail(f"could not resolve a SHA-256 for {archive} from {sidecar} or sha256.sum")

        # Cross-check against what GitHub itself computed for the stored bytes.
        # This is the defence against a tampered checksum file, so when the API
        # omits `digest` say so loudly rather than silently dropping the check.
        reported = assets[archive].get("digest") or ""
        if reported.startswith("sha256:"):
            if reported[7:] != digest:
                fail(f"{archive}: checksum file says {digest} but the GitHub API reports {reported[7:]}")
        else:
            print(
                f"::warning::{archive}: the GitHub API reported no `digest` field, so the "
                f"checksum-file value could not be cross-checked here. The download is still "
                f"verified against this pin at build time by macos/scripts/fetch-forge3.sh.",
            )

        resolved[arch] = digest

    if resolved["aarch64"] == resolved["x86_64"]:
        fail("both architectures resolved to the same checksum, which means the wrong asset was read")

    output = os.environ.get("GITHUB_OUTPUT")
    lines = [f"aarch64_sha={resolved['aarch64']}", f"x86_64_sha={resolved['x86_64']}"]
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
