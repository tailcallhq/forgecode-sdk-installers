#!/bin/sh
set -eu

# Submit the signed DMG to Apple's notary service WITHOUT waiting. This is the
# only notarization submission in the release pipeline: submitting the DMG
# notarizes the app bundle inside it recursively, so the app is signed (with a
# hardened runtime) but never submitted on its own. The submission UUID is
# written to disk so a later, decoupled step (scripts/staple-dmg.sh, driven by
# the scheduled finalize workflow) can poll for the result and staple once
# Apple accepts it. Nothing here blocks on notarization.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

require_command xcrun

profile=${NOTARY_PROFILE:-}
[ -n "$profile" ] || fail "NOTARY_PROFILE is required (created with notarytool store-credentials)"
[ -f "$DMG_PATH" ] || fail "DMG is missing; run scripts/create-dmg.sh and scripts/sign-dmg.sh first"
[ "$(signature_kind "$DMG_PATH")" = "developer-id" ] || fail "DMG must be Developer ID signed before notarization"

submission_json="$NOTARIZATION_LOG_DIR/dmg-submit.json"
safe_remove "$submission_json"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$profile" --no-wait --output-format json > "$submission_json"
submission_id=$(plutil -extract id raw -o - "$submission_json" 2>/dev/null || true)
[ -n "$submission_id" ] || fail "notarytool did not return a submission id (see $submission_json)"

# Persist the UUID next to the DMG so it travels with the release artifact and
# the finalize workflow can pick it up without re-submitting.
printf '%s\n' "$submission_id" > "$SUBMISSION_ID_PATH"
chmod 0644 "$SUBMISSION_ID_PATH"
printf 'Submitted %s for notarization: %s\n' "$DMG_PATH" "$submission_id"
printf 'Submission id recorded at %s\n' "$SUBMISSION_ID_PATH"
