<p align="center">
  <img src="assets/banner.svg" alt="Frost — macOS menu-bar input locker" width="100%">
</p>

Frost is a macOS menu-bar input locker. It suppresses keyboard, mouse, and
trackpad input while keeping the display visible, then unlocks with Touch ID on
Macs with Touch ID.

It is built for the awkward but useful moment when you want the Mac to keep
showing an unattended task, but you do not want local input to interfere with it:
an agent run, a long build, a render, a benchmark, a terminal session, or any
other visible-but-hands-off work.

Frost is best described as:

- an input suppressor
- an overlay manager
- a local authentication gate

It is not a screen locker, not a replacement for the macOS login window, and not
a security boundary against a determined person with physical access. Your
screen contents stay visible.

## Status

Frost is a focused macOS app in active development.

- Platform: macOS 14.6+
- Requires: a Mac with Touch ID configured (or, optionally, a paired Apple Watch with Watch unlock enabled in Settings)
- UI: SwiftUI plus AppKit
- App type: `LSUIElement` menu-bar agent, with no Dock icon
- Bundle ID: `dev.abdeen.frost`
- Updates: Sparkle 2.9.3
- Sandbox: off
- Hardened Runtime: on

## What Frost Does

When you choose **Lock Input**, Frost:

1. Checks that Touch ID is available and configured.
2. Checks that no other app holds secure event input — while it is held, the
   keyboard never reaches a session-level tap, so the unlock shortcut could not
   fire.
3. Checks that Accessibility is granted.
4. Creates an active `CGEvent` tap.
5. Suppresses keyboard and pointer events by swallowing them in the tap callback.
6. Freezes the cursor position.
7. Shows a translucent overlay on every display — and refuses the lock if no
   display could host one, rather than suppressing input behind nothing.
8. Hides system switching surfaces that cannot be stopped at the event-tap layer.
9. Optionally holds power assertions to keep the display and/or system awake.
10. Waits for the configured unlock shortcut.

When you press the unlock shortcut, Frost keeps the overlay and event tap active
and asks macOS to authenticate with
`LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` — Touch ID
only, no password fallback, because keyboard input stays suppressed while locked.
This presents the standard system Touch ID prompt. Frost activates and keys the
overlay window on the display where the lock was triggered, not always the
menu-bar display, so the prompt appears where the user is looking. If
authentication succeeds, Frost tears everything down and restores normal input.
If it is cancelled with Escape, Frost returns to the idle locked state and the
unlock shortcut re-opens the prompt.

The default unlock shortcut is `Control-Option-Command-U`.

## What Frost Does Not Do

Frost deliberately does not:

- hide, blank, blur, or replace the screen
- log the user out
- switch to the macOS login window
- run as root
- install a kernel extension
- install a privileged helper
- claim to protect against a determined local attacker
- claim closed-lid operation
- send telemetry, analytics, crash reports, licensing calls, or account data

The only intended network activity is Sparkle update checking.

## Frost Never Unlocks Itself

Frost will not hand the machine back without Touch ID. Not after repeated failed
attempts, not if Touch ID gets locked out, not if the sensor disconnects, not if
macOS interferes with input blocking, not on any timer.

This is deliberate. Frost cannot tell whether the person at the keyboard is the
owner who locked themselves out or someone else who walked up, and it does not
guess. If Touch ID cannot authenticate you, the way back is `pkill -x frost`
over SSH from another device, or holding the power button. That is the trade
Frost makes, and it is the reason the app is worth running at all.

The one exception is debug builds, which include an auto-unlock timer so a
developer cannot trap themselves. It is compiled out of release builds.

## Safety And Recovery

Input suppression is inherently risky: a bug can leave the local keyboard and
mouse unable to interact with the app. Frost keeps several escape hatches, and
they are part of the project contract.

### Normal Unlock

Press the configured unlock shortcut to open the Touch ID prompt, then
authenticate with Touch ID. If you cancel the prompt with Escape, press the
shortcut again to re-open it.

