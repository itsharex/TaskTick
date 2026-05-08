import AppKit
import SwiftData
import SwiftUI

/// Custom NSPanel that intercepts keyboard shortcuts the OS would otherwise
/// drop on a borderless-style panel: Escape (cancelOperation) and ⌘W
/// (performClose) both route through the dismiss callback.
final class QuickLauncherPanel: NSPanel {
    var onDismiss: (() -> Void)?

    /// Borderless-styled panels default to non-key, which would prevent the
    /// search field from receiving keystrokes. Force-enable both so the
    /// embedded TextField can take focus and the panel reacts to shortcuts.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}

/// Owns the floating panel that hosts `QuickLauncherView`. Toggles visibility
/// in response to the global hotkey and dismisses on focus loss / Escape.
@MainActor
final class QuickLauncherController: NSObject, NSWindowDelegate {

    static let shared = QuickLauncherController()

    private var panel: QuickLauncherPanel?
    private var modelContainer: ModelContainer?
    /// Most recent time the panel actually became key. Used to ignore the
    /// transient resign-key that fires on cold start when the system briefly
    /// shuffles focus during app activation — without this guard, the panel
    /// flashes open and immediately hides itself.
    private var lastBecameKeyAt: Date?

    /// Stash the container at app boot so `toggle()` can wire SwiftData into the
    /// panel without depending on whoever triggered the hotkey.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Show if hidden, hide if shown. Called from the global hotkey handler.
    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let modelContainer else { return }

        let panel = panel ?? makePanel()
        self.panel = panel

        // Refresh the SwiftUI host every time so the @Query inside re-fetches
        // and the search field's @State resets to empty/index-0. Without this,
        // the panel remembers the previous query and selection.
        let host = NSHostingController(rootView:
            QuickLauncherView(onDismiss: { [weak self] in self?.hide() })
                .modelContainer(modelContainer)
        )
        // `.preferredContentSize` makes the host publish SwiftUI's intrinsic
        // size to the panel — but the panel applies that change with an
        // implicit resize animation. We do the layout manually below and set
        // the panel size pre-show, so this only matters for late-arriving
        // size changes (which we don't care about during the initial flash).
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host

        // Force SwiftUI to compute its real intrinsic size BEFORE we make the
        // panel key. Without this, makeKeyAndOrderFront flashes the panel at
        // its initial 580x200 contentRect, AppKit then animates a resize to
        // SwiftUI's actual size, and during the resize a ghost frame of the
        // content appears below the search bar — the "下拉白卡片" the user
        // reported. Pre-sizing here means the user only ever sees the
        // already-final-size panel.
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        let targetHeight = fitting.height > 0 ? fitting.height : panel.frame.height
        panel.setContentSize(NSSize(width: panelWidth, height: targetHeight))

        // Anchor the TOP of the panel at a fixed screen Y. The SwiftUI view
        // sizes to its content, so panel height varies with how many results
        // are visible — anchoring the top means the search field stays put
        // while the bottom grows downward as the result list fills in.
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let topY = visible.maxY - 150
        let leftX = visible.midX - panelWidth / 2
        panel.setFrameTopLeftPoint(NSPoint(x: leftX, y: topY))

        // Hide-during-init pattern. The gap between makeKeyAndOrderFront
        // and alpha→1 exists because SwiftUI's @FocusState flips inside
        // QuickLauncherView.onAppear, and AppKit's first text-field focus
        // this session spawns CursorUIViewService — an XPC remote view that
        // boots with one frame of default-background paint, leaking through
        // as a "下拉白卡片" beneath the search bar. The pre-warm in
        // QuickLauncherController.prewarmCursorUI (called at app launch)
        // makes the service warm before QL is ever summoned, but on heavily
        // loaded systems that can still take a moment to fully settle.
        // 250ms is the empirical floor at which the flash stays absent
        // across cold-start retries.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            panel.alphaValue = 1.0
        }
    }

    /// Forces `CursorUIViewService` to spawn during app launch by briefly
    /// focusing an offscreen NSTextField. The XPC service is responsible
    /// for cursor / IME / autofill UI and its first-spawn latency is what
    /// causes the "下拉白卡片" flash when our search field gains focus.
    /// Calling this once at launch guarantees the service is warm long
    /// before the user can press the global hotkey.
    func prewarmCursorUI() {
        let window = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.hasShadow = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(field)
        window.contentView = container
        window.orderFrontRegardless()
        window.makeFirstResponder(field)
        // Hold long enough for the XPC service to fully initialize, then
        // tear the warmer down. 600ms is conservative; tested locally the
        // service is hot at ~300ms but slow machines need more headroom.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            window.orderOut(nil)
            // `window` is a local — once this closure ends and the panel is
            // out of the screen, ARC will release it.
        }
    }

    private var panelWidth: CGFloat { QuickLauncherView.cardWidth }

    func hide() {
        lastBecameKeyAt = nil
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.lastBecameKeyAt = Date()
        }
    }

    /// Auto-dismiss when the user clicks outside the panel — classic Spotlight
    /// behavior. Without this the panel sticks around invisibly on top of
    /// whatever the user clicks next.
    ///
    /// On cold start (and sometimes when QL is summoned while another app is
    /// foreground), the focus chain shuffles for a few hundred ms after the
    /// panel first becomes key — the panel resigns key very briefly and the
    /// dismiss-on-resign would fire, hiding the panel just after the user
    /// summoned it. The 300ms grace period filters those transient events
    /// without interfering with deliberate clicks-outside (which only happen
    /// well after the user has had time to see the panel anyway).
    nonisolated func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let last = self.lastBecameKeyAt, Date().timeIntervalSince(last) < 0.3 {
                return
            }
            self.hide()
        }
    }

    // MARK: - Setup

    private func makePanel() -> QuickLauncherPanel {
        // Borderless on purpose: `.titled + .fullSizeContentView` (the
        // SwiftUI-friendly default) keeps an `NSThemeFrame` titlebar layer
        // around even with `titlebarAppearsTransparent`. On macOS 26.x that
        // titlebar layer briefly ignores the window's alphaValue during
        // initial reveal, painting a default-background frame *under* the
        // SwiftUI content — exactly the "下拉白卡片" the user kept seeing.
        // Going borderless eliminates the offending layer entirely.
        // SwiftUI's own `.clipShape(RoundedRectangle)` handles the rounded
        // corners, and `panel.hasShadow = true` still gives us native shadow.
        let panel = QuickLauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Let SwiftUI's clipShape handle the rounded corners; no layer hacks
        // on contentView (those leaked an outer rounded "frame" behind the
        // SwiftUI card when the panel was bigger than the content).
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Kill AppKit's default window-appearing animation. Without this,
        // makeKeyAndOrderFront pops the panel in with a scale animation that
        // renders one frame using the panel's default (white) background
        // before SwiftUI's content paints — visible as a "下拉白卡片"
        // ghost flash beneath the search bar. We do our own alpha 0→1
        // transition in show(), so AppKit's animation is pure liability.
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.hide() }
        return panel
    }

}
