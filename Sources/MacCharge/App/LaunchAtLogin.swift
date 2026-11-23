import Foundation
import ServiceManagement

/// Autostart beim Anmelden.
/// Primär über SMAppService (macOS 13+). Da MacCharge ohne kostenpflichtiges
/// Apple-Entwicklerzertifikat (nur ad-hoc) signiert ist, wird zusätzlich ein
/// LaunchAgent als Rückfallebene unterstützt.
enum LaunchAtLogin {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/io.github.ziege1988.maccharge.plist")
    }

    static func apply(_ enabled: Bool) {
        if enabled { enable() } else { disable() }
    }

    private static func enable() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("SMAppService fehlgeschlagen (\(error.localizedDescription)) – nutze LaunchAgent")
        }
        if SMAppService.mainApp.status == .enabled {
            try? FileManager.default.removeItem(at: agentURL)
        } else {
            writeLaunchAgent()
        }
    }

    private static func disable() {
        try? SMAppService.mainApp.unregister()
        try? FileManager.default.removeItem(at: agentURL)
    }

    private static func writeLaunchAgent() {
        let appPath = Bundle.main.bundlePath
        let plist: [String: Any] = [
            "Label": "io.github.ziege1988.maccharge",
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
        } catch {
            Log.info("LaunchAgent konnte nicht geschrieben werden: \(error.localizedDescription)")
        }
    }
}
