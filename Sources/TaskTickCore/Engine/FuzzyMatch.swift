import Foundation

/// Case-insensitive subsequence matcher with positional scoring.
///
/// Given query "dlbk" and candidate "daily-backup":
/// - Walks the candidate looking for query characters in order.
/// - "d" matches at index 0, "l" at 3, "b" at 6, "k" at 11.
/// - Returns a score where smaller spans and consecutive matches rank higher,
///   so an exact prefix beats a scattered subsequence.
///
/// Returns `nil` if `query` is not a subsequence of `candidate`.
public enum FuzzyMatch {

    /// Higher score = better match. `nil` means no match.
    public static func score(query: String, candidate: String) -> Int? {
        let q = query.lowercased()
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }

        let qChars = Array(q)
        let cChars = Array(c)
        var qi = 0
        var firstIndex: Int?
        var lastIndex: Int = 0
        var consecutiveBonus = 0
        var prevMatchedAt: Int = -2 // -2 so the first match never counts as consecutive

        for (ci, ch) in cChars.enumerated() {
            guard qi < qChars.count else { break }
            if ch == qChars[qi] {
                if firstIndex == nil { firstIndex = ci }
                lastIndex = ci
                if ci == prevMatchedAt + 1 {
                    consecutiveBonus += 5
                }
                prevMatchedAt = ci
                qi += 1
            }
        }

        guard qi == qChars.count, let first = firstIndex else { return nil }

        // Lower span = tighter match. Cap at 100 so very long names don't dominate.
        let span = min(lastIndex - first, 100)
        // Earlier matches rank higher (matching at the start is ideal).
        let leadingPenalty = min(first, 50)
        // Boost very short candidates so 'foo' > 'foobar' for query 'foo'.
        let lengthPenalty = max(0, cChars.count - qChars.count) / 2

        return 1000 + consecutiveBonus - span - leadingPenalty - lengthPenalty
    }
}
