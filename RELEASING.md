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
| `appcast.xml` (EdDSA-signed) | Object `frost/appcast.xml` in a private S3-compatible bucket, served at `updates.abdeen.industries/frost/appcast.xml` |
| Download page | `abdeen.dev/frost` — in the abdeen.dev repo (`src/app/frost`), reads the latest release from GitHub at load time |

The update host is a small service that answers every `GET /<app>/<file>` with a
short-lived redirect to the bucket object `<app>/<file>`. Publishing is one
upload of `frost/appcast.xml`; the service never redeploys per release. The
appcast's `<enclosure url>` points back at the GitHub DMG — the DMG is never
uploaded to the bucket. Enclosure URLs must stay absolute: Sparkle resolves a
relative one against the redirected bucket URL, which would break it. The
download page doesn't change per release.

2.2.1 and 2.2.2 shipped with `SUFeedURL` pointing at
`abdeen.dev/frost/appcast.xml`, which permanently redirects to the update host,
so they keep receiving updates. Builds up to 2.2 shipped with `SUFeedURL`
pointing at `updates.abdeen.dev/frost/appcast.xml`. That alias is retired, so
anything still on 2.2 or older no longer sees updates and has to be reinstalled
by hand from the download page.

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
4. **`gh auth login`**, and the bucket credentials in the environment you
   release from. Copy the five values from the bucket's Credentials tab:
   ```sh
   export UPDATES_BUCKET=…             # BUCKET
   export UPDATES_ACCESS_KEY_ID=…      # ACCESS_KEY_ID
   export UPDATES_SECRET_ACCESS_KEY=…  # SECRET_ACCESS_KEY
   export UPDATES_ENDPOINT=…           # ENDPOINT
   export UPDATES_REGION=…             # REGION
   ```
   `release.sh` falls back to `https://t3.storageapi.dev` and `auto` for the last
   two, but the manual upload below uses all five.
   No other checkout is needed; the release script uploads the appcast itself.
5. **Appcast route**: `updates.abdeen.industries/frost/appcast.xml` (`SUFeedURL`)
   redirects to the bucket object `frost/appcast.xml`. The key is the URL path,
   so there is nothing to configure per app. The upload sets
   `Content-Type: application/xml` and `Cache-Control: no-cache`, so clients
   revalidate instead of reusing a stale appcast.
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
   GitHub release, and uploads the appcast to the update host), with the
   `UPDATES_*` variables from setup step 4 exported:
   ```sh
   scripts/release.sh /path/to/frost.app
   ```
   It checks for the bucket credentials before building anything, so a missing
   one never leaves a release half-cut. Add `UPLOAD=0` to build + create the
   release but leave the signed appcast in `dist/appcast.xml` without uploading
   it.

   The script is not resumable: if it fails after `gh release create`, re-run
   only the upload, then confirm the feed serves the new appcast:
   ```sh
   printf 'user = "%s:%s"\n' "$UPDATES_ACCESS_KEY_ID" "$UPDATES_SECRET_ACCESS_KEY" |
     curl --config - --fail-with-body --silent --show-error \
       --aws-sigv4 "aws:amz:$UPDATES_REGION:s3" \
       --header "Content-Type: application/xml" \
       --header "Cache-Control: no-cache" \
       --upload-file dist/appcast.xml \
       "https://$UPDATES_BUCKET.${UPDATES_ENDPOINT#https://}/frost/appcast.xml"
   curl -sSL https://updates.abdeen.industries/frost/appcast.xml
   ```
   The key pair goes to curl on stdin rather than as `--user`, so the secret
   stays out of `ps`.
6. **Verify**: open the GitHub release, confirm the `.dmg` downloads and opens
   without a Gatekeeper warning, then confirm an older build sees the update via
   *Check for Updates…* — and that the update dialog now shows the release notes
   from the changelog.

## What `release.sh` does

Tag is `v$MARKETING_VERSION`. It refuses to overwrite an existing release, and
refuses to start without the bucket credentials unless `UPLOAD=0`. It sets
`DOWNLOAD_URL_PREFIX` to the GitHub asset URL and calls `publish.sh` (DMG +
`generate_appcast`), then `gh release create … <dmg>`, then PUTs the appcast to
the bucket as `frost/appcast.xml` (curl signs the request with SigV4) and reads
it back through `updates.abdeen.industries`, reporting success only once the
public feed serves exactly that file. Apple and Sparkle private keys stay in
your Keychain the whole time.

Release notes for **both** the GitHub release and the appcast's `<description>`
come from the matching `CHANGELOG.md` section, extracted by `scripts/changelog.sh`:
`release.sh` passes it to `gh release create --notes-file`, and `publish.sh`
writes it next to the DMG as `Frost-<version>.md` so `generate_appcast
--embed-release-notes` renders it into the appcast. If the version has no
changelog section yet, the GitHub release falls back to `--generate-notes` and
the appcast item ships without notes (both scripts print a warning) — so a
forgotten changelog degrades gracefully instead of blocking the release.
