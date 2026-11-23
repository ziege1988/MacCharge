import Foundation
import Combine

/// Bereiche, für die eine Überlastungswarnung (‼️) angezeigt werden kann.
enum WarningArea: String, CaseIterable {
    case cpu, gpu, ram, thermal, battery, plug
}

/// Sammelt alle 2 Sekunden die Systemwerte und bewertet Überlastungen.
@MainActor
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: Double?
    @Published private(set) var gpu: Double?
    @Published private(set) var memory: MemoryReading?
    @Published private(set) var battery = BatterySensor.sample()
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var ramHistory: [Double] = []

    /// Aktive Warnungen (nach Ablauf der Verzögerung).
    @Published private(set) var warnings: Set<WarningArea> = []
    /// Aktuelle Leistungsaufnahme an der Steckdose (nur Refoss lokal).
    var plugPowerProvider: @MainActor () -> Double? = { nil }
    /// Steckdose nicht erreichbar / reagiert nicht.
    var plugFaultProvider: @MainActor () -> Bool = { false }

    /// Akkuverlauf 24 h (eigenes ObservableObject, wird separat in die Views gereicht).
    let history = BatteryHistory(demo: SystemMonitor.demoMode)

    private let cpuSensor = CPUSensor()
    private var timer: Timer?
    private var exceededSince: [WarningArea: Date] = [:]
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.3
    }

    private func tick() {
        cpu = cpuSensor.sample() ?? cpu
        gpu = GPUSensor.sample()
        memory = MemorySensor.sample()
        battery = BatterySensor.sample()
        thermalState = ProcessInfo.processInfo.thermalState
        if Self.demoMode { applyDemoValues() }
        history.record(battery)

        if let cpu { cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength)) }
        if let gpu { gpuHistory = Array((gpuHistory + [gpu]).suffix(Self.historyLength)) }
        if let ram = memory?.percent { ramHistory = Array((ramHistory + [ram]).suffix(Self.historyLength)) }
        evaluateWarnings()
    }

    /// Demo-Modus (MACCHARGE_DEMO=1): simulierte Werte für Screenshots/Tests ohne Akku.
    /// MACCHARGE_DEMO=1 → normal (78 %, lädt), MACCHARGE_DEMO=low → 14 %, Akkubetrieb.
    static let demoValue = ProcessInfo.processInfo.environment["MACCHARGE_DEMO"]
    static var demoMode: Bool { demoValue != nil }
    private var demoStep = 0

    private func applyDemoValues() {
        demoStep += 1
        // CPU läuft durch alle Bereiche (grün → orange → rot), damit alle Farben sichtbar sind
        cpu = [15, 35, 55, 75, 85, 95][demoStep % 6] + Double.random(in: 0...4)
        gpu = 30 + Double.random(in: 0...45)
        let low = Self.demoValue == "low"
        battery.hasBattery = true
        battery.percent = low ? 14 : 78
        battery.isCharging = !low
        battery.externalPower = !low
        battery.minutesToFull = low ? nil : 42
        battery.minutesToEmpty = low ? 38 : nil
        battery.watts = low ? -9.8 : 27.4
        battery.temperatureC = 31.5
        battery.healthPercent = 94
        battery.cycleCount = 212
        battery.adapterWatts = low ? nil : 96
        battery.inputWatts = low ? nil : 45.3
    }

    private func evaluateWarnings() {
        var exceeded: [WarningArea: Bool] = [:]
        exceeded[.cpu] = (cpu ?? 0) >= settings.cpuWarn
        exceeded[.gpu] = (gpu ?? 0) >= settings.gpuWarn
        exceeded[.ram] = (memory?.percent ?? 0) >= settings.ramWarn
        exceeded[.thermal] = thermalState == .serious || thermalState == .critical
        exceeded[.battery] = (battery.temperatureC ?? 0) >= settings.batteryTempWarn
        exceeded[.plug] = (plugPowerProvider() ?? 0) >= settings.plugPowerWarn || plugFaultProvider()

        let now = Date()
        var active: Set<WarningArea> = []
        for area in WarningArea.allCases {
            if exceeded[area] == true {
                let since = exceededSince[area] ?? now
                exceededSince[area] = since
                // Thermik und Steckdosenfehler sofort, Auslastung erst nach Verzögerung (gegen Flackern)
                let delay = (area == .thermal || area == .plug) ? 0 : settings.warnDelay
                if now.timeIntervalSince(since) >= delay { active.insert(area) }
            } else {
                exceededSince[area] = nil
            }
        }
        if active != warnings { warnings = active }
    }
}
