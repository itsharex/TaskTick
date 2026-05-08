import Foundation

/// Minimal column-aligned table renderer (no third-party dep). Computes column
/// widths from content, prints header in caps, single-line rows.
enum TableRenderer {
    static func render(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }
        var widths = headers.map { $0.displayWidth }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.displayWidth)
            }
        }

        func formatRow(_ cells: [String]) -> String {
            zip(cells, widths)
                .map { cell, w in cell.padToDisplayWidth(w) }
                .joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }

        var lines: [String] = [formatRow(headers)]
        for row in rows {
            // Pad short rows with empty strings to match column count.
            var padded = row
            while padded.count < headers.count { padded.append("") }
            lines.append(formatRow(padded))
        }
        return lines.joined(separator: "\n")
    }
}

private extension Character {
    /// Estimated terminal display width in cells (1 or 2). Covers the
    /// common East Asian Wide / Fullwidth ranges + most emoji. `count` /
    /// UTF-16 code units would under-count CJK glyphs which occupy 2 cells.
    var displayWidth: Int {
        for scalar in unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs + Compat + Extensions, Hangul, kana, fullwidth, emoji.
            if (0x1100...0x115F).contains(v)            // Hangul Jamo
                || (0x2E80...0x303E).contains(v)         // CJK Radicals, Kangxi Radicals
                || (0x3041...0x33FF).contains(v)         // Hiragana, Katakana, CJK Symbols
                || (0x3400...0x4DBF).contains(v)         // CJK Extension A
                || (0x4E00...0x9FFF).contains(v)         // CJK Unified Ideographs
                || (0xA000...0xA4CF).contains(v)         // Yi
                || (0xAC00...0xD7A3).contains(v)         // Hangul Syllables
                || (0xF900...0xFAFF).contains(v)         // CJK Compatibility Ideographs
                || (0xFE30...0xFE4F).contains(v)         // CJK Compat Forms
                || (0xFF00...0xFF60).contains(v)         // Fullwidth ASCII
                || (0xFFE0...0xFFE6).contains(v)         // Fullwidth signs
                || (0x1F300...0x1F64F).contains(v)       // Misc Symbols & Pictographs + Emoticons
                || (0x1F680...0x1F6FF).contains(v)       // Transport & Map
                || (0x1F900...0x1F9FF).contains(v)       // Supplemental Symbols & Pictographs
                || (0x20000...0x3FFFD).contains(v) {     // CJK Extensions B-F
                return 2
            }
        }
        return 1
    }
}

private extension String {
    var displayWidth: Int {
        reduce(0) { $0 + $1.displayWidth }
    }

    func padToDisplayWidth(_ targetWidth: Int) -> String {
        let need = targetWidth - displayWidth
        return need > 0 ? self + String(repeating: " ", count: need) : self
    }
}
