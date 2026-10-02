# AGENTS.md — Frost

Guardrails for AI agents (and humans) working in this repository. **Read this before making changes.**

## What Frost is

Frost is a **macOS menu-bar input locker**. It blocks keyboard, mouse, and trackpad input while keeping the display fully visible, and unlocks via Touch ID on Macs with Touch ID. It exists to lock your desk while an unattended-but-visible task runs — an AI agent, a long build, a render.

## What Frost is NOT — do not change these framings

- **Not a screen locker.** The screen stays on and visible; content is never hidden or blanked.
- **Not a replacement for the macOS login window (`loginwindow`).** It does not log the user out, does not gate at the login screen, and is not a security boundary against a determined local attacker.
- **Not a kiosk/MDM tool, parental control, or anti-theft device.**

Describe it as an *input suppressor + overlay manager + local auth gate*. Never document or market it as a security / lock-screen product.

## THE INVARIANT — Frost never unlocks without authentication

**Under no circumstances may Frost release a lock it is holding without a
successful `LAContext` evaluation.** Not on repeated Touch ID failures, not on
biometry lockout, not when the sensor disconnects, not when macOS kills the
event tap, not on a timer, not on any heuristic about whether the person at the
keyboard "looks like" the owner. There is no way to distinguish an owner who
locked themselves out from someone else at the machine, and Frost does not
attempt that judgement. If the only way back is a hard power-off, that is the
correct outcome and the user opted into it.

Consequences that follow, and must not be "fixed":

- Biometry lockout after repeated failures is terminal while locked. It clears
  only with a typed password, which the tap makes impossible. Say so plainly;
  do not add an escape.
- If macOS disables the event tap and it cannot be revived, input is flowing
  again — macOS did that, not Frost, and Frost cannot prevent it. Frost still
  does NOT let go: it releases the dead tap (which re-couples the pointer so the
  authenticate button is reachable), keeps the overlay and kiosk options up,
  stops claiming to block input, and requires authentication to dismiss.
- There is no unlock App Intent, no URL scheme, and no "emergency dismiss".

The ONLY paths that end a lock without authentication are process death
(SIGTERM/SIGINT/SIGHUP over SSH, or a power-off) and the DEBUG auto-unlock
timer, which is compiled out of release builds. Both are listed below. Adding a
third is a breaking change to the product, not a bug fix.

Refusing to START a lock is different and always allowed — a preflight failure
(no Touch ID, no Accessibility, secure input held, no display for the overlay)
means the lock never began and no input was ever taken.

## CRITICAL SAFETY — never lock the user out

Input suppression can trap the user with no way to type or click. Every change must preserve **all** of these escape hatches. If a change would weaken any of them, stop and flag it.

1. **Remote kill (SIGTERM).** Frost catches `SIGTERM` and tears the lock down cleanly (restores the cursor, releases the tap) before exiting, independent of app state. Because the event tap blocks *local* input, the realistic way to trigger it is **over SSH from another device** (`pkill -ix frost` / `kill <pid>`; the executable is `Frost`, and `-i` also matches builds up to 2.2.1, whose executable was `frost` — keep the `-i`) with Remote Login enabled in advance, or from a terminal you opened before locking — document it that way. (There is intentionally no in-repo killswitch script; the SIGTERM handler is the contract.)
2. **Debug auto-unlock timer.** In DEBUG builds, a timer tears the lock down after N seconds regardless of auth. It must be present from the very first line of tap code and must never compile into release builds (`#if DEBUG`).
3. **Visible recovery / warning state.** If the event tap can't be created, the overlay must show a clear, visible "input unavailable / how to recover" recovery state rather than silently trapping input. If the tap gets disabled (`tapDisabledByTimeout` / `tapDisabledByUserInput`) while locked, re-enable it and show a visible warning on the overlay. If it cannot be re-enabled, keep holding the lock and require authentication — see THE INVARIANT above. These hatches exist so a lock never becomes *invisible* or *unexplained*; none of them is a way out without authentication.

Force Quit (`⌘⌥Esc`) is deliberately disabled while locked (`NSApplicationPresentationOptions.disableForceQuit`): opening it steals focus from the authentication prompt and strands the user. The escape hatches above replace it. Order of implementation is fixed: **SIGTERM handler → debug auto-unlock → recovery UI come before any input-suppressing code.**

## Architecture / hard constraints

- **Non-sandboxed.** The App Sandbox is **off** and must stay off: active `CGEventTap`s and the Accessibility API are incompatible with the sandbox. This is *why* Frost ships outside the Mac App Store.
- **Hardened Runtime stays on** (required for Developer ID notarization).
- **No kernel extension, no privileged helper tool, no root.** Everything runs as the logged-in user.
- **No network except Sparkle's update check.** No telemetry, no analytics, no crash reporting, no licensing/DRM, no accounts. Local-only.
- **Distribution is outside the Mac App Store, via Sparkle.** Never reference the App Store, App Store review, or MAS receipts.

