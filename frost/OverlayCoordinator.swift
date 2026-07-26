//
//  OverlayCoordinator.swift
//  frost
//
//  Owns the borderless overlay windows — one per display, each joining all
//  Spaces, so the dim covers every desktop and monitor. Rebuilt on display
//  changes. Content is placed inside each screen's safe area so the central
//  affordance does not sit under a notched display housing.
//
//  The key window lives on the ACTIVE display — the one the pinned cursor is on,
//  i.e. where the lock was triggered — not always the menu-bar display, so the
//  system Touch ID prompt appears where the user is looking when locking from a
//  secondary monitor.
//
//  The overlay is intentionally semi-transparent: Frost keeps the display
//  VISIBLE while input is locked, so you can watch whatever is running.
//

import AppKit
import os
import SwiftUI

/// LockController's seam onto the overlay windows, so the lock state machine
/// can be tested without creating real NSWindows on every display.
@MainActor
protocol OverlayPresenting: AnyObject {
    @discardableResult
    func present(controller: LockController, level: NSWindow.Level) -> Bool
    func focusAuthenticationWindow()
    func dismiss()
    func rebuildIfDeferred()
}

@MainActor
final class OverlayCoordinator: NSObject, OverlayPresenting {
    private var windows: [NSWindow] = []
    private let log = Logger(subsystem: "dev.abdeen.frost", category: "Overlay")
    /// Index into `windows` of the active-display window: it becomes key so the
    /// system Touch ID prompt is focused on the display where the user is.
    /// Recomputed on every rebuild.
    private var authenticationWindowIndex = 0
    private weak var controller: LockController?
    /// Set when a screen-parameters change arrives mid-authentication. Rebuilding
    /// recreates every overlay window, which would churn focus out from under the
    /// live system Touch ID prompt, so the rebuild is deferred until Frost returns
    /// to the idle locked state (see `rebuildIfDeferred`).
    private var needsRebuildAfterAuth = false
    /// Window level for the current presentation, remembered across rebuilds.
    /// `.screenSaver` while input is genuinely locked. Recovery overlays (input
    /// NOT locked) sit at `.floating` so system dialogs — above all the
    /// Accessibility (TCC) consent prompt that a failed `lock()` may have just
    /// triggered — appear above the overlay instead of being buried and
    /// click-blocked beneath it.
    private var level: NSWindow.Level = .screenSaver

    deinit {
        MainActor.assumeIsolated {
            dismiss()
        }
    }

    /// Returns false when no overlay window could be created (no screens), so
    /// the caller can refuse to enter a lock that would suppress input with
    /// nothing on screen to explain it.
    @discardableResult
    func present(controller: LockController, level: NSWindow.Level = .screenSaver) -> Bool {
        self.controller = controller
        self.level = level
        rebuild()
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        show()
        log.info("Overlay presented on \(self.windows.count, privacy: .public) display(s)")
        return !windows.isEmpty
    }

    private func show() {
        guard !windows.isEmpty else { return }
        let keyIndex = min(max(authenticationWindowIndex, 0), windows.count - 1)
        // Order the non-key windows first, then key the active-display window
        // last so it ends up frontmost and focused.
        for (index, window) in windows.enumerated() where index != keyIndex {
            window.orderFrontRegardless()
        }
        windows[keyIndex].makeKeyAndOrderFront(nil)
    }

    /// Bring Frost forward and re-key the active-display window. Frost is an
    /// LSUIElement agent, so it isn't active when the overlay is first presented
    /// on a fresh launch and the lock-time `makeKeyAndOrderFront` doesn't stick.
    /// Called when authentication is armed so the app is active — letting the
    /// system Touch ID prompt take focus — with the active-display window keyed so
    /// the prompt is biased onto the display where the lock was triggered.
    func focusAuthenticationWindow() {
        // Activate FIRST, before the empty-window bail-out. Frost is an
        // LSUIElement agent, so without this the system authentication prompt
        // cannot take focus — and an empty window set is exactly when the user
        // has no other affordance left.
        NSApp.activate(ignoringOtherApps: true)
        guard !windows.isEmpty else { return }
        let keyIndex = min(max(authenticationWindowIndex, 0), windows.count - 1)
        windows[keyIndex].makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        needsRebuildAfterAuth = false
        controller = nil
        log.info("Overlay dismissed")
    }

    /// What a screen-parameters change should do. Pure: rebuilding mid-auth
    /// churns focus out from under the live Touch ID prompt, so it must defer.
    enum ScreenChangeAction: Equatable {
        case ignore              // nothing presented at all: nothing to do
        case deferUntilAuthEnds  // live Touch ID prompt: rebuild later
        case rebuild
    }

