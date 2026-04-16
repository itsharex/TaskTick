import Foundation

enum AvailableShells {
    static let fallback = ["/bin/zsh", "/bin/bash", "/bin/sh"]

    static func load() -> [String] {
        guard let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else {
            return fallback
        }
        let fm = FileManager.default
        var seen = Set<String>()
        var shells: [String] = []
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard fm.isExecutableFile(atPath: line) else { continue }
            if seen.insert(line).inserted {
                shells.append(line)
            }
        }
        return shells.isEmpty ? fallback : shells
    }

    /// Returns shells guaranteed to contain `selected`, even if /etc/shells omits it.
    static func load(including selected: String) -> [String] {
        var shells = load()
        if !selected.isEmpty, !shells.contains(selected) {
            shells.append(selected)
        }
        return shells
    }
}
