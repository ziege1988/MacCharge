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

enum Log {
    static func info(_ message: String) {
        NSLog("[MacCharge] %@", message)
    }
}
