#!/usr/bin/env python3
"""Rewrite the pinned forge3 version and its per-platform checksums.

Kept out of the workflow YAML so it stays runnable — and testable — locally:

    scripts/bump-forge3.py --tag v0.1.191 \\
        --aarch64-sha <64 hex> --x86-64-sha <64 hex>

Every substitution is anchored to an exact assignment line and asserted to have
matched exactly once. A silent no-op here would ship a package whose declared
version disagrees with the binary inside it, so a pattern that stops matching
must fail the release rather than quietly change nothing.

--check re-reads the files afterwards and verifies the intended values are in
place, which also makes the script safe to re-run (it is idempotent).
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ROOT_VERSIONS = REPO_ROOT / "versions.sh"
MACOS_VERSIONS = REPO_ROOT / "macos" / "scripts" / "versions.sh"


def fail(message: str) -> "typing.NoReturn":  # noqa: F821
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def substitute(path: pathlib.Path, variable: str, value: str) -> str:
    """Replace `VARIABLE="..."` in *path*, requiring exactly one match."""
    if not path.is_file():
        fail(f"expected file is missing: {path}")
    original = path.read_text()
    # Anchored to line start so a mention in a comment cannot be rewritten.
    pattern = re.compile(rf'^{re.escape(variable)}="[^"]*"$', re.MULTILINE)
    found = pattern.findall(original)
    if len(found) != 1:
        fail(
            f"{path}: expected exactly one assignment of {variable}, found {len(found)}. "
            "The file's shape changed; refusing to guess."
        )
    updated = pattern.sub(f'{variable}="{value}"', original, count=1)
    if updated != original:
        path.write_text(updated)
    return original


def verify(path: pathlib.Path, variable: str, value: str) -> None:
    expected = f'{variable}="{value}"'
    for line in path.read_text().splitlines():
        if line == expected:
            return
    fail(f"{path}: {variable} is not {value!r} after rewrite")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="forge3 release tag, e.g. v0.1.191")
    parser.add_argument("--aarch64-sha", required=True, help="SHA-256 of the aarch64 darwin archive")
    parser.add_argument("--x86-64-sha", required=True, dest="x86_64_sha", help="SHA-256 of the x86_64 darwin archive")
    parser.add_argument("--check", action="store_true", help="re-verify the values after rewriting")
    args = parser.parse_args()

    # Treat every input as untrusted: these arrive from a repository_dispatch
    # payload and from a downloaded checksum file.
    if not TAG_RE.match(args.tag):
        fail(f"tag must match ^v[0-9]+\\.[0-9]+\\.[0-9]+$, got {args.tag!r}")
    for name, sha in (("aarch64", args.aarch64_sha), ("x86_64", args.x86_64_sha)):
        if not SHA_RE.match(sha):
            fail(f"{name} checksum must be 64 lowercase hex characters, got {sha!r}")
    if args.aarch64_sha == args.x86_64_sha:
        fail("the two architecture checksums are identical, which means the wrong asset was read")

    substitute(ROOT_VERSIONS, "FORGE3_VERSION", args.tag)
    substitute(MACOS_VERSIONS, "FORGE3_AARCH64_SHA256", args.aarch64_sha)
    substitute(MACOS_VERSIONS, "FORGE3_X86_64_SHA256", args.x86_64_sha)

    if args.check:
        verify(ROOT_VERSIONS, "FORGE3_VERSION", args.tag)
        verify(MACOS_VERSIONS, "FORGE3_AARCH64_SHA256", args.aarch64_sha)
        verify(MACOS_VERSIONS, "FORGE3_X86_64_SHA256", args.x86_64_sha)

    print(f"Pinned forge3 {args.tag}")
    print(f"  aarch64 {args.aarch64_sha}")
    print(f"  x86_64  {args.x86_64_sha}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
