#!/bin/sh

# macOS-specific pins. Shared values (APP_VERSION_DEFAULT, FORGE3_VERSION,
# FORGE3_REPOSITORY) come from the repository-root versions.sh so that one tag
# drives every platform; only the archive names and checksums below are
# genuinely macOS-specific.
#
# REPO_ROOT is set by common.sh before this file is sourced.
. "$REPO_ROOT/versions.sh"

# Verified by scripts/fetch-forge3.sh against the downloaded archives.
FORGE3_AARCH64_ARCHIVE="forge3-aarch64-apple-darwin.tar.xz"
FORGE3_AARCH64_SHA256="d01cca863fd7af861abf20eec621334b61057ea8bb7f426563b82ab12d6d5950"
FORGE3_X86_64_ARCHIVE="forge3-x86_64-apple-darwin.tar.xz"
FORGE3_X86_64_SHA256="07c447bf83f8171d9290e2e77e76498d2db01ce8630dacc3936da50d574ee6d6"
