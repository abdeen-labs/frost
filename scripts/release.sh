#!/usr/bin/env bash
#
# release.sh — cut a Frost release end-to-end from an already-notarized app.
#
# Run this LOCALLY after you have archived, Developer ID-signed, NOTARIZED, and
# STAPLED frost.app in Xcode and exported it. It does the repeatable parts:
#
#   1. Build the DMG and EdDSA-sign the Sparkle appcast (private key read from
#      your login Keychain — it never leaves this machine).
#   2. Create the GitHub Release for tag v<version> and upload the DMG.
#   3. Publish the signed appcast by uploading it to the update bucket, then
#      read it back through the public feed URL.
#
# Hosting model: the DMG lives on GitHub Releases (the appcast's <enclosure url>
# points back at that asset). The appcast is the object frost/appcast.xml in a
# private S3-compatible bucket. The SUFeedURL,
# https://updates.abdeen.industries/frost/appcast.xml, is a small service that
# answers with a short-lived redirect to that object, so publishing is a single
# PUT and nothing redeploys per release. Builds 2.2.1–2.2.2 poll
# abdeen.dev/frost/appcast.xml, which permanently redirects here; builds up to
# 2.2 polled the retired updates.abdeen.dev alias and no longer see updates
# (see RELEASING.md). The download PAGE lives in the
# abdeen.dev site, reads GitHub at load time, and is not touched here.
#
# Usage:
#   scripts/release.sh /path/to/frost.app                 # build, release, upload
#   UPLOAD=0 scripts/release.sh /path/to/frost.app        # build + release, leave appcast in dist/
#
# Environment (values from the bucket's Credentials tab; the first three are
# required unless UPLOAD=0):
#   UPDATES_BUCKET              Bucket name.
#   UPDATES_ACCESS_KEY_ID       Access key id with write access to the bucket.
#   UPDATES_SECRET_ACCESS_KEY   Its secret access key.
#   UPDATES_ENDPOINT            Endpoint (default: https://t3.storageapi.dev).
#   UPDATES_REGION              SigV4 signing region (default: auto).
#
# Prereqs: gh (authenticated), the Sparkle tools publish.sh discovers, and
# curl 7.76 or later for --aws-sigv4 and --fail-with-body (macOS ships one).

set -euo pipefail

# publish.sh honors SKIP_NOTARIZATION_CHECK=1 for local dry runs. A real
# release must never inherit it: an un-notarized DMG would be EdDSA-signed,
# published, and then blocked by Gatekeeper on every user's machine.
if [ "${SKIP_NOTARIZATION_CHECK:-0}" = "1" ]; then
  echo "error: SKIP_NOTARIZATION_CHECK is set. Refusing to cut a release" >&2
  echo "without the notarization/stapling gate. Unset it and retry;" >&2
  echo "the flag is only for direct scripts/publish.sh dry runs." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="${REPO_SLUG:-abdeen-labs/frost}"
APP_PATH="${APP_PATH:-${1:-$REPO_ROOT/build/export/frost.app}}"

if [ ! -d "$APP_PATH" ]; then
  echo "error: notarized frost.app not found at: $APP_PATH" >&2
  echo "Export a Developer ID-signed, notarized, stapled app from Xcode first," >&2
  echo "then: scripts/release.sh /path/to/frost.app" >&2
  exit 1
fi

# --- Version + tag ----------------------------------------------------------
PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
TAG="v$VERSION"
DMG="$REPO_ROOT/dist/Frost-$VERSION.dmg"
APPCAST="$REPO_ROOT/dist/appcast.xml"

echo "Releasing Frost $VERSION (tag $TAG) to $REPO_SLUG"

# Refuse to overwrite an existing release — bump the version instead.
if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists. Bump MARKETING_VERSION /" >&2
  echo "CURRENT_PROJECT_VERSION, re-export, and retry." >&2
  exit 1
fi

# --- Provenance: the tag must name the source that is inside the DMG --------
# `gh release create` creates the tag server-side from the default branch's
# current HEAD. Nothing else here ties that commit to the .app being shipped,
# so a release cut after archiving-then-committing would tag source that is not
# the source in the DMG — and the CHANGELOG compare-links would describe a diff
# the release does not contain. Assert the three things that make the tag
# meaningful, then pin it explicitly with --target.
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "error: the working tree has uncommitted changes. Commit or stash them" >&2
  echo "so the tag names exactly the source that was archived." >&2
  exit 1
fi

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if ! git -C "$REPO_ROOT" fetch --quiet origin 2>/dev/null; then
  echo "warning: could not fetch origin; the pushed-state check may be stale." >&2
fi
if [ "$HEAD_SHA" != "$(git -C "$REPO_ROOT" rev-parse origin/main)" ]; then
  echo "error: HEAD is not origin/main. Push (or check out) the reviewed commit" >&2
  echo "before cutting the release." >&2
  exit 1
fi

# Scope to the shipping app target's build configurations: FrostTests carries
# its own MARKETING_VERSION (1.0), so a project-wide grep reads the wrong one.
# Match MARKETING_VERSION only inside a buildSettings block whose
# PRODUCT_BUNDLE_IDENTIFIER is the release bundle id.
PROJECT_VERSION="$(awk '
  /buildSettings = \{/ { in_block = 1; version = ""; is_app = 0; next }
  in_block && /MARKETING_VERSION = / {
    version = $0
    sub(/.*MARKETING_VERSION = /, "", version); sub(/;.*/, "", version)
  }
  in_block && /PRODUCT_BUNDLE_IDENTIFIER = dev\.abdeen\.frost;/ { is_app = 1 }
  in_block && /^[[:space:]]*\};/ {
    if (is_app && version != "") print version
    in_block = 0
  }
