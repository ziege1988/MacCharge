import AppKit

enum AppInfo {
    static let name = "MacCharge"

    /// GitHub-Repository, aus dem Updates (Releases) geladen werden.
    static let repoOwner = "ziege1988"
    static let repoName = "MacCharge"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Logo aus dem App-Bundle (Contents/Resources/Logo.png).
    static var logo: NSImage {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: name) ?? NSImage()
    }
}

/// Protokoll: Unified Log + Datei ~/Library/Logs/MacCharge/MacCharge.log (max. ~1 MB, danach .old).
/// Wird synchron geschrieben, damit auch Einträge kurz vor dem Herunterfahren sicher auf der Platte landen.
enum Log {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacCharge/MacCharge.log")
    private static let queue = DispatchQueue(label: "maccharge.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ message: String) {
        NSLog("[MacCharge] %@", message)
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 1_000_000 {
                let old = fileURL.appendingPathExtension("old")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.synchronize()
                try? handle.close()
            }
        }
    }

    /// Letzte Zeilen des Protokolls (für „Kopieren“ in den Einstellungen).
    static func tail(_ count: Int = 80) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "(Protokoll ist leer)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }
}