## Core APIs (intended implementation)

- **Input suppression:** `CGEvent.tapCreate` with `.cgSessionEventTap` + `.headInsertEventTap` + `.defaultTap` — an *active* session-level tap; suppress by returning `nil` from the callback. Re-enable on `tapDisabledByTimeout` / `tapDisabledByUserInput` and make that visible in the overlay. Do not switch to `.cghidEventTap` without explicitly accepting a root/privileged architecture.
- **Overlays:** one borderless `NSWindow` per `NSScreen`, level `.screenSaver`, collection behavior `canJoinAllSpaces` + `fullScreenAuxiliary`. Rebuild on `NSApplication.didChangeScreenParametersNotification`. Respect `safeAreaInsets` for notched displays.
- **Unlock:** Touch ID by default, optionally Touch ID *or Apple Watch* (`.deviceOwnerAuthenticationWithBiometricsOrWatch`) behind the default-off `allowWatchUnlock` setting — the event tap suppresses keyboard input while locked, so a typed password is not a viable unlock path. Preflight Touch ID with `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` before suppressing input; if Touch ID is unavailable, show recovery and do not lock. The actual unlock evaluation uses a fresh `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` (empty `localizedFallbackTitle`, so no password button), which presents the standard system Touch ID prompt. By default Touch ID is **not** armed automatically on lock: the lock sits idle until the unlock hotkey opens the prompt, and Escape cancels back to the idle locked state. The optional `startTouchIDWhenLocked` setting opens the prompt as soon as the lock begins. Frost activates and keys the overlay window on the **active display** — the one the pinned cursor is on, where the lock was triggered — not always the menu-bar display, so the system prompt appears there. The unlock hotkey is recognized **inside** the event-tap callback (keycodes + modifier flags), because normal key/menu routing is dead while input is suppressed. Pointer events are swallowed while locked; do not add mouse click-through unless the tap/overlay safety story is redesigned.
- **Sleep:** `IOPMAssertionCreateWithName` with two independent assertions, `kIOPMAssertionTypePreventUserIdleDisplaySleep` and `kIOPMAssertionTypePreventUserIdleSystemSleep`. Acquire on lock, release on unlock/terminate. **Do not** claim lid-closed operation.
- **Secure event input:** preflight `IsSecureEventInputEnabled()` before suppressing anything and refuse to lock while it is held. The WindowServer routes keyboard events only to the secure-input holder, so they never reach a session-level tap — `tapCreate` still succeeds, the pointer still freezes, and the in-tap unlock chord can never fire. Frost also watches for it mid-lock, but deliberately only WARNS there: auto-unlocking on a false positive would silently unlock an unattended Mac, and the system authentication prompt may itself hold secure input.
- **Permissions:** Accessibility via `AXIsProcessTrustedWithOptions`. Do not gate Frost on Input Monitoring unless the event-tap architecture changes and testing proves it is required. After a user grants Accessibility, require a Frost relaunch before attempting to lock; do not auto-lock or promise automatic retry from the running process.
- **Updates:** Sparkle `SPUStandardUpdaterController` with a "Check for Updates…" menu item.
- **Launch at login:** `SMAppService.mainApp`.

## Session lifecycle and app behavior

- `LockController` owns teardown: release the event tap, restore the cursor,
  clear presentation options, release power assertions, and dismiss overlays
  when the session ends through an authorized path.
- `SIGINT` and `SIGHUP` use the same clean teardown as `SIGTERM`, covering
  Ctrl-C or a closed session in a terminal opened before locking. `kill -9`
  and crashes skip teardown and rely on macOS to reclaim the tap and cursor
  association. Do not describe these as clean exits.
- The DEBUG auto-unlock timer shows a countdown on the overlay and tears down
  regardless of authentication state. It must never compile into Release.
- Startup failures show **Input Not Locked** with recovery guidance and a retry
  button where retrying in place is useful. Missing Accessibility provides
  Privacy settings and **Quit & Reopen** actions; a fresh grant requires a
  relaunch, never an automatic lock attempt.
- If an existing tap cannot be revived, release the dead tap to restore pointer
  interaction, retain the overlay and presentation options, and offer an
  **Unlock with Touch ID** button. The shortcut cannot work without the tap;
  authentication is still required to dismiss the overlay.
- The global lock shortcut uses an `NSEvent` monitor only while unlocked. Clear
  it if it matches the unlock shortcut, which is recognized inside the tap.
- Overlay messages are optional and truncated so the unlock hint stays visible.
- The menu's **Lock Input** item reads **Locked** during suppression and
  **Input Not Locked** during recovery; it is disabled in both states.
