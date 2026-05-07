import AppKit
import SwiftUI

// Pillow-shaped non-activating overlay for transient feedback. Adapted from
// the FileLens / ShotMemo / PasteMemo pattern so all our apps share the look.

// MARK: - Descriptor

struct ToastDescriptor: Equatable {
    let message: String
    let icon: ToastIcon
    /// Auto-dismiss interval. Nil = sticky (caller must dismiss manually).
    let duration: TimeInterval?

    init(message: String, icon: ToastIcon = .none, duration: TimeInterval? = 1.6) {
        self.message = message
        self.icon = icon
        self.duration = duration
    }
}

enum ToastIcon: Equatable {
    case none, success, info, error, running, stopped, restart

    var systemImageName: String? {
        switch self {
        case .none: nil
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .running: "play.circle.fill"
        case .stopped: "stop.circle.fill"
        case .restart: "arrow.clockwise.circle.fill"
        }
    }

    func tint(isDark: Bool) -> Color {
        switch self {
        case .none: .clear
        case .success: Color(red: 0.13, green: 0.63, blue: 0.35)
        case .info: isDark ? Color(red: 0.50, green: 0.73, blue: 1.00) : Color(red: 0.00, green: 0.31, blue: 0.78)
        case .error: Color(red: 0.90, green: 0.35, blue: 0.30)
        case .running: Color(red: 0.20, green: 0.55, blue: 0.95)
        case .stopped: Color(red: 0.85, green: 0.35, blue: 0.30)
        case .restart: Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }
}

// MARK: - View

struct ToastView: View {
    let descriptor: ToastDescriptor

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 10) {
            if let name = descriptor.icon.systemImageName {
                Image(systemName: name)
                    .font(.system(size: 14))
                    .foregroundStyle(descriptor.icon.tint(isDark: isDark))
            }
            Text(descriptor.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(panelFill)
                .shadow(color: shadowColor, radius: 18, y: 6)
                .shadow(color: shadowColor.opacity(0.5), radius: 4, y: 1)
        )
        .overlay(Capsule().stroke(panelStroke, lineWidth: 0.5))
        .fixedSize()
    }

    private var panelFill: Color {
        isDark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.99, green: 0.99, blue: 0.98)
    }
    private var panelStroke: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
    private var textColor: Color {
        isDark ? Color(red: 0.93, green: 0.93, blue: 0.94) : Color(red: 0.08, green: 0.09, blue: 0.11)
    }
    private var shadowColor: Color {
        isDark ? Color.black.opacity(0.48) : Color.black.opacity(0.14)
    }
}

// MARK: - Center

@MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    private var panel: NSPanel?
    private let state = ToastCenterState()
    private var autoDismissTask: Task<Void, Never>?
    private var tearDownTask: Task<Void, Never>?

    private static let canvasSize = NSSize(width: 520, height: 160)

    func show(_ descriptor: ToastDescriptor) {
        autoDismissTask?.cancel()
        tearDownTask?.cancel()
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()

        withAnimation(.spring(response: 0.48, dampingFraction: 0.7)) {
            state.current = descriptor
        }

        if let duration = descriptor.duration {
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.dismiss() }
            }
        }
    }

    func success(_ message: String) { show(ToastDescriptor(message: message, icon: .success)) }
    func info(_ message: String)    { show(ToastDescriptor(message: message, icon: .info)) }
    func error(_ message: String)   { show(ToastDescriptor(message: message, icon: .error)) }
    func running(_ message: String) { show(ToastDescriptor(message: message, icon: .running)) }
    func stopped(_ message: String) { show(ToastDescriptor(message: message, icon: .stopped)) }
    func restart(_ message: String) { show(ToastDescriptor(message: message, icon: .restart)) }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard state.current != nil else { return }
        withAnimation(.easeIn(duration: 0.26)) { state.current = nil }
        tearDownTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state.current == nil else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// Hide & release the floating panel before app termination. The panel's
    /// collectionBehavior spans every Space; if WindowServer has to clean up
    /// after a SIGKILL, you see a one-frame full-screen redraw flash. Tearing
    /// down while the app is still alive avoids that flash.
    func tearDownForTermination() {
        autoDismissTask?.cancel()
        tearDownTask?.cancel()
        state.current = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func ensurePanel() {
        if panel != nil { return }
        let host = NSHostingView(rootView: ToastHost(state: state))
        host.frame = NSRect(origin: .zero, size: Self.canvasSize)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isExcludedFromWindowsMenu = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.contentView = host
        panel = p
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let restingBottom = visible.minY + 72
        let y = restingBottom - ToastHost.bottomInset
        let x = visible.midX - Self.canvasSize.width / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class ToastCenterState: ObservableObject {
    @Published var current: ToastDescriptor?
}

struct ToastHost: View {
    static let bottomInset: CGFloat = 56
    @ObservedObject var state: ToastCenterState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let descriptor = state.current {
                ToastView(descriptor: descriptor)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(descriptor.message)
            }
            Color.clear.frame(height: Self.bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
