#!/usr/bin/env bash
#
# test.sh — build Frost and run the FrostTests unit suite, exactly as CI does.
#
# This is the repo's one-command verification. Code signing is disabled: the
# suite is logic tests only and needs no signed, distributable artifact.
#
# Usage:
#   scripts/test.sh
#
# Environment overrides (used by CI; optional locally):
#   DERIVED_DATA_PATH    Custom -derivedDataPath (default: Xcode's default).
#   RESULT_BUNDLE_PATH   Write an .xcresult bundle here (default: none).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXTRA_ARGS=()
if [ -n "${DERIVED_DATA_PATH:-}" ]; then
  EXTRA_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi
if [ -n "${RESULT_BUNDLE_PATH:-}" ]; then
  EXTRA_ARGS+=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi

xcodebuild test \
  -project "$REPO_ROOT/Frost.xcodeproj" \
  -scheme frost \
  -destination 'platform=macOS' \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM=""