- A plain launch shows no window, keeping login-item starts silent. On reopen,
  `AppDelegate` shows the explicit AppKit settings window so users can recover
  a hidden menu-bar item. Recovery's **Quit & Reopen Frost** launches with
  `--show-settings` to show settings immediately.
- The **Lock Input** App Intent runs the same preflights and recovery behavior
  as the menu item. It is a no-op while locked or showing recovery. Debug
  builds publish **Lock Input (Dev)** to distinguish the installed app.
- App Shortcuts appear in Shortcuts.app after the first launch, but are not
  directly in the `shortcuts` CLI library. Users must first create a named
  shortcut containing the action before invoking `shortcuts run "Lock Input"`.
  There is no unlock automation or `frost://` URL scheme.

## Implementation reference

### Input Suppression

`EventTapManager` owns a session-level `CGEvent` tap:

- `CGEventTapLocation.cgSessionEventTap`
- `.headInsertEventTap`
- `.defaultTap`

Returning `nil` from the callback swallows input. The callback recognizes the
unlock shortcut before swallowing the key event. The tap mask also includes
macOS system-defined events, so media keys (volume, brightness, play/pause,
eject) are suppressed while locked.

Frost deliberately does not use `CGEventTapLocation.cghidEventTap`: Apple's SDK
requires root for that earlier tap location, and Frost runs as the logged-in
user.

During authentication, the tap remains active and the overlay remains visible.
Bare Escape is allowed through so the system authentication prompt can be
cancelled. Modified Escape combinations, including Force Quit, remain swallowed.

### Overlay

`OverlayCoordinator` creates one borderless `NSWindow` per display.

Overlay windows:

- use `.screenSaver` level while input is locked, and `.floating` for recovery
  overlays so system dialogs — notably the Accessibility consent prompt — stay
  above them and clickable
- join all Spaces
- support full-screen auxiliary presentation
- rebuild when screen parameters change
- place the central affordance inside each display's safe area
- use a translucent material card so the underlying screen remains visible

The normal locked overlay is informational. Recovery overlays are interactive
only when input was not successfully locked.

### App Presentation Options

Some system gestures and switchers happen above the HID event layer. Frost uses
`NSApplicationPresentationOptions` while locked to hide or disable those routes:

- hide Dock
- hide menu bar
- disable process switching
- disable Force Quit
- disable Apple menu

Those options are always cleared during teardown.

### Local Authentication

`UnlockCoordinator` wraps LocalAuthentication:

```swift
LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)
```

Before locking, Frost verifies that the Mac reports Touch ID through
`.deviceOwnerAuthenticationWithBiometrics`. During unlock, a fresh `LAContext`
(with an empty `localizedFallbackTitle`, so no password button) is evaluated with
`.deviceOwnerAuthenticationWithBiometrics`, presenting the standard system Touch
ID prompt — Touch ID only, since keyboard input stays suppressed while locked.
If "Allow Apple Watch to unlock" is enabled in Settings, Frost evaluates
`.deviceOwnerAuthenticationWithBiometricsOrWatch` instead, so a paired,
unlocked Watch can approve the unlock; the no-password rationale is
unchanged — both paths are out-of-band from the suppressed keyboard.

### Power Assertions

`SleepAssertionManager` uses IOKit power assertions while locked:

- `kIOPMAssertionTypePreventUserIdleDisplaySleep`
- `kIOPMAssertionTypePreventUserIdleSystemSleep`

They are controlled by settings and released on every teardown path. They do not
override the power button or closed-lid behavior.

### Updates

`UpdaterController` owns Sparkle's `SPUStandardUpdaterController`.

Sparkle reads:

- `SUFeedURL` from `frost/Info.plist`
- `SUPublicEDKey` from `frost/Info.plist`

The current feed URL is:

```text
https://abdeen.dev/frost/appcast.xml
```

Builds up to 2.2 polled the retired `updates.abdeen.dev` alias, so those
installs no longer see updates; `RELEASING.md` covers it.

Do not replace `SUPublicEDKey`. It is the public EdDSA key used to verify
updates for existing installs.

Frost sets `SUVerifyUpdateBeforeExtraction` so a downloaded update's EdDSA
signature is verified before the archive is even unarchived. Sparkle's
scheduled background checks are deferred while input is locked, so an update
alert can never compete with the Touch ID prompt for focus.

### Privacy Manifest

`PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected
data types, and UserDefaults access for Frost's own settings.

## Source map

- `frost/frostApp.swift`: app entry point, menu-bar item, shared controllers.
- `frost/AppDelegate.swift`: launch/reopen hooks for showing settings.
- `frost/SettingsWindowController.swift`: explicit AppKit settings window.
- `frost/SettingsView.swift`: settings UI.
- `frost/SettingsStore.swift`: persisted user preferences.
- `frost/LockController.swift`: lock-session state machine and teardown owner.
- `frost/EventTapManager.swift`: active `CGEvent` tap and unlock shortcut handling.
- `frost/InactivityLockMonitor.swift`: idle-time polling for optional auto-lock.
- `frost/InactivityLockOption.swift`: persisted inactivity timeout choices.
- `frost/LaunchAtLoginManager.swift`: `SMAppService.mainApp` wrapper.
- `frost/OverlayCoordinator.swift`: per-display overlay windows and recovery UI.
- `frost/UnlockCoordinator.swift`: LocalAuthentication wrapper.
- `frost/SleepAssertionManager.swift`: display and system idle assertions.
- `frost/PermissionManager.swift`: Accessibility checks.
- `frost/Shortcut.swift`: shortcut persistence, matching, and display.
- `frost/ShortcutRecorder.swift`: AppKit-backed shortcut recorder control.
- `frost/UpdaterController.swift`: Sparkle update wrapper.
- `frost/SystemHooks.swift`: SIGTERM/SIGINT/SIGHUP handlers and the force-exit
  watchdog (escape hatch #1), the global lock-hotkey monitor, and the
  Accessibility-trust observer.
- `frost/FrostAppIntents.swift`: the Lock Input App Intent and App Shortcut.
- `scripts/publish.sh`: DMG packaging and appcast generation.
- `scripts/release.sh`: end-to-end release — DMG + appcast via publish.sh,
  GitHub Release upload, appcast publish to the update host.

## Signing & secrets

- `Info.plist` holds `SUPublicEDKey` (Sparkle's **public** EdDSA key) and `SUFeedURL`. **Never overwrite `SUPublicEDKey`** — replacing it breaks update verification for everyone already running Frost.
- The Sparkle **private** key lives in the developer's login Keychain (created by `generate_keys`). It is never committed and never written to a file in this repo. `.gitignore` blocks common key filenames as a backstop.

## Build / verify

- Target: macOS 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.6`), SwiftUI + AppKit hybrid, `LSUIElement` agent (no Dock icon). Bundle id `dev.abdeen.frost`.
- To verify, run `scripts/test.sh` — it is the exact CI invocation.

### Building from source (human workflow)

1. Open `Frost.xcodeproj` in Xcode.
2. Select the `frost` scheme (it builds the `Frost` target).
3. Build and run.
4. Grant Accessibility when prompted.
5. Quit and relaunch Frost so the Accessibility grant is active in the app process.

To run the unit suite from the command line: `scripts/test.sh` (same invocation CI uses).

Important project settings:

- `MACOSX_DEPLOYMENT_TARGET = 14.6`
- `ENABLE_APP_SANDBOX = NO`
- `ENABLE_HARDENED_RUNTIME = YES`
- `INFOPLIST_KEY_LSUIElement = YES`
- Bundle id is configuration-specific so a dev build can coexist with an
  installed copy without fighting over the same Accessibility (TCC) grant:
  Debug builds use `dev.abdeen.frost.debug` and display as "Frost (Dev)";
  Release keeps `dev.abdeen.frost` / "Frost". Grant Accessibility to each once.
- Sparkle is resolved through Swift Package Manager (currently 2.9.3).
- `PrivacyInfo.xcprivacy` is bundled from the synchronized `frost` folder.

## Release packaging

Releases are cut with:

```sh
scripts/release.sh /path/to/frost.app
```

from an already exported, signed, notarized, and stapled `frost.app`. See
`RELEASING.md` for the full procedure, including one-time setup.

`release.sh`:

1. Builds `dist/Frost-<version>.dmg` and the EdDSA-signed `dist/appcast.xml`
   (via `scripts/publish.sh`).
2. Creates the GitHub Release `v<version>` and uploads the DMG there.
3. Commits the appcast to the abdeen.dev repo, which serves it at
   `https://abdeen.dev/frost/appcast.xml`.

The DMG lives on GitHub Releases; only the appcast lives on the update
domain. The appcast's enclosure URL points at the GitHub asset.

`scripts/publish.sh` is the lower-level DMG/appcast builder that
`release.sh` drives. Running it standalone is for dry runs and legacy
flows, not the release procedure.

Release notes for both the GitHub release and the in-app Sparkle update dialog
come from the matching [`CHANGELOG.md`](CHANGELOG.md) section (extracted by
`scripts/changelog.sh`), so update the changelog before cutting a release — see
`RELEASING.md`.

Sparkle's private EdDSA key belongs in the developer's login Keychain, created
by Sparkle's `generate_keys`. It must not be committed or written into this
repository.

## Working style

- Build in phases; do not scaffold the whole app at once.
- Keep changes narrow and consistent with the surrounding code.
- Keep `README.md` focused on installation, everyday use, settings, privacy,
  and recovery. Put implementation details and contributor instructions here;
  keep the full release procedure in `RELEASING.md`.
