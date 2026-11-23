import Foundation
import Combine

enum PlugBackend: String, CaseIterable, Identifiable {
    case shortcuts   // Apple Home / HomeKit über die Kurzbefehle-App
    case refossLocal // Refoss Open API (JSON-RPC über HTTP im lokalen Netz)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcuts: return "Apple Home (Kurzbefehle)"
        case .refossLocal: return "Refoss lokal (Open API)"
        }
    }
}

/// Alle Einstellungen, persistent in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // MARK: Laden
    @Published var automationEnabled: Bool { didSet { d.set(automationEnabled, forKey: "automationEnabled") } }
    @Published var lowerLimit: Int { didSet { d.set(lowerLimit, forKey: "lowerLimit") } }
    @Published var upperLimit: Int { didSet { d.set(upperLimit, forKey: "upperLimit") } }

    // MARK: Steckdose
    @Published var backend: PlugBackend { didSet { d.set(backend.rawValue, forKey: "backend") } }
    @Published var shortcutOn: String { didSet { d.set(shortcutOn, forKey: "shortcutOn") } }
    @Published var shortcutOff: String { didSet { d.set(shortcutOff, forKey: "shortcutOff") } }
    @Published var refossHost: String { didSet { d.set(refossHost, forKey: "refossHost") } }
    @Published var refossSwitchID: Int { didSet { d.set(refossSwitchID, forKey: "refossSwitchID") } }
    @Published var refossUser: String { didSet { d.set(refossUser, forKey: "refossUser") } }
    @Published var refossPassword: String { didSet { d.set(refossPassword, forKey: "refossPassword") } }

    // MARK: Warnungen (Überlastung)
    /// Ab hier wird die Auslastung orange dargestellt (rot ab dem jeweiligen Warnwert).
    @Published var loadHigh: Double { didSet { d.set(loadHigh, forKey: "loadHigh") } }
    @Published var cpuWarn: Double { didSet { d.set(cpuWarn, forKey: "cpuWarn") } }
    @Published var gpuWarn: Double { didSet { d.set(gpuWarn, forKey: "gpuWarn") } }
    @Published var ramWarn: Double { didSet { d.set(ramWarn, forKey: "ramWarn") } }
    @Published var batteryTempWarn: Double { didSet { d.set(batteryTempWarn, forKey: "batteryTempWarn") } }
    @Published var plugPowerWarn: Double { didSet { d.set(plugPowerWarn, forKey: "plugPowerWarn") } }
    @Published var warnDelay: Double { didSet { d.set(warnDelay, forKey: "warnDelay") } }

    // MARK: Allgemein
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var alwaysOnTop: Bool { didSet { d.set(alwaysOnTop, forKey: "alwaysOnTop") } }
    @Published var showOnAllSpaces: Bool { didSet { d.set(showOnAllSpaces, forKey: "showOnAllSpaces") } }
    @Published var widgetOpacity: Double { didSet { d.set(widgetOpacity, forKey: "widgetOpacity") } }

    // MARK: Updates
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }

    private init() {
        d.register(defaults: [
            "automationEnabled": true,
            "lowerLimit": 20,
            "upperLimit": 85,
            "backend": PlugBackend.shortcuts.rawValue,
            "shortcutOn": "MacCharge Ein",
            "shortcutOff": "MacCharge Aus",
            "refossHost": "",
            "refossSwitchID": 1,
            "refossUser": "",
            "refossPassword": "",
            "loadHigh": 70.0,
            "cpuWarn": 90.0,
            "gpuWarn": 90.0,
            "ramWarn": 90.0,
            "batteryTempWarn": 45.0,
            "plugPowerWarn": 150.0,
            "warnDelay": 10.0,
            "launchAtLogin": true,
            "alwaysOnTop": true,
            "showOnAllSpaces": true,
            "widgetOpacity": 0.97,
            "autoCheckUpdates": true,
        ])
        automationEnabled = d.bool(forKey: "automationEnabled")
        lowerLimit = d.integer(forKey: "lowerLimit")
        upperLimit = d.integer(forKey: "upperLimit")
        backend = PlugBackend(rawValue: d.string(forKey: "backend") ?? "") ?? .shortcuts
        shortcutOn = d.string(forKey: "shortcutOn") ?? "MacCharge Ein"
        shortcutOff = d.string(forKey: "shortcutOff") ?? "MacCharge Aus"
        refossHost = d.string(forKey: "refossHost") ?? ""
        refossSwitchID = d.integer(forKey: "refossSwitchID")
        refossUser = d.string(forKey: "refossUser") ?? ""
        refossPassword = d.string(forKey: "refossPassword") ?? ""
        loadHigh = d.double(forKey: "loadHigh")
        cpuWarn = d.double(forKey: "cpuWarn")
        gpuWarn = d.double(forKey: "gpuWarn")
        ramWarn = d.double(forKey: "ramWarn")
        batteryTempWarn = d.double(forKey: "batteryTempWarn")
        plugPowerWarn = d.double(forKey: "plugPowerWarn")
        warnDelay = d.double(forKey: "warnDelay")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        alwaysOnTop = d.bool(forKey: "alwaysOnTop")
        showOnAllSpaces = d.bool(forKey: "showOnAllSpaces")
        widgetOpacity = d.double(forKey: "widgetOpacity")
        autoCheckUpdates = d.bool(forKey: "autoCheckUpdates")
    }

    /// Sorgt dafür, dass unten < oben mit mindestens 5 % Abstand gilt.
    func normalizeLimits() {
        lowerLimit = min(max(lowerLimit, 5), 90)
        upperLimit = min(max(upperLimit, lowerLimit + 5), 100)
    }
}