The unlock shortcut is recognized inside the event-tap callback, because normal
menu and keyboard routing is unavailable while input is suppressed.

### Remote Kill

Frost catches `SIGTERM` and performs a clean teardown before exiting. That
teardown restores the cursor, releases the event tap, releases power assertions,
dismisses overlays, and clears app presentation options.

Because local input is suppressed while locked, the practical recovery route is
from another device over SSH with Remote Login enabled before locking:

```sh
pkill -x frost
```

You can also use `kill <pid>` if you already know the process ID. A terminal
that was opened before locking can also send the signal.

There is intentionally no in-repo kill script. The `SIGTERM` handler is the
recovery contract.

`SIGTERM` is the supported remote-kill path. `SIGINT` and `SIGHUP` get the same
clean teardown, covering Ctrl-C or a closed session in a terminal that was
opened before locking. A forced kill such as `kill -9` or a process crash skips
Frost's teardown and relies on macOS to reclaim the event tap and cursor
association.

### Debug Auto-Unlock

Debug builds include an automatic unlock timer. The overlay shows its countdown,
and it tears the lock down regardless of authentication state.

This is compiled only in `DEBUG` builds and must never ship in release builds.

### Recovery UI

If Frost cannot acquire the required permissions, cannot verify Touch ID, or
cannot create an event tap, it does not lock input. Instead, it shows an
**Input Not Locked** recovery overlay with guidance and, where retrying in place
is useful, a retry button. When Accessibility is the issue, the overlay also
includes a button to open Privacy settings and a **Quit & Reopen** button,
because macOS may not make a fresh Accessibility grant usable until Frost is
relaunched — and a quit-only path would leave an agent with no Dock icon and
nothing visible to reopen.

If macOS disables the event tap while Frost is already locked, Frost attempts to
re-enable it immediately and shows a visible warning on the overlay. If the tap
cannot be created at all, Frost does not lock input.

If the tap cannot be re-enabled, input is flowing again — macOS did that, and
Frost cannot prevent it. Frost still does not unlock: it keeps the overlay up,
stops claiming to block input, says what happened, and offers an **Unlock with
Touch ID** button (the unlock shortcut lived inside the tap and is gone with
it). Only authentication takes the overlay down.

### Force Quit

Frost disables the Force Quit panel while locked. This is intentional: opening
Force Quit while the authentication prompt is active can steal focus from the auth
prompt and strand the user. Use the unlock shortcut, the debug auto-unlock in
debug builds, or the `SIGTERM` path above.

## Permissions

Frost needs one user-granted macOS privacy permission:

- Accessibility: required for an active event tap to alter or suppress events.

It is granted in:

```text
System Settings > Privacy & Security
```

If Accessibility is missing, Frost prompts where macOS allows it, then shows the
recovery overlay instead of suppressing input. After granting Accessibility,
quit and reopen Frost before trying to lock input.

## Settings

Open settings from the menu-bar item. Frost never opens a window on launch, so
that starting at login stays silent. If the menu-bar item is hidden, open Frost
again *while it is already running* (Finder, Spotlight, or `open -a Frost`) —
that delivers a reopen, which shows the settings window.

Current settings:

- Unlock Shortcut: required; defaults to `Control-Option-Command-U`.
- Lock Shortcut: optional global shortcut that starts input suppression. Frost
  clears it if it matches the unlock shortcut.
- Auto-lock: optional inactivity timer based on keyboard, mouse, and trackpad
  idle time, from 30 seconds up to 2 hours.
- Start Touch ID automatically when locked: optional; opens the Touch ID prompt
  as soon as a lock begins instead of waiting for the unlock shortcut.
- Allow Apple Watch to unlock: optional, off by default; also accepts a paired,
  unlocked Apple Watch (double-press its side button when prompted) as an
  unlock path alongside Touch ID.
- Overlay message: optional owner-supplied text shown on the locked overlay
  while input is suppressed. Empty means none; long messages are shortened so
  the unlock-shortcut hint always stays visible.