' "$REPO_ROOT/Frost.xcodeproj/project.pbxproj" | sort -u)"
if [ "$(printf '%s\n' "$PROJECT_VERSION" | wc -l | tr -d ' ')" != "1" ] \
   || [ -z "$PROJECT_VERSION" ]; then
  echo "error: could not read a single MARKETING_VERSION for the release target" >&2
  echo "from project.pbxproj (got: ${PROJECT_VERSION:-none})." >&2
  exit 1
fi
if [ "$PROJECT_VERSION" != "$VERSION" ]; then
  echo "error: the exported app is $VERSION but project.pbxproj says" >&2
  echo "MARKETING_VERSION = $PROJECT_VERSION. Re-export from the committed source." >&2
  exit 1
fi

# --- Upload credentials -----------------------------------------------------
# Checked before anything is built or released: a credential found missing only
# at step 3 would leave a published GitHub release whose appcast never went out,
# so no installed copy would ever be offered it.
if [ "${UPLOAD:-1}" = "1" ]; then
  MISSING=""
  for var in UPDATES_BUCKET UPDATES_ACCESS_KEY_ID UPDATES_SECRET_ACCESS_KEY; do
    if [ -z "${!var:-}" ]; then
      MISSING="$MISSING $var"
    fi
  done
  if [ -n "$MISSING" ]; then
    echo "error: not set:$MISSING" >&2
    echo "Export the bucket credentials (see RELEASING.md), or run with UPLOAD=0" >&2
    echo "to build and release without uploading the appcast." >&2
    exit 1
  fi
fi

# --- 1. DMG + signed appcast pointing at the GitHub asset -------------------
export DOWNLOAD_URL_PREFIX="https://github.com/$REPO_SLUG/releases/download/$TAG/"
"$REPO_ROOT/scripts/publish.sh" "$APP_PATH"

# --- 2. GitHub Release (uploads the DMG) ------------------------------------
# Prefer the curated CHANGELOG.md section (the same notes Sparkle embeds in the
# appcast). Fall back to GitHub's auto-generated notes if this version has no
# changelog entry yet, so a forgotten changelog never blocks a release.
echo "Creating GitHub release ${TAG}..."
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
if "$REPO_ROOT/scripts/changelog.sh" "$VERSION" >"$NOTES_FILE" 2>/dev/null; then
  echo "Using CHANGELOG.md notes for $VERSION."
  gh release create "$TAG" "$DMG" \
    --repo "$REPO_SLUG" \
    --target "$HEAD_SHA" \
    --title "Frost $VERSION" \
    --notes-file "$NOTES_FILE"
else
  echo "warning: no CHANGELOG.md section for $VERSION; using --generate-notes." >&2
  gh release create "$TAG" "$DMG" \
    --repo "$REPO_SLUG" \
    --target "$HEAD_SHA" \
    --title "Frost $VERSION" \
    --generate-notes
fi

# --- 3. Publish the appcast to the update host ------------------------------
# The appcast is one object in a private S3-compatible bucket. The update host
# answers GET /frost/appcast.xml with a short-lived redirect to the object of
# the same key, so publishing is a single PUT: nothing to commit, nothing to
# redeploy. The bucket is addressed virtual-hosted style, the bucket name as a
# subdomain of the endpoint.
APPCAST_KEY="frost/appcast.xml"
FEED_URL="https://updates.abdeen.industries/$APPCAST_KEY"
if [ "${UPLOAD:-1}" = "1" ]; then
  ENDPOINT_HOST="${UPDATES_ENDPOINT:-https://t3.storageapi.dev}"
  ENDPOINT_HOST="${ENDPOINT_HOST#https://}"
  ENDPOINT_HOST="${ENDPOINT_HOST%%/*}"
  OBJECT_URL="https://$UPDATES_BUCKET.$ENDPOINT_HOST/$APPCAST_KEY"
  echo "Uploading the appcast to $OBJECT_URL..."
  # curl signs the PUT itself (SigV4). The key pair goes in as a config on
  # stdin rather than --user, so the secret never shows up in `ps`. no-cache
  # makes clients revalidate rather than reuse a stale appcast.
  if ! printf 'user = "%s:%s"\n' "$UPDATES_ACCESS_KEY_ID" "$UPDATES_SECRET_ACCESS_KEY" |
    curl --config - --fail-with-body --silent --show-error \
      --aws-sigv4 "aws:amz:${UPDATES_REGION:-auto}:s3" \
      --header "Content-Type: application/xml" \
      --header "Cache-Control: no-cache" \
      --upload-file "$APPCAST" \
      "$OBJECT_URL"; then
    echo "error: uploading the appcast failed (curl's error is above)." >&2
    echo "The GitHub release exists; re-run only the upload (see RELEASING.md)." >&2
    exit 1
  fi
  # Read it back through the public feed URL (redirect + bucket), so the script
  # only reports success once installed copies can see this appcast.
  if ! curl --fail --silent --show-error --location "$FEED_URL" | cmp -s - "$APPCAST"; then
    echo "error: $FEED_URL does not serve the appcast just uploaded." >&2
    echo "The GitHub release exists; re-run only the upload (see RELEASING.md)." >&2
    exit 1
  fi
  echo "Published $FEED_URL"
else
  echo "UPLOAD=0 — appcast left at $APPCAST, not uploaded."
fi

echo
echo "Done."
echo "  Release: https://github.com/$REPO_SLUG/releases/tag/$TAG"
echo "  Appcast: $FEED_URL"
echo "  Verify:  open the release page, confirm the .dmg downloads, then check an"
echo "           older build sees the update via Check for Updates..."
