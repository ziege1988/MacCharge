import AppKit

/// Einstiegspunkt: MacCharge läuft als "Agent"-App (kein Dock-Symbol)
/// mit einem schwebenden Widget-Fenster und einem Menüleisten-Symbol.
@main
enum MacChargeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
