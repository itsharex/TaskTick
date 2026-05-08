import Foundation

/// Minimal column-aligned table renderer (no third-party dep). Computes column
/// widths from content, prints header in caps, single-line rows.
enum TableRenderer {
    static func render(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        func formatRow(_ cells: [String]) -> String {
            zip(cells, widths)
                .map { cell, w in cell.padding(toLength: w, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
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
