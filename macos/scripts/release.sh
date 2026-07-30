#!/bin/sh
set -eu

# Build the signed release and submit the DMG for notarization WITHOUT waiting.
#
# Only the DMG is submitted: notarizing the DMG notarizes the app inside it
# recursively, so the app is signed with a hardened runtime but never submitted
# on its own. Submission is non-blocking (scripts/submit-dmg.sh runs
# `notarytool submit --no-wait`); the ticket is stapled later by
# scripts/staple-dmg.sh, driven by the scheduled finalize workflow, so this
# build never blocks on Apple's notary queue.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_FLAVOR=signed
export BUILD_FLAVOR
. "$SCRIPT_DIR/common.sh"
[ -n "${SIGNING_IDENTITY:-}" ] || fail "SIGNING_IDENTITY is required"
[ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is required"

packaging_preflight
run_tests
sh "$SCRIPT_DIR/assemble-app.sh"
sh "$SCRIPT_DIR/sign-app.sh"
VERIFY_SIGNATURES=1 sh "$SCRIPT_DIR/verify-release.sh"
sh "$SCRIPT_DIR/create-dmg.sh"
sh "$SCRIPT_DIR/sign-dmg.sh"
VERIFY_SIGNATURES=1 sh "$SCRIPT_DIR/verify-release.sh"

# SKIP_NOTARY_SUBMIT lets the PR `test-release` dry run exercise the whole
# build + sign path without actually enqueuing an Apple submission that nobody
# would ever poll, staple, or close out. Real releases leave it unset.
if [ "${SKIP_NOTARY_SUBMIT:-0}" = "1" ]; then
  printf 'Release built and signed; notary submission skipped (SKIP_NOTARY_SUBMIT=1).\n'
  printf 'DMG: %s\nManifest: %s\nChecksums: %s\n' "$DMG_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH"
else
  sh "$SCRIPT_DIR/submit-dmg.sh"
  printf 'Release built and submitted for notarization.\n'
  printf 'DMG: %s\nSubmission id: %s\nManifest: %s\nChecksums: %s\nNotarization logs: %s\n' \
    "$DMG_PATH" "$SUBMISSION_ID_PATH" "$MANIFEST_PATH" "$CHECKSUMS_PATH" "$NOTARIZATION_LOG_DIR"
fi
