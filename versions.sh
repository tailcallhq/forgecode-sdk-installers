#!/bin/sh

# Versions shared by every platform package (macOS, Windows, Linux).
#
# One git tag drives one release across all platforms, so these live at the
# repository root rather than in any single platform directory. Per-platform
# details that genuinely differ — archive filenames and their checksums — stay
# in that platform's own scripts/versions.sh.

# ForgeCode's own version, independent of the bundled forge3 helper so UI-only
# releases can ship and a forge3 bump alone does not masquerade as a new app
# release. Updaters (Sparkle on macOS, the MSI manifest on Windows) compare
# this to decide whether an update exists, so it must increase on every
# published build. The release workflow overrides it from the git tag; this is
# the local/dev default.
#
# Pre-1.0: this is not a stable release.
APP_VERSION_DEFAULT="0.1.0"

# The pinned forge3 release bundled into each package. Updating this is a
# deliberate act: the tag and every platform's checksums move together, and
# each platform's fetch script verifies downloads against them.
FORGE3_VERSION="v0.1.190"
FORGE3_REPOSITORY="tailcallhq/forgecode-sdk"
