import Foundation

/// Per-task "most recently launched" timestamps. Stored in UserDefaults so the
/// ranking survives across app launches without dragging SwiftData migrations
/// in for an ephemeral concern. The launcher reads this map at sort time to
/// surface the user's frequently-triggered tasks at the top.
@MainActor
enum QuickLauncherUsage {
    private static let key = "quickLauncher.lastUsed.v1"

    /// Mark a task as just launched from the quick launcher. Called from the
    /// run / restart actions — *not* from scheduled runs, since automatic
    /// triggers shouldn't bump a task's MRU rank.
    static func markUsed(_ taskID: UUID) {
        var dict = readDictionary()
        dict[taskID.uuidString] = Date().timeIntervalSinceReferenceDate
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func lastUsed(_ taskID: UUID) -> Date? {
        let dict = readDictionary()
        guard let interval = dict[taskID.uuidString] else { return nil }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    /// Stored as `[String: Double]` (TimeIntervalSinceReferenceDate) instead of
    /// `[String: Date]` because UserDefaults dictionary readback bridges
    /// inconsistently between Date and NSDate across Swift versions. Doubles
    /// are unambiguous.
    private static func readDictionary() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}