    /// Keyed on whether a controller is still PRESENTED, not on whether windows
    /// currently exist. `rebuild()` repopulates from `NSScreen.screens`, so a
    /// display reconfiguration that momentarily reports zero screens leaves the
    /// window set empty — and keying on `hasWindows` made that state permanent:
    /// every later screen change took `.ignore`, so the overlay never came back
    /// while the tap kept suppressing input with nothing on screen.
    static func screenChangeAction(isPresented: Bool, isAuthenticating: Bool) -> ScreenChangeAction {
        guard isPresented else { return .ignore }
        return isAuthenticating ? .deferUntilAuthEnds : .rebuild
    }

    static func shouldApplyDeferredRebuild(needsRebuildAfterAuth: Bool, isPresented: Bool) -> Bool {
        needsRebuildAfterAuth && isPresented
    }

    @objc private func screenParametersChanged() {
        // Never rebuild while a Touch ID evaluation is live: rebuild() recreates
        // every overlay window, churning focus out from under the system prompt.
        // Hiding the menu bar for kiosk mode (at lock) and display sleep/wake
        // (after idle) both fire this notification right when the first prompt is
        // up. Defer the rebuild until authentication ends.
        switch Self.screenChangeAction(
            isPresented: controller != nil, isAuthenticating: controller?.isAuthenticating == true
        ) {
        case .ignore:
            return
        case .deferUntilAuthEnds:
            needsRebuildAfterAuth = true
            log.info("Screen parameters changed during auth; deferring overlay rebuild")
        case .rebuild:
            rebuild()
            show()
        }
    }

    /// Apply a rebuild that was deferred because the screen-parameters change
    /// arrived mid-authentication. Called by `LockController` when it returns to
    /// the idle locked state, so the overlay still picks up any real display
    /// change that happened while the prompt was up.
    func rebuildIfDeferred() {
        guard Self.shouldApplyDeferredRebuild(
            needsRebuildAfterAuth: needsRebuildAfterAuth, isPresented: controller != nil
        ) else { return }
        needsRebuildAfterAuth = false
        log.info("Applying overlay rebuild deferred during auth")
        rebuild()
        show()
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard let controller else { return }
        let screens = NSScreen.screens
        authenticationWindowIndex = Self.activeScreenIndex(in: screens)
        for screen in screens {
            windows.append(makeWindow(for: screen, controller: controller))
        }
    }

    /// The display the user is on — where the lock was triggered. The cursor is
    /// pinned for the whole session, so its location stays on the lock-time
    /// display and the keyed window follows it across rebuilds. Falls back to the
    /// main screen, then the first screen, if the cursor isn't on any screen.
    private static func activeScreenIndex(in screens: [NSScreen]) -> Int {
        activeScreenIndex(
            frames: screens.map(\.frame),
            mouse: NSEvent.mouseLocation,
            mainIndex: NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        )
    }

    /// Pure core of active-display selection: the display the mouse is on, else
    /// the main display, else the first. `mainIndex` is NSScreen.main's index in
    /// the same array (nil when unknown).
    static func activeScreenIndex(frames: [CGRect], mouse: CGPoint, mainIndex: Int?) -> Int {
        guard !frames.isEmpty else { return 0 }
        if let index = frames.firstIndex(where: { $0.contains(mouse) }) {
            return index
        }
        if let mainIndex, frames.indices.contains(mainIndex) {
            return mainIndex
        }
        return 0
    }

    private func makeWindow(
        for screen: NSScreen,
        controller: LockController
    ) -> NSWindow {
        let window = OverlayWindow(contentRect: screen.frame,
                                   styleMask: .borderless,
                                   backing: .buffered,
                                   defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false   // recovery buttons must be clickable
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LockOverlayView(
            controller: controller,
            safeAreaInsets: screen.safeAreaInsets.swiftUIInsets
        ))
        window.setFrame(screen.frame, display: true)
        return window
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSEdgeInsets {
    var swiftUIInsets: EdgeInsets {
        EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right)
    }
}

// MARK: - Overlay UI

struct LockOverlayView: View {
    @ObservedObject var controller: LockController
    var safeAreaInsets: EdgeInsets
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // Scale the card width with Dynamic Type so large accessibility text sizes
    // have room to wrap instead of clipping against a hard-coded width.
    @ScaledMetric private var cardWidth: CGFloat = 430

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(
                280,
                proxy.size.width - safeAreaInsets.leading - safeAreaInsets.trailing - 32
            )
            let availableHeight = max(
                200,
                proxy.size.height - safeAreaInsets.top - safeAreaInsets.bottom - 32
            )

