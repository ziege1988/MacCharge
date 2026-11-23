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

    /// Aktive Warnungen (nach Ablauf der Verzögerung).
    @Published private(set) var warnings: Set<WarningArea> = []
    /// Aktuelle Leistungsaufnahme an der Steckdose (nur Refoss lokal).
    var plugPowerProvider: @MainActor () -> Double? = { nil }
    /// Steckdose nicht erreichbar / reagiert nicht.
    var plugFaultProvider: @MainActor () -> Bool = { false }

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

        if let cpu { cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength)) }
        if let gpu { gpuHistory = Array((gpuHistory + [gpu]).suffix(Self.historyLength)) }
        evaluateWarnings()
    }

    /// Demo-Modus (MACCHARGE_DEMO=1): simulierte Werte für Screenshots/Tests ohne Akku.
    static let demoMode = ProcessInfo.processInfo.environment["MACCHARGE_DEMO"] == "1"

    private func applyDemoValues() {
        cpu = 93 + Double.random(in: 0...5)
        gpu = 35 + Double.random(in: 0...20)
        battery.hasBattery = true
        battery.percent = 78
        battery.isCharging = true
        battery.externalPower = true
        battery.minutesToFull = 42
        battery.watts = 27.4
        battery.temperatureC = 31.5
        battery.healthPercent = 94
        battery.cycleCount = 212
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
