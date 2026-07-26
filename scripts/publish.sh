#!/usr/bin/env bash
#
# publish.sh — package a Frost release and (re)generate the Sparkle appcast.
#
# This does NOT build or sign the app. In Xcode: archive, sign with Developer ID
# + Hardened Runtime, notarize, and staple the .app FIRST, then point this
# script at the exported frost.app.
#
# Pipeline:
#   1. Read the version from the .app's Info.plist.
#   2. Stage the .app (+ an /Applications symlink) and build a compressed DMG.
#   3. Run Sparkle's generate_appcast over a clean one-release staging dir — it
#      signs the DMG with the EdDSA private key (read from the login Keychain)
#      and writes appcast.xml.
#
# Outputs land in dist/. Releases are normally cut via scripts/release.sh,
# which uploads the DMG to GitHub Releases and publishes the appcast to the
# update host (see RELEASING.md); standalone runs of this script are for
# local dry runs.
#
# Usage:
#   scripts/publish.sh [path/to/frost.app]
#
# Environment overrides:
#   APP_PATH      Path to the exported frost.app (alternative to the argument).
#   SPARKLE_BIN   Dir containing generate_appcast (auto-discovered otherwise).

set -euo pipefail

# --- Config -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
REPO_SLUG="${REPO_SLUG:-Cuzeth/frost}"
APP_PATH="${APP_PATH:-${1:-$REPO_ROOT/build/export/frost.app}}"

# --- Locate the exported .app ----------------------------------------------
if [ ! -d "$APP_PATH" ]; then
  echo "error: frost.app not found at: $APP_PATH" >&2
  echo "Export it from Xcode first, or pass its path:" >&2
  echo "  scripts/publish.sh /path/to/frost.app" >&2
  exit 1
fi

# --- Verify the app is notarized + stapled ----------------------------------
# The contract is an already-signed, notarized, stapled app. A mis-exported
# build would otherwise ship and hit Gatekeeper on every user's machine.
# SKIP_NOTARIZATION_CHECK=1 is for local dry runs only.
if [ "${SKIP_NOTARIZATION_CHECK:-0}" != "1" ]; then
  echo "Validating notarization/stapling of $APP_PATH..."
  if ! xcrun stapler validate "$APP_PATH"; then
    echo "error: $APP_PATH has no valid notarization staple." >&2
    echo "Notarize + staple in Xcode first (Distribute -> Developer ID)." >&2
    echo "Local dry run only: SKIP_NOTARIZATION_CHECK=1 scripts/publish.sh ..." >&2
    exit 1
  fi
  if ! spctl --assess --type exec -v "$APP_PATH"; then
    echo "error: Gatekeeper assessment failed for $APP_PATH." >&2
    exit 1
  fi
fi

# --- Locate Sparkle's generate_appcast -------------------------------------
# The path under DerivedData contains a per-project hash, so discover it rather
# than hardcoding. Search is scoped to this user's DerivedData only.
find_sparkle_bin() {
  if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "$SPARKLE_BIN"
    return 0
  fi
  local derived="$HOME/Library/Developer/Xcode/DerivedData"
  local hit
  # Multiple frost-* DerivedData dirs can hold different Sparkle versions;
  # prefer the most recently built one instead of whichever find lists first.
  hit="$(/usr/bin/find "$derived" -type f \
        -path "$derived/frost-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" 2>/dev/null \
        -print0 | xargs -0 ls -t 2>/dev/null | head -n 1)"
  if [ -n "$hit" ]; then
    dirname "$hit"
    return 0
  fi
  return 1
}

SPARKLE_BIN="$(find_sparkle_bin || true)"
if [ -z "${SPARKLE_BIN:-}" ] || [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "error: could not find Sparkle's generate_appcast." >&2
  echo "Set SPARKLE_BIN to the dir containing it, e.g.:" >&2
  echo "  export SPARKLE_BIN=~/Library/Developer/Xcode/DerivedData/frost-*/SourcePackages/artifacts/sparkle/Sparkle/bin" >&2
  exit 1
fi
echo "Using Sparkle tools: $SPARKLE_BIN"

# --- Read version from the app ---------------------------------------------
PLIST="$APP_PATH/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "Packaging Frost $SHORT_VERSION (build $BUILD_VERSION)"

# Where the appcast's <enclosure url> should point. release.sh exports this to
# aim at the GitHub Releases asset for the tag it is about to create; the
# default below resolves to the same place, because that is where DMGs actually
# live (RELEASING.md: only the appcast is served from updates.abdeen.dev). A
# default pointing at the update host would mint items whose enclosure 404s.
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$REPO_SLUG/releases/download/v$SHORT_VERSION/}"

