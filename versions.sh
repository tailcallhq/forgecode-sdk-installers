#!/bin/sh

# Versions shared by every platform package (macOS, Windows, Linux).
#
# One git tag drives one release across all platforms, so these live at the
# repository root rather than in any single platform directory. Per-platform
# details that genuinely differ — archive filenames and their checksums — stay
# in that platform's own scripts/versions.sh.

# The pinned forge3 release bundled into each package, and the single source of
# truth for the version of everything in this repository. Updating this is a
# deliberate act: the tag and every platform's checksums move together, and
# each platform's fetch script verifies downloads against them.
FORGE3_VERSION="v0.1.190"
FORGE3_REPOSITORY="tailcallhq/forgecode-sdk"

# There is ONE version, and it is the SDK's. The desktop app releases 1:1 with
# forge3: SDK v0.1.191 ships as ForgeCode 0.1.191 in ForgeCode-0.1.191.dmg from
# tag v0.1.191 here. The app has no independent version to drift from the
# server it embeds, so "which forge3 am I running?" is answerable from the app
# version alone, and a released SDK cannot sit unshipped behind a stale app
# number.
#
# Because a forge3 bump is by definition a new app release, updaters (Sparkle
# on macOS, the MSI manifest on Windows) still see a strictly increasing
# version on every published build. CFBundleVersion carries the CI run number
# separately, which is what keeps it monotonic even if a tag is re-released.
#
# Derived, never edited by hand — set FORGE3_VERSION above instead. The
# APP_VERSION environment variable still overrides this for local experiments
# (see each platform's scripts/common.sh).
#
# Pre-1.0: this is not a stable release.
APP_VERSION_DEFAULT="${FORGE3_VERSION#v}"
