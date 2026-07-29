#!/bin/sh

# macOS release scripts source the shared ForgeCode application version from
# the repository root. The app/DMG contain no service runtime, so there are no
# macOS runtime archive names, checksums, repositories, or version pins here.
#
# REPO_ROOT is set by common.sh before this file is sourced.
. "$REPO_ROOT/versions.sh"
