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
#   3. Publish the signed appcast by committing it to the abdeen.dev repo and
#      pushing — Vercel then deploys it.
#
# Hosting model: the DMG lives on GitHub Releases (the appcast's <enclosure url>
# points back at that asset). updates.abdeen.dev is a domain ALIAS of the single
# abdeen.dev Vercel project, so the appcast is just a static file in that repo at
# public/frost/appcast.xml — served at https://updates.abdeen.dev/frost/appcast.xml
# (the SUFeedURL) and at https://abdeen.dev/frost/appcast.xml. The download PAGE
# also lives in the abdeen.dev repo (src/app/frost), reads GitHub at load time,
# and ships with the site — it is not touched here.
#
# Usage:
#   scripts/release.sh /path/to/frost.app                 # build, release, publish
#   DEPLOY=0 scripts/release.sh /path/to/frost.app        # build + release, stage appcast only
#
# Environment:
#   ABDEEN_DEV_REPO   Path to the abdeen.dev working copy (default: sibling of
#                     this repo, ../abdeen.dev).
#
# Prereqs: gh (authenticated), the Sparkle tools publish.sh discovers, and a
# clean abdeen.dev checkout with push access (Vercel deploys on push).

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
REPO_SLUG="${REPO_SLUG:-Cuzeth/frost}"
APP_PATH="${APP_PATH:-${1:-$REPO_ROOT/build/export/frost.app}}"
SITE_REPO="${ABDEEN_DEV_REPO:-$REPO_ROOT/../abdeen.dev}"

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

# Scope to the shipping app target's build configurations: frostTests carries
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
' "$REPO_ROOT/frost.xcodeproj/project.pbxproj" | sort -u)"
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

# --- 3. Publish the appcast via the abdeen.dev site -------------------------
# updates.abdeen.dev is a domain alias of the abdeen.dev Vercel project, so the
# appcast is a static file in that repo. Copy it in, then commit + push only that
# file (a pathspec commit, so unrelated working changes are never swept in).
if [ ! -d "$SITE_REPO/.git" ]; then
  echo "error: abdeen.dev repo not found at: $SITE_REPO" >&2
  echo "Set ABDEEN_DEV_REPO to its path, or copy dist/appcast.xml to" >&2
  echo "<abdeen.dev>/public/frost/appcast.xml and deploy the site yourself." >&2
  exit 1
fi

DEST_REL="public/frost/appcast.xml"
DEST="$SITE_REPO/$DEST_REL"
mkdir -p "$(dirname "$DEST")"
cp "$APPCAST" "$DEST"
echo "Updated $DEST"

if [ "${DEPLOY:-1}" = "1" ]; then
  if [ -z "$(git -C "$SITE_REPO" status --porcelain -- "$DEST_REL")" ]; then
    echo "Appcast unchanged in the site repo — nothing to deploy."
  else
    # The commit is pathspec-scoped, but a bare `git push` is not: any other
    # unpushed local commits in the site checkout would deploy alongside the
    # appcast (Vercel deploys on push). Assert we are on the deploy branch with
    # nothing else pending, then push that branch explicitly.
    SITE_BRANCH="$(git -C "$SITE_REPO" rev-parse --abbrev-ref HEAD)"
    if [ "$SITE_BRANCH" != "main" ]; then
      echo "error: $SITE_REPO is on '$SITE_BRANCH', not main. Switch to the" >&2
      echo "deploy branch before publishing the appcast." >&2
      exit 1
    fi
    if [ -n "$(git -C "$SITE_REPO" log --oneline '@{u}..' 2>/dev/null)" ]; then
      echo "error: $SITE_REPO has unpushed commits. Pushing now would deploy" >&2
      echo "them with the appcast. Push or drop them first:" >&2
      git -C "$SITE_REPO" log --oneline '@{u}..' >&2
      exit 1
    fi
    git -C "$SITE_REPO" add -- "$DEST_REL"
    git -C "$SITE_REPO" commit -m "frost: appcast for $VERSION" -- "$DEST_REL"
    git -C "$SITE_REPO" push origin HEAD:main
    echo "Pushed appcast to abdeen.dev — Vercel will deploy it."
  fi
else
  echo "DEPLOY=0 — appcast written to $DEST but not committed/pushed."
fi

echo
echo "Done."
echo "  Release: https://github.com/$REPO_SLUG/releases/tag/$TAG"
echo "  Appcast: https://updates.abdeen.dev/frost/appcast.xml"
echo "  Verify:  open the release page, confirm the .dmg downloads, then check an"
echo "           older build sees the update via Check for Updates..."
