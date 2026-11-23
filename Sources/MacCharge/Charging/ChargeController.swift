import Foundation
import Combine

/// Steuert das Laden: Steckdose AUS bei >= Obergrenze, EIN bei <= Untergrenze.
/// Dazwischen wird nichts geschaltet (Hysterese), damit die Steckdose nicht ständig klickt.
@MainActor
final class ChargeController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case switching(Bool)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Zuletzt bekannter Zustand der Steckdose (aus Gerät oder aus Netzteil-Erkennung abgeleitet).
    @Published private(set) var plugOn: Bool?
    @Published private(set) var plugPower: Double?
    @Published private(set) var plugUnreachable = false
    /// Manuelles Schalten pausiert die Automatik für diese Zeit.
    @Published private(set) var manualHoldUntil: Date?
    /// Einmalig auf 100 % laden.
    @Published var fullChargeOnce = false
    @Published private(set) var lastAction: String = "–"

    private let settings: AppSettings
    private let monitor: SystemMonitor
    private var timer: Timer?
    private var pendingTarget: Bool?
    private var pendingSince: Date?
    private var retries = 0
    private var busy = false

    static let manualHoldMinutes: Double = 30
    private static let verifyAfter: TimeInterval = 15
    private static let maxRetries = 3

    init(settings: AppSettings, monitor: SystemMonitor) {
        self.settings = settings
        self.monitor = monitor
    }

    var effectiveUpperLimit: Int { fullChargeOnce ? 100 : settings.upperLimit }

    var isAutomationPaused: Bool {
        if let until = manualHoldUntil, until > Date() { return true }
        return false
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        Task { await evaluate() }
    }

    func makePlug() -> PlugController {
        switch settings.backend {
        case .shortcuts:
            return ShortcutsPlug(onName: settings.shortcutOn, offName: settings.shortcutOff)
        case .refossLocal:
            return RefossPlug(host: settings.refossHost, switchID: settings.refossSwitchID,
                              user: settings.refossUser, password: settings.refossPassword)
        }
    }

    // MARK: Manuelle Bedienung

    func manualSwitch(_ on: Bool) {
        manualHoldUntil = Date().addingTimeInterval(Self.manualHoldMinutes * 60)
        Task { await send(on, reason: on ? "Manuell eingeschaltet" : "Manuell ausgeschaltet") }
    }

    func resumeAutomation() {
        manualHoldUntil = nil
        Task { await evaluate() }
    }

    func startFullChargeOnce() {
        fullChargeOnce = true
        manualHoldUntil = nil
        Task { await send(true, reason: "Einmalig auf 100 %") }
    }

    // MARK: Regelkreis

    func evaluate() async {
        guard !busy else { return }
        let battery = monitor.battery
        await refreshPlugStatus(battery: battery)

        if let until = manualHoldUntil, until <= Date() { manualHoldUntil = nil }
        if fullChargeOnce && (battery.percent >= 100 || battery.fullyCharged) { fullChargeOnce = false }

        // Ausstehenden Schaltbefehl über das Netzteil-Signal verifizieren
        if let target = pendingTarget, let since = pendingSince {
            if battery.externalPower == target {
                pendingTarget = nil; retries = 0
                phase = .idle
            } else if Date().timeIntervalSince(since) > Self.verifyAfter {
                if retries < Self.maxRetries {
                    retries += 1
                    await send(target, reason: "Wiederholung \(retries)/\(Self.maxRetries)")
                    return
                } else {
                    pendingTarget = nil; retries = 0
                    phase = .error(target ? "Netzteil liefert keinen Strom – Kabel/Steckdose prüfen"
                                          : "Steckdose hat nicht abgeschaltet")
                }
            }
        }

        guard settings.automationEnabled, battery.hasBattery, !isAutomationPaused, pendingTarget == nil else { return }

        let upper = effectiveUpperLimit
        let lower = settings.lowerLimit
        if battery.percent >= upper && battery.externalPower && !fullChargeOnce {
            await send(false, reason: "\(battery.percent) % ≥ \(upper) % → Laden aus")
        } else if battery.percent <= lower && !battery.externalPower {
            await send(true, reason: "\(battery.percent) % ≤ \(lower) % → Laden ein")
        } else if fullChargeOnce && !battery.externalPower {
            await send(true, reason: "Einmalig auf 100 %")
        }
    }

    private func send(_ on: Bool, reason: String) async {
        busy = true
        defer { busy = false }
        phase = .switching(on)
        do {
            try await makePlug().setPower(on)
            plugOn = on
            plugUnreachable = false
            pendingTarget = on
            pendingSince = Date()
            lastAction = "\(Self.timeFormatter.string(from: Date())) · \(reason)"
            Log.info(reason)
        } catch {
            plugUnreachable = true
            phase = .error(error.localizedDescription)
            lastAction = "\(Self.timeFormatter.string(from: Date())) · Fehler: \(error.localizedDescription)"
            Log.info("Schalten fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func refreshPlugStatus(battery: BatteryReading) async {
        if settings.backend == .refossLocal, !settings.refossHost.isEmpty {
            do {
                if let status = try await makePlug().status() {
                    plugOn = status.isOn ?? plugOn
                    plugPower = status.powerWatts
                    plugUnreachable = false
                    if case .error = phase, pendingTarget == nil { phase = .idle }
                }
            } catch {
                plugUnreachable = true
                plugPower = nil
            }
        } else {
            plugPower = nil
            if pendingTarget == nil { plugOn = battery.externalPower }
        }
    }

    /// Verbindungstest aus den Einstellungen.
    func testConnection() async -> String {
        do {
            switch settings.backend {
            case .shortcuts:
                let all = await ShortcutsPlug.availableShortcuts()
                let missing = [settings.shortcutOn, settings.shortcutOff].filter { !all.contains($0) }
                return missing.isEmpty ? "✅ Beide Kurzbefehle gefunden."
                                       : "‼️ Nicht gefunden: \(missing.joined(separator: ", "))"
            case .refossLocal:
                let plug = RefossPlug(host: settings.refossHost, switchID: settings.refossSwitchID,
                                      user: settings.refossUser, password: settings.refossPassword)
                let info = try await plug.deviceInfo()
                let status = try await plug.status()
                let model = info["model"] ?? info["name"] ?? "Refoss"
                let state = status?.isOn.map { $0 ? "EIN" : "AUS" } ?? "?"
                let watts = status?.powerWatts.map { String(format: "%.1f W", $0) } ?? "–"
                return "✅ \(model) erreichbar · \(state) · \(watts)"
            }
        } catch {
            return "‼️ \(error.localizedDescription)"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