            ZStack {
                // A stronger scrim (paired with an opaque card) when the user has
                // asked to reduce transparency, so text stays legible over a busy
                // desktop showing through.
                //
                // In recovery, input is NOT locked and the card says so — but the
                // scrim is a full-screen hit-testable surface on every display and
                // every Space, so without this every click outside the card would
                // land here and do nothing, contradicting the card's own message.
                // Clicks fall through to the app underneath instead; the card's
                // own buttons keep working because they sit above this layer.
                Color.black.opacity(reduceTransparency ? 0.6 : 0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(!isRecovery)
                card(maxWidth: availableWidth, maxHeight: availableHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(safeAreaInsets)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isRecovery: Bool {
        if case .recovery = controller.state { return true }
        return false
    }

    @ViewBuilder private func card(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        switch controller.state {
        case .recovery(let recovery):
            recoveryCard(recovery, width: min(cardWidth + 10, maxWidth))
                .frame(maxHeight: maxHeight)
        default:
            lockedCard(width: min(cardWidth, maxWidth))
                .frame(maxHeight: maxHeight)
        }
    }

    private var authenticating: Bool { controller.state == .authenticating }

    /// With Watch unlock enabled the preflight accepts a paired Watch instead of
    /// a fingerprint, so a Mac with no Touch ID sensor at all can be locked.
    /// Naming Touch ID exclusively would leave that user staring at a fingerprint
    /// glyph with no idea the Watch side-button double-press is what dismisses
    /// the system dialog.
    private var authenticationSymbol: String {
        controller.allowsWatchUnlock ? "applewatch" : "touchid"
    }

    private var authenticationInstruction: String {
        controller.allowsWatchUnlock
            ? "Respond with Touch ID, or double-press your Apple Watch side button. Press Esc to cancel and keep input locked."
            : "Respond to the Touch ID prompt. Press Esc to cancel and keep input locked."
    }

    private func lockedCard(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                authenticationMark

                VStack(alignment: .leading, spacing: 4) {
                    Text(authenticating ? "Authenticate" : "Input Locked")
                        .font(.title2.weight(.semibold))
                    Text(authenticating
                         ? controller.unlockMethodLabel
                         : "Keyboard, mouse, and trackpad input are paused")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if authenticating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(24)

            Divider()
                .padding(.horizontal, 24)

            VStack(spacing: 16) {
                if authenticating {
                    authenticatingPrompt
                } else {
                    unlockPrompt
                }

                if !controller.lockMessage.isEmpty {
                    // Capped deliberately. The message is owner-supplied free
                    // text and everything below it here — the safety strip, the
                    // tap-recovery warning, the DEBUG countdown — plus the
                    // unlock-shortcut hint above it are the affordances the user
                    // needs while input is suppressed. An uncapped message grows
                    // the centred card past both screen edges and pushes them out
                    // of view, and a locked user cannot scroll it back (scroll
                    // events are swallowed) or reach another app (Force Quit is
                    // disabled). Truncating the message is the recoverable
                    // failure; losing the unlock hint is not.
                    Text(controller.lockMessage)
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                safetyStrip

                if controller.inputSuppressionFailed, !authenticating {
                    // The unlock chord lived inside the event tap that just
                    // died, so this button is the only remaining route to the
                    // prompt. Frost holds the lock until it succeeds.
                    Button {
                        controller.authenticateFromOverlay()
                    } label: {
                        Label("Unlock with \(controller.unlockMethodLabel)",
                              systemImage: authenticationSymbol)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }

                if let notice = controller.secureInputNotice {
                    warningText(notice)
                }

                if let notice = controller.tapRecoveryNotice {
                    warningText(notice)
                }

                #if DEBUG
                if let seconds = controller.debugSecondsRemaining {
                    warningText("DEBUG auto-unlock in \(seconds)s", font: .footnote.monospacedDigit())
                }
                #endif
            }
            .padding(24)
        }
        .frame(width: width)
        .background(cardBackground(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 32, y: 18)
        .accessibilityElement(children: .contain)
    }

    /// Card fill: translucent material normally, but an opaque solid when the
    /// user has reduced transparency, so legibility never depends on the desktop
    /// showing through behind the text.
    ///
    /// The opaque fill MUST follow the system appearance. Every string on this
    /// card uses `.primary`/`.secondary`, which resolve to near-black in Light
    /// Mode; a hard-coded black fill put black text on a black card — unreadable
    /// in exactly the accessibility setting whose purpose is legibility.
    /// `.windowBackgroundColor` is near-white in Light Mode and near-black in
    /// Dark, so the label colors keep their intended contrast in both.
    @ViewBuilder
    private func cardBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    // Appearance-aware substitutes for what used to be hard-coded translucent
    // white. `.ultraThinMaterial` resolves LIGHT in Light Mode, so white-on-white
    // separators, panel fills and pill capsules vanished there and the card
    // dissolved into unbounded text over the desktop. `Color.primary` inverts
    // with the appearance, so a low-opacity tint reads in both modes.
    private var hairline: Color { Color.primary.opacity(0.15) }
    private var panelFill: Color { Color.primary.opacity(0.06) }

    private var authenticationMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(authenticating ? 0.12 : 0.08))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(hairline, lineWidth: 1)
            Image(systemName: authenticating ? authenticationSymbol : "lock.fill")
                .font(.system(size: authenticating ? 36 : 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(authenticating ? Color.accentColor : Color.primary)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private var unlockPrompt: some View {
        HStack(spacing: 14) {
            keycap(controller.unlockShortcutDisplay)

            VStack(alignment: .leading, spacing: 3) {
                Text("Unlock Shortcut")
                    .font(.headline)
                Text("Press to open the \(controller.unlockMethodLabel) prompt")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Unlock shortcut: \(controller.unlockShortcutSpoken). Press to open the \(controller.unlockMethodLabel) prompt.")
    }

    private var authenticatingPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: authenticationSymbol)
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text(authenticationInstruction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var safetyStrip: some View {
        HStack(spacing: 8) {
            statusPill(icon: "keyboard", text: "Input paused")
            statusPill(icon: "cursorarrow", text: "Pointer frozen")
            // The unlock method, not "Secured": Frost is not a security product
            // and must never present itself as one (AGENTS.md framing rule).
            statusPill(icon: authenticationSymbol, text: controller.unlockMethodLabel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Input paused, pointer frozen.")
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .frame(minWidth: 106, minHeight: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hairline, lineWidth: 1)
            }
    }

    private func statusPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(panelFill, in: Capsule())
    }

    // A filled banner with dark text, so the warning meets contrast over any
    // desktop and regardless of reduce-transparency — yellow text on translucent
    // material did not.
    private func warningText(_ message: String, font: Font = .footnote) -> some View {
        Text(message)
            .font(font.weight(.medium))
            .foregroundStyle(.black)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func recoveryCard(_ recovery: RecoveryState, width: CGFloat) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(recovery.title)
                .font(.title2.weight(.semibold))
            Text(recovery.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Promote the primary action and push the destructive Quit to the
            // trailing edge so the button hierarchy is unambiguous.
            ViewThatFits(in: .horizontal) {
                recoveryButtons(recovery)
                stackedRecoveryButtons(recovery)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: width)
        .background(cardBackground(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    /// The recovery actions, defined once so the two layouts can never offer a
    /// different button set. Only the ORDER varies by axis, because the two axes
    /// have opposite conventions: macOS puts the default action at the trailing
    /// edge of a row (cancel to its left) and at the TOP of a stack.
    ///
    /// The row previously emitted [default] [secondary] —— [Dismiss], so the
    /// rightmost slot — the one a user reaches for reflexively — was Dismiss. In
    /// the Accessibility recovery, that is precisely the state where dismissing
    /// instead of opening System Settings leaves the user with nothing.
    @ViewBuilder
    private func recoveryActions(_ recovery: RecoveryState, axis: Axis) -> some View {
        switch axis {
        case .horizontal:
            dismissAction
            Spacer(minLength: 0)
            secondaryAction(recovery)
            prominentAction(recovery)
        case .vertical:
            prominentAction(recovery)
            secondaryAction(recovery)
            dismissAction
        }
    }

    @ViewBuilder
    private func prominentAction(_ recovery: RecoveryState) -> some View {
        if recovery.showsAccessibilitySettings {
            Button("Open Privacy Settings") { controller.openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else if recovery.allowsRetry {
            Button("Try Again") { controller.retryRecovery() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func secondaryAction(_ recovery: RecoveryState) -> some View {
        if recovery.showsAccessibilitySettings {
            Button("Quit & Reopen Frost") { controller.quitAndReopenFrost() }
        }
    }

    private var dismissAction: some View {
        Button("Dismiss") { controller.dismissRecovery() }
            .keyboardShortcut(.cancelAction)
    }

    private func recoveryButtons(_ recovery: RecoveryState) -> some View {
        HStack(spacing: 12) { recoveryActions(recovery, axis: .horizontal) }
    }

    private func stackedRecoveryButtons(_ recovery: RecoveryState) -> some View {
        VStack(spacing: 10) { recoveryActions(recovery, axis: .vertical) }
    }
}
