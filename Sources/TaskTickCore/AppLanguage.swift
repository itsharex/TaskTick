import Foundation

/// Supported app languages.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case es = "es"
    case ru = "ru"
    case id = "id"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System / 跟随系统"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .it: "Italiano"
        case .es: "Español"
        case .ru: "Русский"
        case .id: "Bahasa Indonesia"
        }
    }

    /// Resolve the actual language code (for .system, detect from system preferences).
    public var resolvedCode: String {
        switch self {
        case .system:
            for lang in Locale.preferredLanguages {
                // Traditional Chinese detection (zh-Hant, zh-TW, zh-HK)
                if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
                    return "zh-Hant"
                }
                if lang.hasPrefix("zh") { return "zh-Hans" }
                if lang.hasPrefix("en") { return "en" }
                if lang.hasPrefix("ja") { return "ja" }
                if lang.hasPrefix("ko") { return "ko" }
                if lang.hasPrefix("fr") { return "fr" }
                if lang.hasPrefix("de") { return "de" }
                if lang.hasPrefix("it") { return "it" }
                if lang.hasPrefix("es") { return "es" }
                if lang.hasPrefix("ru") { return "ru" }
                if lang.hasPrefix("id") || lang.hasPrefix("ms") { return "id" }
            }
            return "en"
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .it: return "it"
        case .es: return "es"
        case .ru: return "ru"
        case .id: return "id"
        }
    }
}
