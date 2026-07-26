# Changelog

All notable changes to Frost are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

At release time, `scripts/release.sh` and `scripts/publish.sh` read the section
for the version being shipped and use it verbatim as both the GitHub release
notes and the Sparkle update description — so keep entries user-facing and write
them for someone deciding whether to install the update.

## [Unreleased]

<!-- Add entries here, under [Unreleased], in the same PR as the change. At
     release, leave this heading and comment in place and insert the new
     "## [x.y.z] - YYYY-MM-DD" heading just below, so the entries fall under it;
     then repoint the [Unreleased] link and add a compare-link at the bottom. -->

### Added

- Frost now refuses to lock while another app has secure keyboard entry turned on. In that state macOS never delivers the keyboard to Frost, so the unlock shortcut could not have worked.
- The locked overlay names Apple Watch when Watch unlock is on, including how to approve with the side button.
- Shortcut fields can be set from the keyboard, show a focus ring, and say what a rejected combo was missing.

### Fixed

- The locked overlay is readable with Reduce Transparency turned on in Light Mode, where it previously showed dark text on a dark card.
- The overlay's panels, borders, and status pills are visible in Light Mode instead of fading into the background.
- A long overlay message can no longer push the unlock-shortcut hint off the screen.
- Recording a lock shortcut that matches the unlock shortcut no longer deletes the lock shortcut you already had.
- The Launch at login switch stays on after registering when macOS still wants approval in Login Items.
- Recovery buttons follow macOS order, so the rightmost button is no longer Dismiss.
- The recovery overlay no longer swallows clicks meant for the apps underneath it, which it did while telling you input was not locked.
- Quit & Reopen Frost now opens Settings after relaunching, and keeps Frost running if the relaunch fails.
- The Lock Input shortcuts action now reports an error when the lock did not happen, instead of reporting success.
- Frost recovers if a display change momentarily leaves it with no screen to draw the overlay on.
- A disconnected Touch ID keyboard or unavailable Apple Watch is reported as such, instead of "Touch ID didn't match".
- Auto-lock no longer wakes the app every few seconds when it is turned off.

## [2.1.2] - 2026-07-07

### Fixed

- Frost no longer opens the Settings window when it starts automatically at login — it now comes up quietly in the background, like other menu-bar apps.

## [2.1.1] - 2026-07-07

### Added

- This changelog.

## [2.1] - 2026-07-07

### Added

- Lock Input App Intent, so you can lock from the Shortcuts app, Spotlight, or a script.
- Optional Apple Watch unlock, off by default and enabled in Settings.
- Optional owner message shown on the locked overlay.

### Fixed

- The Settings window now opens above other apps without stealing initial keyboard focus.
- The failed-lock snooze is preserved across baseline resets.

### Changed

- Removed an unverified timeout claim from the Inactivity settings footer.

## [2.0] - 2026-07-01

### Added

- Termination watchdog that keeps input from staying locked if the app is killed.

### Changed

- Reworked the recovery, menu, and settings UX following a full audit.

### Fixed

- Hardened the global shortcuts, event tap, and Sparkle update flow, and resolved the top audit findings.

## [1.4] - 2026-06-29

### Changed

- Switched from the embedded Touch ID prompt to the system Touch ID prompt.

### Fixed

- Delayed the Touch ID prompt until the lock window is key, so it no longer appears before the overlay is ready.

## [1.3] - 2026-06-29

### Fixed

- Touch ID now succeeds on the first attempt.

### Changed

- Improved safety, responsiveness, and accessibility handling, including the inactivity monitor.

## [1.2.1] - 2026-06-25

- Packaging and maintenance only; no user-facing changes.

## [1.2] - 2026-06-25

### Changed

- Require relaunching Frost after granting Accessibility permission, so the input tap installs reliably.

## [1.1] - 2026-06-25

### Added

- In-app updater UI (Sparkle) and accessibility-permission retry logic.

## [1.0.2] - 2026-06-25

### Fixed

- Re-arm the lock hotkey when Accessibility trust changes, so the shortcut keeps working after you grant permission.

## [1.0.1] - 2026-06-25

- Release-tooling fixes; no user-facing changes.

## [1.0] - 2026-06-25

Initial public release.

### Added

- Input lock that blocks keyboard, mouse, and kiosk gestures.
- Touch ID unlock (biometrics-only) with multi-display support.

<!-- Corrected after publication: this section originally claimed the lock was
     "cancelable with Esc" and that Touch ID had "a password fallback". Neither
     was ever true. Esc only cancels the Touch ID PROMPT and returns to the idle
     locked state; it never ends a lock. And Frost evaluates the biometrics-only
     policy with an empty localizedFallbackTitle, so no password button exists.
     These sections ship verbatim as GitHub release notes and Sparkle update
     descriptions, so a trapped user could have hammered Esc expecting release
     and looked for a password box that is not there. -->
- Menu-bar agent with a configurable lock/unlock shortcut and power toggles.
- Settings window for lock/unlock shortcuts, auto-lock durations, auto-start Touch ID, and menu-bar visibility.
- Pointer stays pinned while the screen is locked.
- Sparkle-based automatic updates.

[Unreleased]: https://github.com/Cuzeth/frost/compare/v2.1.2...HEAD
[2.1.2]: https://github.com/Cuzeth/frost/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/Cuzeth/frost/compare/v2.1...v2.1.1
[2.1]: https://github.com/Cuzeth/frost/compare/v2.0...v2.1
[2.0]: https://github.com/Cuzeth/frost/compare/v1.4...v2.0
[1.4]: https://github.com/Cuzeth/frost/compare/v1.3...v1.4
[1.3]: https://github.com/Cuzeth/frost/compare/v1.2.1...v1.3
[1.2.1]: https://github.com/Cuzeth/frost/compare/v1.2...v1.2.1
[1.2]: https://github.com/Cuzeth/frost/compare/v1.1...v1.2
[1.1]: https://github.com/Cuzeth/frost/compare/v1.0.2...v1.1
[1.0.2]: https://github.com/Cuzeth/frost/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Cuzeth/frost/compare/v1.0...v1.0.1
[1.0]: https://github.com/Cuzeth/frost/releases/tag/v1.0
