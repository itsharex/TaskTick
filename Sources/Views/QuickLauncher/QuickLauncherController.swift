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
        panel.contentViewController = host

        // Lock width to match the SwiftUI `.frame(width: 580)` so the panel
        // and its content agree. Without this the panel keeps the initial
        // contentRect width and ends up offset from horizontal center.
        panel.setContentSize(NSSize(width: panelWidth, height: panel.frame.height))

        // Anchor the TOP of the panel at a fixed screen Y. The SwiftUI view
        // sizes to its content, so panel height varies with how many results
        // are visible — anchoring the top means the search field stays put
        // while the bottom grows downward as the result list fills in.
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let topY = visible.maxY - 150
        let leftX = visible.midX - panelWidth / 2
        panel.setFrameTopLeftPoint(NSPoint(x: leftX, y: topY))

        // Hide-during-layout pattern to kill the size-flash:
        // 1. alpha=0 + show invisible
        // 2. force SwiftUI to compute final intrinsic size NOW (sync layout)
        // 3. flip alpha to 1 after the layout has settled
        // Without the explicit `layoutSubtreeIfNeeded`, the panel renders at
        // its initial 200pt height for one frame before SwiftUI's intrinsic
        // size kicks in, and the user sees a tiny stub card flash.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            panel.alphaValue = 1.0
        }
    }

    private var panelWidth: CGFloat { QuickLauncherView.cardWidth }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// Auto-dismiss when the user clicks outside the panel — classic Spotlight
    /// behavior. Without this the panel sticks around invisibly on top of
    /// whatever the user clicks next.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.hide()
        }
    }

    // MARK: - Setup

    private func makePanel() -> QuickLauncherPanel {
        // `.titled` + `.fullSizeContentView` lets SwiftUI draw all the way to
        // the panel's top edge (so no dead band) AND inherit the native macOS
        // window shadow — way nicer than painting a SwiftUI shadow ourselves.
        // `.nonactivatingPanel` keeps the app in accessory mode so calling
        // the launcher doesn't restore the main window.
        let panel = QuickLauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
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
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.hide() }
        return panel
    }

}