# --- Verify the Keychain signing key matches the app's public key -----------
# generate_appcast signs with whatever EdDSA key the login Keychain holds. If
# that key was ever regenerated, it would sign happily — and every existing
# install would silently fail to verify updates against the SUPublicEDKey it
# shipped with. Fail before signing anything.
if [ -x "$SPARKLE_BIN/generate_keys" ]; then
  KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
  APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
  if [ "$KEYCHAIN_PUBLIC_KEY" != "$APP_PUBLIC_KEY" ]; then
    echo "error: the Keychain's Sparkle public key does not match the app's" >&2
    echo "SUPublicEDKey:" >&2
    echo "  Keychain: $KEYCHAIN_PUBLIC_KEY" >&2
    echo "  App:      $APP_PUBLIC_KEY" >&2
    echo "Signing with this key would break updates for every existing install." >&2
    echo "Restore the original private key before publishing (see RELEASING.md)." >&2
    exit 1
  fi
  echo "Sparkle signing key matches the app's SUPublicEDKey."
else
  echo "warning: generate_keys not found next to generate_appcast;" >&2
  echo "skipping the signing-key match check." >&2
fi

# --- Build the DMG ----------------------------------------------------------
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/Frost-$SHORT_VERSION.dmg"
STAGING="$(mktemp -d)"
APPCAST_INPUT="$(mktemp -d)"
trap 'rm -rf "$STAGING" "$APPCAST_INPUT"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Frost $SHORT_VERSION" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"
echo "Built DMG: $DMG_PATH"

# --- Generate / update the appcast -----------------------------------------
# generate_appcast signs every archive it sees, so feed it a clean staging dir
# containing only this release's DMG. That keeps stray/aborted files in dist/
# out of the public appcast.
cp -p "$DMG_PATH" "$APPCAST_INPUT/"

# Drop any existing item for THIS marketing version before regenerating.
#
# generate_appcast deliberately merges into the -o file and keeps items whose
# archives are absent — that is what preserves the release history other
# versions need, so we must not regenerate from scratch. But it keys items on
# CFBundleVersion, while the DMG filename (and therefore the enclosure URL)
# is keyed on CFBundleShortVersionString. Re-exporting the same marketing
# version with a bumped build — a re-notarization, a fixed export — therefore
# appends a SECOND item pointing at the SAME enclosure URL with a different
# length and edSignature. Only one can match the uploaded asset; the other can
# never verify, and it still consumes one of the --maximum-versions slots,
# silently pushing a genuinely older release out of the feed.
#
# Pruning by shortVersionString makes re-publishing a version idempotent:
# generate_appcast re-adds it below from the DMG we just signed, with the
# correct length and signature. History for every OTHER version is untouched.
APPCAST_PATH="$DIST_DIR/appcast.xml"
if [ -f "$APPCAST_PATH" ]; then
  PRUNED="$(mktemp)"
  if awk -v ver="$SHORT_VERSION" '
      /<item>/ { buf = $0 "\n"; in_item = 1; drop = 0; next }
      in_item {
        buf = buf $0 "\n"
        if (index($0, "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>")) drop = 1
        if (index($0, "</item>")) {
          if (!drop) printf "%s", buf; else dropped++
          in_item = 0; buf = ""
        }
        next
      }
      { print }
      END { if (dropped) print "pruned " dropped " stale item(s)" > "/dev/stderr" }
    ' "$APPCAST_PATH" >"$PRUNED"; then
    if ! cmp -s "$APPCAST_PATH" "$PRUNED"; then
      echo "Replacing the existing appcast item(s) for $SHORT_VERSION."
      # generate_appcast reads and rewrites the -o path, so prune in place there.
      cp "$PRUNED" "$APPCAST_PATH"
    fi
  else
    echo "warning: could not prune $APPCAST_PATH; leaving it as-is." >&2
  fi
  rm -f "$PRUNED"
fi

# Attach this version's CHANGELOG.md section as release notes. generate_appcast
# picks up a notes file whose name matches the archive (minus extension), so
# name it to match the DMG; --embed-release-notes renders the Markdown inline
# into the item's <description>. This is the same text scripts/release.sh puts
# on the GitHub release — one source, so the update dialog and GitHub agree.
NOTES_MD="$APPCAST_INPUT/Frost-$SHORT_VERSION.md"
if "$REPO_ROOT/scripts/changelog.sh" "$SHORT_VERSION" >"$NOTES_MD" 2>/dev/null; then
  echo "Attached release notes for $SHORT_VERSION from CHANGELOG.md."
else
  rm -f "$NOTES_MD"
  echo "warning: no CHANGELOG.md section for $SHORT_VERSION;" >&2
  echo "the appcast item will ship without release notes." >&2
fi

"$SPARKLE_BIN/generate_appcast" \
  --embed-release-notes \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  -o "$DIST_DIR/appcast.xml" \
  "$APPCAST_INPUT"

echo
echo "Done."
echo "  DMG:     $DMG_PATH"
echo "  Appcast: $DIST_DIR/appcast.xml"
echo
echo "Next: releases are normally cut with scripts/release.sh, which uploads the"
echo "DMG to GitHub Releases and publishes the appcast (see RELEASING.md)."
echo "(If generate_appcast reported a missing key, run Sparkle's generate_keys"
echo " once — it stores the private key in your login Keychain.)"
