import AppKit
import SwiftUI

/// Aktionen des Power-Widgets.
enum PowerAction: String, CaseIterable, Identifiable {
    case shutdown, restart, logout, sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shutdown: return "Aus"
        case .restart: return "Neustart"
        case .logout: return "Abmelden"
        case .sleep: return "Ruhe"
        }
    }

    var icon: String {
        switch self {
        case .shutdown: return "power"
        case .restart: return "arrow.clockwise"
        case .logout: return "rectangle.portrait.and.arrow.right"
        case .sleep: return "moon.fill"
        }
    }

    var verb: String {
        switch self {
        case .shutdown: return "Fährt herunter"
        case .restart: return "Startet neu"
        case .logout: return "Meldet ab"
        case .sleep: return "Schläft ein"
        }
    }
}

/// Führt Herunterfahren / Neustart / Abmelden / Ruhezustand aus – vorher wird die Steckdose
/// abgeschaltet und auf den Kurzbefehl gewartet. Hält außerdem den gemeinsamen Abschaltvorgang
/// beim Herunterfahren, damit ein Umschalt-Kurzbefehl nie doppelt ausgeführt wird.
@MainActor
final class PowerActionController: ObservableObject {
    /// Erster Klick „scharf“ stellen, zweiter Klick ausführen (Schutz vor Versehen).
    @Published private(set) var armed: PowerAction?
    @Published private(set) var running: PowerAction?
    @Published private(set) var status: String?

    /// Gemeinsamer Abschaltvorgang (Power-Widget, Menü und macOS-Herunterfahren).
    private(set) var shutdownTask: Task<Void, Never>?

    private let settings: AppSettings
    private let charger: ChargeController
    private var disarmWork: DispatchWorkItem?

    init(settings: AppSettings, charger: ChargeController) {
        self.settings = settings
        self.charger = charger
    }

    /// Klick auf einen Button im Power-Widget.
    func tap(_ action: PowerAction) {
        guard running == nil else { return }
        if settings.powerConfirm && armed != action {
            armed = action
            disarmWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.armed = nil }
            disarmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }
        armed = nil
        perform(action)
    }

    func perform(_ action: PowerAction) {
        guard running == nil else { return }
        running = action
        Log.info("Power-Widget: \(action.title)")

        Task { @MainActor in
            if action == .sleep {
                // Ruhezustand: Abschalten übernimmt die Ruhezustand-Überwachung (inkl. Untergrenzen-Regel)
                self.status = action.verb + " …"
            } else {
                self.status = "Strom aus …"
                self.startShutdownSwitchOff(trigger: action.title)
                await self.shutdownTask?.value
                self.status = action.verb + " …"
            }

            if let error = Self.execute(action) {
                Log.info("\(action.title) fehlgeschlagen: \(error)")
                self.status = nil
                self.running = nil
                self.shutdownTask = nil
                let alert = NSAlert()
                alert.messageText = "„\(action.title)“ konnte nicht ausgeführt werden"
                alert.informativeText = "Bitte MacCharge unter Systemeinstellungen → Datenschutz & Sicherheit → Automation erlauben, „System Events“ zu steuern.\n\n\(error)"
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            } else if action == .sleep {
                // Nach dem Aufwachen wieder bedienbar
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.running = nil
                    self?.status = nil
                }
            }
        }
    }

    /// Strom aus beim Herunterfahren – wird von allen Auslösern gemeinsam genutzt.
    func startShutdownSwitchOff(trigger: String) {
        guard shutdownTask == nil else { return }
        guard settings.offOnShutdown else {
            Log.info("Abschalten beim Herunterfahren ist in den Einstellungen deaktiviert")
            shutdownTask = Task {}
            return
        }
        let charger = self.charger
        shutdownTask = Task { @MainActor in
            await charger.switchOffForPowerEvent(reason: "\(trigger) → Strom aus", timeout: 20)
        }
    }

    /// Führt den macOS-Befehl aus. Gibt eine Fehlermeldung zurück oder nil bei Erfolg.
    private static func execute(_ action: PowerAction) -> String? {
        if action == .sleep {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            do { try p.run() } catch { return error.localizedDescription }
            return nil
        }
        let command: String
        switch action {
        case .shutdown: command = "shut down"
        case .restart: command = "restart"
        case .logout: command = "log out"
        case .sleep: command = "sleep"
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to \(command)")?.executeAndReturnError(&error)
        if let error {
            return (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
        }
        return nil
    }
}

// MARK: - Fenster

/// Kleines, eigenständig verschiebbares Fenster für das Power-Widget.
final class PowerWidgetWindow: NSPanel {
    static let size = NSSize(width: 236, height: 70)
    private static let originKey = "powerWidgetOrigin"
    private var restoring = false

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        restorePosition()
        NotificationCenter.default.addObserver(self, selector: #selector(savePosition),
                                               name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func savePosition() {
        guard !restoring else { return }
        UserDefaults.standard.set([frame.minX, frame.maxY], forKey: Self.originKey)
    }

    private func restorePosition() {
        restoring = true
        defer { restoring = false }
        if let v = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], v.count == 2 {
            let rect = NSRect(x: v[0], y: v[1] - Self.size.height, width: Self.size.width, height: Self.size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                setFrame(rect, display: true)
                return
            }
        }
        placeDefault()
    }

    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.maxX - Self.size.width - 20, y: vf.minY + 20))
    }

    @objc private func screensChanged() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { placeDefault() }
    }

    func resetPosition() {
        placeDefault()
        savePosition()
    }
}

// MARK: - Ansicht

struct PowerWidgetView: View {
    @EnvironmentObject var power: PowerActionController
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.background, Color(red: 0.09, green: 0.1, blue: 0.115)],
                           startPoint: .top, endPoint: .bottom)
            WindowDragArea()
            if let status = power.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .allowsHitTesting(false)
            } else {
                HStack(spacing: 6) {
                    ForEach(PowerAction.allCases) { action in
                        PowerButton(action: action, armed: power.armed == action) { power.tap(action) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: PowerWidgetWindow.size.width, height: PowerWidgetWindow.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .help(monitor.battery.externalPower ? "Strom wird vorher abgeschaltet" : "Akkubetrieb – kein Strom zum Abschalten")
    }
}

private struct PowerButton: View {
    let action: PowerAction
    let armed: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: armed ? "exclamationmark.triangle.fill" : action.icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(armed ? "Sicher?" : action.title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(armed ? Color.white : (action == .shutdown ? Theme.warning : Theme.textPrimary))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(armed ? Theme.warning : Theme.card.opacity(hover ? 1 : 0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hover ? Color.white.opacity(0.18) : Theme.stroke)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(armed ? "Zum Bestätigen erneut klicken" : helpText)
    }

    private var helpText: String {
        switch action {
        case .shutdown: return "Strom aus, dann Mac ausschalten"
        case .restart: return "Strom aus, dann Mac neu starten"
        case .logout: return "Strom aus, dann abmelden"
        case .sleep: return "Ruhezustand (Strom aus, wenn Akku über der unteren Grenze)"
        }
    }
}
