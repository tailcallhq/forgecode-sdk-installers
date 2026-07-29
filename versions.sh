#!/bin/sh

# Versions shared by every platform package (macOS, Windows, Linux).
#
# One git tag drives one application release across all platforms, so the
# shared application version lives at the repository root rather than in any
# single platform directory. Platform scripts source this file and may define
# only settings that genuinely differ for their package format.

# ForgeCode's own version. Desktop packages contain the application only; the
# service runtime is installed separately when the service is first needed and
# is not version-pinned by release packaging. App updaters compare this value,
# so it must increase on every published application build. The release
# workflow overrides it from the git tag; this is the local/dev default.
#
# Pre-1.0: this is not a stable release.
APP_VERSION_DEFAULT="0.1.0"
