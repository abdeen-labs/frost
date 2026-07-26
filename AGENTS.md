# AGENTS.md — Frost

Guardrails for AI agents (and humans) working in this repository. **Read this before making changes.**

## What Frost is

Frost is a **macOS menu-bar input locker**. It blocks keyboard, mouse, and trackpad input while keeping the display fully visible, and unlocks via Touch ID on Macs with Touch ID. It exists to lock your desk while an unattended-but-visible task runs — an AI agent, a long build, a render.

## What Frost is NOT — do not change these framings

- **Not a screen locker.** The screen stays on and visible; content is never hidden or blanked.
- **Not a replacement for the macOS login window (`loginwindow`).** It does not log the user out, does not gate at the login screen, and is not a security boundary against a determined local attacker.
- **Not a kiosk/MDM tool, parental control, or anti-theft device.**

Describe it as an *input suppressor + overlay manager + local auth gate*. Never document or market it as a security / lock-screen product.

## CRITICAL SAFETY — never lock the user out

Input suppression can trap the user with no way to type or click. Every change must preserve **all** of these escape hatches. If a change would weaken any of them, stop and flag it.

1. **Remote kill (SIGTERM).** Frost catches `SIGTERM` and tears the lock down cleanly (restores the cursor, releases the tap) before exiting, independent of app state. Because the event tap blocks *local* input, the realistic way to trigger it is **over SSH from another device** (`pkill -x frost` / `kill <pid>`) with Remote Login enabled in advance, or from a terminal you opened before locking — document it that way. (There is intentionally no in-repo killswitch script; the SIGTERM handler is the contract.)
2. **Debug auto-unlock timer.** In DEBUG builds, a timer tears the lock down after N seconds regardless of auth. It must be present from the very first line of tap code and must never compile into release builds (`#if DEBUG`).
3. **Visible recovery / warning state.** If the event tap can't be created, the overlay must show a clear, visible "input unavailable / how to recover" recovery state rather than silently trapping input. If the tap gets disabled (`tapDisabledByTimeout` / `tapDisabledByUserInput`) while locked, re-enable it and show a visible warning on the overlay.

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

## Modules

`LockController`, `PermissionManager`, `OverlayCoordinator`, `EventTapManager`, `UnlockCoordinator`, `SleepAssertionManager`, `InactivityLockMonitor`, `LaunchAtLoginManager`, `SettingsStore`, `SystemHooks` (signal handlers + force-exit watchdog + lock-hotkey monitor), `FrostAppIntents` (the Lock Input intent), and `UpdaterController` (wraps Sparkle).

## Signing & secrets

- `Info.plist` holds `SUPublicEDKey` (Sparkle's **public** EdDSA key) and `SUFeedURL`. **Never overwrite `SUPublicEDKey`** — replacing it breaks update verification for everyone already running Frost.
- The Sparkle **private** key lives in the developer's login Keychain (created by `generate_keys`). It is never committed and never written to a file in this repo. `.gitignore` blocks common key filenames as a backstop.

## Build / verify

- Target: macOS 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.6`), SwiftUI + AppKit hybrid, `LSUIElement` agent (no Dock icon). Bundle id `dev.abdeen.frost`.
- Agents should **not** run `xcodebuild`. Hand builds/tests to the human and ask for the output.
- When handing verification to the human, ask them to run `scripts/test.sh` — it is the exact CI invocation.
- Releases are packaged with `scripts/publish.sh` (DMG + `generate_appcast`); the appcast is hosted at `https://updates.abdeen.dev/frost/appcast.xml`.

## Working style

- Build in phases; do not scaffold the whole app at once.
- Keep changes narrow and consistent with the surrounding code.
