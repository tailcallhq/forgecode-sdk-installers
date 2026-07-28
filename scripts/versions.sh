#!/bin/sh

# The ForgeCode app's own version. Independent of the bundled forge3 helper so
# UI-only releases can ship, and so a forge3 bump alone does not masquerade as
# a new app release. Sparkle compares this to decide whether an update exists,
# so it must increase on every published build. The release workflow overrides
# it from the git tag; this value is the local/dev default.
APP_VERSION_DEFAULT="1.0.0"

# The pinned forge3 release bundled into Contents/Helpers. Updating this is a
# deliberate act: the tag and both checksums move together, and
# scripts/fetch-forge3.sh verifies the downloaded archives against them.
FORGE3_VERSION="v0.1.190"
FORGE3_REPOSITORY="tailcallhq/forgecode-sdk"
FORGE3_AARCH64_ARCHIVE="forge3-aarch64-apple-darwin.tar.xz"
FORGE3_AARCH64_SHA256="d01cca863fd7af861abf20eec621334b61057ea8bb7f426563b82ab12d6d5950"
FORGE3_X86_64_ARCHIVE="forge3-x86_64-apple-darwin.tar.xz"
FORGE3_X86_64_SHA256="07c447bf83f8171d9290e2e77e76498d2db01ce8630dacc3936da50d574ee6d6"
