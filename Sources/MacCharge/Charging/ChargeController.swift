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
    private var cancellables = Set<AnyCancellable>()
    /// Nach endgültig fehlgeschlagenem Schalten: Automatik ruht, bis sich das Netzteilsignal
    /// ändert oder manuell geschaltet wird (verhindert Dauer-Umschalten, z. B. bei abgezogenem Kabel).
    @Published private(set) var faultLock: Bool?

    static let manualHoldMinutes: Double = 30
    private static let verifyAfter: TimeInterval = 15
    private static let maxRetries = 3

    init(settings: AppSettings, monitor: SystemMonitor) {
        self.settings = settings
        self.monitor = monitor
    }

    var effectiveUpperLimit: Int { fullChargeOnce ? 100 : settings.upperLimit }

    var isAutomationPaused: Bool {
        if faultLock != nil { return true }
        if let until = manualHoldUntil, until > Date() { return true }
        return false
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        Task { await evaluate() }

        // Ändert der Nutzer Grenzen oder Automatik, gilt die neue Regel sofort:
        // eine manuelle Pause bzw. Fehlersperre wird aufgehoben und neu ausgewertet.
        Publishers.Merge3(settings.$upperLimit.dropFirst().map { _ in () },
                          settings.$lowerLimit.dropFirst().map { _ in () },
                          settings.$automationEnabled.dropFirst().filter { $0 }.map { _ in () })
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.manualHoldUntil = nil
                self.faultLock = nil
                if case .error = self.phase { self.phase = .idle }
                Task { await self.evaluate() }
            }
            .store(in: &cancellables)
    }

    /// Kurzer Klartext, was die Automatik als Nächstes tut (für die Statuszeile).
    var nextActionHint: String {
        let b = monitor.battery
        guard settings.automationEnabled else { return "Automatik aus" }
        guard b.hasBattery else { return "Kein Akku" }
        if b.externalPower {
            return "Strom aus bei ≥ \(effectiveUpperLimit) % · jetzt \(b.percent) %"
        }
        return "Strom ein bei ≤ \(settings.lowerLimit) % · jetzt \(b.percent) %"
    }

    func makePlug() -> PlugController {
        switch settings.backend {
        case .shortcuts:
            return ShortcutsPlug(onName: settings.shortcutOn, offName: settings.shortcutOff,
                                 toggleName: isToggleMode ? settings.shortcutToggle : nil)
        case .refossLocal:
            return RefossPlug(host: settings.refossHost, switchID: settings.refossSwitchID,
                              user: settings.refossUser, password: settings.refossPassword)
        }
    }

    /// Umschalt-Kurzbefehl: Zustand ist nur über das Netzteilsignal bekannt.
    var isToggleMode: Bool { settings.backend == .shortcuts && settings.shortcutMode == .toggle }

    // MARK: Manuelle Bedienung

    func manualSwitch(_ on: Bool) {
        faultLock = nil
        manualHoldUntil = Date().addingTimeInterval(Self.manualHoldMinutes * 60)
        Task { await send(on, reason: on ? "Manuell eingeschaltet" : "Manuell ausgeschaltet") }
    }

    func resumeAutomation() {
        manualHoldUntil = nil
        faultLock = nil
        Task { await evaluate() }
    }

    func startFullChargeOnce() {
        faultLock = nil
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
                // Umschalt-Kurzbefehl nie wiederholen – ein zweiter Aufruf würde zurückschalten
                let maxRetries = isToggleMode ? 0 : Self.maxRetries
                if retries < maxRetries {
                    retries += 1
                    await send(target, reason: "Wiederholung \(retries)/\(maxRetries)")
                    return
                } else {
                    pendingTarget = nil; retries = 0
                    faultLock = battery.externalPower
                    phase = .error(target ? "Netzteil liefert keinen Strom – Kabel/Steckdose prüfen"
                                          : "Steckdose hat nicht abgeschaltet")
                }
            }
        }

        // Sperre aufheben, sobald sich das Netzteilsignal ändert (z. B. Kabel wieder eingesteckt)
        if let lock = faultLock, lock != battery.externalPower {
            faultLock = nil
            if case .error = phase { phase = .idle }
        }

        guard settings.automationEnabled, battery.hasBattery, !isAutomationPaused,
              pendingTarget == nil, faultLock == nil else { return }

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
        if SystemMonitor.demoMode {
            // Demo-Modus schaltet niemals die echte Steckdose
            lastAction = "Demo · würde \(on ? "einschalten" : "ausschalten"): \(reason)"
            return
        }
        // Umschalt-Modus: nur schalten, wenn der Ist-Zustand (Netzteil) vom Ziel abweicht
        if isToggleMode && monitor.battery.externalPower == on {
            lastAction = "\(Self.timeFormatter.string(from: Date())) · Strom ist bereits \(on ? "ein" : "aus")"
            plugOn = on
            return
        }
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

    // MARK: Herunterfahren / Ruhezustand

    /// Schaltet den Strom vor dem Herunterfahren bzw. Einschlafen ab – ohne Verifikation
    /// (danach läuft MacCharge nicht mehr) und mit Zeitlimit, damit macOS nicht hängt.
    /// Gibt true zurück, wenn ein Schaltbefehl gesendet wurde.
    @discardableResult
    func switchOffForPowerEvent(reason: String, timeout: TimeInterval) async -> Bool {
        guard !SystemMonitor.demoMode, monitor.battery.externalPower else { return false }
        let plug = makePlug()
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { try await plug.setPower(false); return true } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        plugOn = false
        lastAction = "\(Self.timeFormatter.string(from: Date())) · \(reason)\(finished ? "" : " (ohne Bestätigung)")"
        Log.info("\(reason): Strom aus gesendet (bestätigt: \(finished))")
        return true
    }

    /// Nach dem Aufwachen sofort neu bewerten (z. B. Akku im Schlaf gesunken).
    func didWake() {
        pendingTarget = nil
        retries = 0
        Task { await evaluate() }
    }

    /// Verbindungstest aus den Einstellungen.
    func testConnection() async -> String {
        do {
            switch settings.backend {
            case .shortcuts:
                let all = await ShortcutsPlug.availableShortcuts()
                let names = isToggleMode ? [settings.shortcutToggle] : [settings.shortcutOn, settings.shortcutOff]
                let missing = names.filter { !all.contains($0) }
                if !missing.isEmpty { return "‼️ Nicht gefunden: \(missing.joined(separator: ", "))" }
                return isToggleMode ? "✅ Kurzbefehl „\(settings.shortcutToggle)“ gefunden."
                                    : "✅ Beide Kurzbefehle gefunden."
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
