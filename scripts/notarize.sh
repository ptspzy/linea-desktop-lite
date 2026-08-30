#!/usr/bin/env bash
set -euo pipefail

DMG="${1:?usage: notarize.sh PATH_TO_DMG}"
NOTARY_PROFILE="${NOTARY_PROFILE:?NOTARY_PROFILE is required}"

test -f "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
