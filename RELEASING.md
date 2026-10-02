# Releasing Frost

Two independent trust layers ship a release. Don't conflate them:

- **Apple notarization** — stapled *into* the `.app`/`.dmg`, satisfies Gatekeeper.
  Done locally in Xcode. Lives in the binary, not on any server.
- **Sparkle appcast** — `appcast.xml`, EdDSA-signed with your private key. Hosted
  at the URL hardcoded in `Info.plist` (`SUFeedURL`). This is what lets installed
  copies verify and fetch updates.

## Where things live

| Artifact | Host |
|---|---|
| `Frost-x.y.z.dmg` (notarized) | GitHub Releases (`github.com/abdeen-labs/frost`) |
| `appcast.xml` (EdDSA-signed) | `public/frost/appcast.xml` in the **abdeen.dev repo**, served at `abdeen.dev/frost/appcast.xml` |
| Download page | `abdeen.dev/frost` — also in the abdeen.dev repo (`src/app/frost`), reads the latest release from GitHub at load time |

The appcast is just a static file in the abdeen.dev Vercel project and ships when
the site deploys. The appcast's `<enclosure url>` points back at the GitHub DMG —
the DMG is never uploaded to your domain. The download page doesn't change per
release.

Builds up to 2.2 shipped with `SUFeedURL` pointing at
`updates.abdeen.dev/frost/appcast.xml`; 2.2.1 moved the feed to the apex domain.
That alias is retired, so anything still on 2.2 or older no longer sees updates
and has to be reinstalled by hand from the download page.

## One-time setup

1. **Developer ID Application** certificate in your login Keychain.
2. **Notarization profile**:
   `xcrun notarytool store-credentials "frost-notary" --apple-id <id> --team-id <team> --password <app-specific-pw>`
3. **Sparkle EdDSA key** in your login Keychain. Confirm it matches the app:
   `generate_keys -p` must print `V8xkC2BQlZG91vsCTw7ACPjL1dbRlBKo+ftb9ymNbdM=`.
   If it prints anything else, **stop** — signing with the wrong key breaks
   updates for every installed copy. (`publish.sh` also enforces this match
   automatically before signing, along with `stapler validate` and a
   Gatekeeper `spctl` assessment of the exported app.)
4. **`gh auth login`**, and a checkout of **`github.com/abdeen-labs/abdeen.dev`**
   with push access (the release script commits the appcast there; Vercel
   deploys on push).
5. **Appcast route**: `public/frost/appcast.xml` in the abdeen.dev repo is served
   at `abdeen.dev/frost/appcast.xml` (`SUFeedURL`) as a plain static file. Vercel's
   default `application/xml` content type is fine for Sparkle. There is nothing to
   configure beyond the site itself.
6. **Download page**: the `abdeen.dev/frost` route (`src/app/frost`). It reads the
   latest release from GitHub, so it doesn't need redeploying per version — it
   ships with the abdeen.dev site.

## Cutting a release

1. **Update the changelog.** In `CHANGELOG.md`, leave the `## [Unreleased]`
   heading and its comment in place and insert a new `## [x.y.z] - YYYY-MM-DD`
   heading directly below them (e.g. `## [1.0.1] - 2026-07-14`), so this
   release's accumulated entries fall under it. Repoint the `[Unreleased]` link
   at the new tag and add a matching compare-link at the bottom of the file.
   That version section becomes **both** the GitHub release notes and the
   Sparkle update description, so write it for a user. Commit it.
2. **Bump the version** in the Xcode target (both must change; `CURRENT_PROJECT_VERSION`
   must strictly increase — Sparkle compares it):
   - `MARKETING_VERSION` → e.g. `1.0.1` (the display + tag version)
   - `CURRENT_PROJECT_VERSION` → e.g. `2`
3. **Push** `main` so the tag will reference a real remote commit.
4. **Archive → Distribute → Developer ID** in Xcode: sign, notarize, staple,
   export `frost.app`.
5. **Run the release script** (builds the DMG, signs the appcast, creates the
   GitHub release, and commits + pushes the appcast to the abdeen.dev repo so
   Vercel deploys it):
   ```sh
   ABDEEN_DEV_REPO=~/GitHub/abdeen-labs/abdeen.dev scripts/release.sh /path/to/frost.app
   ```
   `ABDEEN_DEV_REPO` defaults to `../abdeen.dev` (a sibling checkout), so you can
   omit it only if the repos sit side by side. Add `DEPLOY=0` to build + create
   the release but only write the appcast into the repo (no commit/push).

   The script is not resumable: if it fails after `gh release create`, do the
   last step by hand — copy `dist/appcast.xml` to `public/frost/appcast.xml` in
   the site checkout, commit only that file, and push `main`.
6. **Verify**: open the GitHub release, confirm the `.dmg` downloads and opens
   without a Gatekeeper warning, then confirm an older build sees the update via
   *Check for Updates…* — and that the update dialog now shows the release notes
   from the changelog.

## What `release.sh` does

Tag is `v$MARKETING_VERSION`. It refuses to overwrite an existing release. It sets
`DOWNLOAD_URL_PREFIX` to the GitHub asset URL and calls `publish.sh` (DMG +
`generate_appcast`), then `gh release create … <dmg>`, then copies the appcast to
`<abdeen.dev>/public/frost/appcast.xml` and commits + pushes **only that file**
(a pathspec commit, so unrelated working changes are never swept in). Apple and
Sparkle private keys stay in your Keychain the whole time.

Release notes for **both** the GitHub release and the appcast's `<description>`
come from the matching `CHANGELOG.md` section, extracted by `scripts/changelog.sh`:
`release.sh` passes it to `gh release create --notes-file`, and `publish.sh`
writes it next to the DMG as `Frost-<version>.md` so `generate_appcast
--embed-release-notes` renders it into the appcast. If the version has no
changelog section yet, the GitHub release falls back to `--generate-notes` and
the appcast item ships without notes (both scripts print a warning) — so a
forgotten changelog degrades gracefully instead of blocking the release.