- Prevent screen saver: holds a display-sleep prevention assertion while locked.
- Prevent sleep: holds an idle system-sleep prevention assertion while locked.
- Launch at login: registers Frost as a main-app login item with `SMAppService`.
- Show in menu bar: controls whether the menu-bar item is visible.
- Quit Frost: exits the menu-bar agent from the settings window.

The optional lock shortcut uses a global `NSEvent` monitor while Frost is
unlocked. The unlock shortcut is handled separately inside the `CGEvent` tap
while Frost is locked.

## Menu Bar

Frost is an `LSUIElement` agent, so it has no Dock icon. The menu-bar item
contains:

- Lock Input (reads Locked while input is suppressed, and Input Not Locked
  while a recovery overlay is showing; disabled in both states)
- Settings...
- Check for Updates...
- Quit Frost

If the menu-bar item is hidden in settings, Frost still needs a way back in.
`AppDelegate` shows the explicit AppKit settings window when it receives a
*reopen* — i.e. when Frost is opened again while already running. A plain launch
deliberately shows nothing, so a login-item start is silent. The one exception is
the recovery overlay's **Quit & Reopen Frost**, which passes `--show-settings` to
the instance it launches.

## Automation

Frost exposes one Shortcuts action, **Lock Input**, through App Intents. It
starts the same lock as the menu item — every preflight (Touch ID
availability, Accessibility) and every recovery behavior applies unchanged —
and is a no-op if Frost is already locked or showing the recovery overlay.

After Frost has been launched once, the action appears in Shortcuts.app's
action gallery. App Shortcuts published this way are not visible to the
`shortcuts` command-line tool's library, so it cannot find the action
directly. To run it from a terminal or script, first create a shortcut in
Shortcuts.app that contains the Lock Input action — a one-time step — and
name it, e.g., "Lock Input". After that, running the shortcut from the
command line works:

```sh
shortcuts run "Lock Input"
```

Debug builds publish the action as "Lock Input (Dev)", mirroring the Frost
(Dev) build split, so a development build never masquerades as the installed
app in Shortcuts.

There is deliberately no unlock automation and no `frost://` URL scheme: the
intent can only start a lock, never end one.

## How It Works

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
https://updates.abdeen.dev/frost/appcast.xml
```

Do not replace `SUPublicEDKey`. It is the public EdDSA key used to verify
updates for existing installs.

Frost sets `SUVerifyUpdateBeforeExtraction` so a downloaded update's EdDSA
signature is verified before the archive is even unarchived. Sparkle's
scheduled background checks are deferred while input is locked, so an update
alert can never compete with the Touch ID prompt for focus.

### Privacy Manifest

`PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected
data types, and UserDefaults access for Frost's own settings.

## Source Map

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

## Build From Source

1. Open `frost.xcodeproj` in Xcode.
2. Select the `frost` target/scheme.
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
- Sparkle is resolved through Swift Package Manager.
- `PrivacyInfo.xcprivacy` is bundled from the synchronized `frost` folder.

For AI agents and automated edits, read `AGENTS.md` before touching the project.
It contains the safety invariants that must not regress.

## License

MIT — see [`LICENSE`](LICENSE).

## Release Packaging

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
   `https://updates.abdeen.dev/frost/appcast.xml`.

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

## Development Rules Worth Keeping Visible

- Preserve the `SIGTERM` teardown path.
- Preserve the debug auto-unlock timer in debug builds only.
- Never start suppressing input without a visible recovery path for startup
  failures.
- If the tap is disabled while locked, re-enable it and show a visible overlay
  warning instead of silently treating the lock as healthy.
- Always release the event tap, restore the cursor, clear presentation options,
  and release power assertions during teardown.
- Keep the app non-sandboxed.
- Keep Hardened Runtime enabled.
- Do not add telemetry, analytics, crash reporting, licensing, accounts, or
  network access outside Sparkle update checks.
- Do not introduce root helpers, privileged daemons, or kernel extensions.
- Do not overwrite Sparkle's `SUPublicEDKey`.
- Do not describe Frost as a screen locker or security product.
