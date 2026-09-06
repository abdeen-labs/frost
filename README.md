<p align="center">
  <img src="assets/banner.svg" alt="Frost — macOS menu-bar input locker" width="100%">
</p>

Keep your Mac working, without accidental input getting in the way.

Frost lives in your menu bar and blocks keyboard, mouse, and trackpad input
while your screen stays visible. Use it to keep an eye on a long build, render,
or AI task, then unlock with Touch ID when you're ready to take over.

Your screen contents remain visible to anyone nearby. Frost doesn't replace
the macOS lock screen or protect against someone determined to access your Mac.

## Get started

You'll need **macOS 14.6 or later** and **Touch ID configured**. You can also
use a paired, unlocked Apple Watch by enabling **Allow Apple Watch to unlock**
in Frost's settings.

1. Download Frost from [GitHub Releases](https://github.com/abdeen-labs/frost/releases),
   open the disk image, and drag Frost to Applications.
2. Open Frost. It appears in the menu bar, with no Dock icon.
3. Grant Frost **Accessibility** access in **System Settings → Privacy & Security
   → Accessibility** when prompted.
4. Quit and reopen Frost after granting access.

Before your first lock, read [Recovery](#recovery) below and set up Remote Login
if you want a way to quit Frost from another device.

## Lock and unlock

Choose **Lock Input** from Frost's menu. An overlay appears on each display,
the pointer stays in place, and keyboard, mouse, and trackpad input is blocked.
Your work remains visible underneath.

To unlock, press **Control–Option–Command–U** (`⌃⌥⌘U`), then authenticate with
Touch ID. If you've enabled Apple Watch unlock, you can double-press your
Watch's side button when prompted instead.

Press **Escape** to cancel the authentication prompt and stay locked. Press
the unlock shortcut again whenever you're ready to retry. You can change the
shortcut or have the prompt open automatically in Settings.

## Make it yours

Open **Settings…** from the menu bar to adjust:

- **Shortcuts:** change the unlock shortcut and optionally add a lock shortcut.
- **Auto-lock:** lock after 30 seconds to 2 hours without keyboard, mouse, or
  trackpad activity. Reading or watching without interacting counts as idle.
- **Authentication:** open Touch ID automatically on lock, or allow Apple Watch
  to unlock. Both options are off by default.
- **Overlay message:** add a message to show while input is locked.
- **Keep awake:** use **Prevent screen saver** and **Prevent sleep** to keep the
  display and Mac awake while locked. These don't keep a Mac running with its
  lid closed.
- **Startup and menu bar:** launch at login or hide the menu-bar icon.

If you hide the icon, open Frost again from Applications or Spotlight to show
Settings. Frost starts quietly at login without opening a window.

## Recovery

**There is no password fallback while input is blocked, and Force Quit is
disabled.** Frost requires successful authentication to unlock; it won't release
input just because authentication fails or a device disconnects. Repeated Touch
ID failures can lock out Touch ID, which requires a typed password to reset.
You can't type that password while Frost is blocking input.

If you can't authenticate, you can quit Frost from another device over SSH.
Enable **Remote Login** on your Mac *before* locking, then connect from the
other device and run:

```sh
pkill -x frost
```

This quits Frost and restores input. If remote recovery isn't available and
you can't authenticate, holding the power button to turn off the Mac is the
remaining recovery option; unsaved work may be lost.

If Frost can't start a lock—for example, because Accessibility is missing,
authentication is unavailable, or another app is protecting keyboard input—it
shows **Input Not Locked** with instructions. Follow those instructions before
trying again. After granting Accessibility, quit and reopen Frost.

If macOS interrupts input blocking during a lock, Frost shows a warning and
tries to restore it. If blocking can't be restored, the overlay says so and
provides an authentication button. Input may be flowing again, but you still
need to authenticate to dismiss the overlay.

## Use with Shortcuts

Frost includes a **Lock Input** action in the macOS Shortcuts app. Launch Frost
once, then add the action to a shortcut of your own.

To run it from a terminal or script, first save that shortcut with a name such
as “Lock Input,” then run:

```sh
shortcuts run "Lock Input"
```

Shortcuts can start a lock. Unlocking requires authentication in Frost.

## Privacy and updates

Frost has no accounts, telemetry, analytics, or crash reporting. Its only
network activity is checking for and downloading app updates through Sparkle.
Use **Check for Updates…** in the menu to check manually.

See the [changelog](CHANGELOG.md) for what's changed.

## Contributing

For architecture, safety requirements, and build instructions, see
[AGENTS.md](AGENTS.md). Release maintainers should also read
[RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE).
