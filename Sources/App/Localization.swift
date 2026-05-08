import Foundation
import SwiftUI
import TaskTickCore

/// Observable language manager that triggers SwiftUI re-renders on language change.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Bump this to force SwiftUI views to re-compute L10n.tr() calls.
    @Published var revision: Int = 0

    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "appLanguage")
            L10n.reloadBundle(for: current)
            revision += 1
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let lang = AppLanguage(rawValue: saved) ?? .system
        self.current = lang
        L10n.reloadBundle(for: lang)
    }
}

/// View modifier that forces re-render when language changes.
struct LocalizedView: ViewModifier {
    @ObservedObject private var lm = LanguageManager.shared

    func body(content: Content) -> some View {
        content
            .id(lm.revision) // Force rebuild entire view tree on language change
    }
}

extension View {
    /// Apply this to top-level views to make them respond to language changes.
    func localized() -> some View {
        modifier(LocalizedView())
    }
}
