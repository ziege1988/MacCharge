import SwiftUI

struct DashboardView: View {
    let openSettings: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var charger: ChargeController
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.background, Color(red: 0.09, green: 0.1, blue: 0.115)],
                           startPoint: .top, endPoint: .bottom)
            WindowDragArea()
            VStack(spacing: 10) {
                header
                BatteryCard()
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    cpuTile
                    gpuTile
                    ramTile
                    thermalTile
                }
                ChargeControlCard()
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: AppInfo.logo).resizable().frame(width: 20, height: 20)
            BrandText(size: 14)
            Spacer()
            PlugPill()
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        if updater.updateAvailable {
                            Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 3, y: -3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(updater.updateAvailable ? "Update verfügbar – Einstellungen öffnen" : "Einstellungen")
        }
        .frame(height: 24)
    }

    // MARK: Kacheln

    private var cpuTile: some View {
        Tile(title: "CPU", icon: "cpu", warning: monitor.warnings.contains(.cpu)) {
            valueLine(monitor.cpu.map { String(format: "%.0f %%", $0) } ?? "–")
            Sparkline(values: monitor.cpuHistory, color: monitor.warnings.contains(.cpu) ? Theme.warning : Theme.accent)
                .frame(height: 18)
        }
    }

    private var gpuTile: some View {
        Tile(title: "GPU", icon: "square.stack.3d.up.fill", warning: monitor.warnings.contains(.gpu)) {
            valueLine(monitor.gpu.map { String(format: "%.0f %%", $0) } ?? "n. v.")
            Sparkline(values: monitor.gpuHistory, color: monitor.warnings.contains(.gpu) ? Theme.warning : Theme.accent)
                .frame(height: 18)
        }
    }

    private var ramTile: some View {
        let mem = monitor.memory
        let warn = monitor.warnings.contains(.ram)
        return Tile(title: "RAM", icon: "memorychip", warning: warn) {
            valueLine(mem.map { String(format: "%.0f %%", $0.percent) } ?? "–")
            VStack(alignment: .leading, spacing: 4) {
                Meter(value: mem?.percent ?? 0, color: warn ? Theme.warning : Theme.accent)
                Text(mem.map { "\(gb($0.usedBytes)) / \(gb($0.totalBytes)) GB" } ?? " ")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(height: 18)
        }
    }

    private var thermalTile: some View {
        let state = monitor.thermalState
        let warn = monitor.warnings.contains(.thermal)
        let (label, level): (String, Double) = {
            switch state {
            case .nominal: return ("Normal", 25)
            case .fair: return ("Erhöht", 50)
            case .serious: return ("Hoch", 80)
            case .critical: return ("Kritisch", 100)
            @unknown default: return ("–", 0)
            }
        }()
        return Tile(title: "Thermik", icon: "thermometer.medium", warning: warn) {
            valueLine(label)
            VStack(alignment: .leading, spacing: 4) {
                Meter(value: level, color: warn ? Theme.warning : (state == .fair ? Theme.amber : Theme.accent))
                Text(monitor.battery.temperatureC.map { String(format: "Akku %.1f °C", $0) } ?? " ")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(monitor.warnings.contains(.battery) ? Theme.warning : Theme.textSecondary)
            }
            .frame(height: 18)
        }
    }

    private func valueLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Akku

struct BatteryCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var charger: ChargeController

    var body: some View {
        let b = monitor.battery
        let warn = monitor.warnings.contains(.battery)
        Tile(title: "Akku", icon: b.isCharging ? "bolt.fill" : "battery.75", warning: warn) {
            if !b.hasBattery {
                Text("Kein Akku gefunden").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(b.percent)")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(Theme.textPrimary)
                    + Text(" %").font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(statusText(b)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(b.isCharging ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                }
                LimitBar(percent: b.percent, lower: settings.lowerLimit, upper: charger.effectiveUpperLimit,
                         charging: b.isCharging, warning: warn)
                Text(detailText(b)).font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(warn ? Theme.warning : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func statusText(_ b: BatteryReading) -> String {
        if b.isCharging {
            if let m = b.minutesToFull { return "Lädt · \(m / 60):\(String(format: "%02d", m % 60)) bis voll" }
            return "Lädt"
        }
        if b.externalPower { return b.fullyCharged ? "Voll geladen" : "Netzteil · pausiert" }
        if let m = b.minutesToEmpty { return "Akku · noch \(m / 60):\(String(format: "%02d", m % 60))" }
        return "Akkubetrieb"
    }

    private func detailText(_ b: BatteryReading) -> String {
        var parts: [String] = []
        if let w = b.watts, abs(w) >= 0.1 { parts.append(String(format: "%+.1f W", w)) }
        if let t = b.temperatureC { parts.append(String(format: "%.0f °C", t)) }
        if let h = b.healthPercent { parts.append(String(format: "%.0f %% Zustand", h)) }
        if let c = b.cycleCount { parts.append("\(c) Zyklen") }
        return parts.joined(separator: " · ")
    }
}

/// Akkubalken mit Markierungen für Unter- und Obergrenze.
struct LimitBar: View {
    let percent: Int
    let lower: Int
    let upper: Int
    let charging: Bool
    let warning: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                // Zielbereich
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: w * CGFloat(upper - lower) / 100)
                    .offset(x: w * CGFloat(lower) / 100)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: warning ? [Theme.warning, Theme.warning]
                                                         : [Theme.accentDim, Theme.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, w * CGFloat(percent) / 100))
                marker(at: lower, width: w, label: "\(lower)")
                marker(at: upper, width: w, label: "\(upper)")
            }
        }
        .frame(height: 10)
        .padding(.bottom, 13)
        .animation(.easeOut(duration: 0.5), value: percent)
    }

    private func marker(at value: Int, width: CGFloat, label: String) -> some View {
        VStack(spacing: 1) {
            Rectangle().fill(Color.white.opacity(0.8)).frame(width: 1.5, height: 14)
            Text(label).font(.system(size: 8, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
        .offset(x: width * CGFloat(value) / 100 - 0.75, y: 9)
    }
}

// MARK: - Steckdose / Ladesteuerung

struct PlugPill: View {
    @EnvironmentObject var charger: ChargeController
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let fault = monitor.warnings.contains(.plug)
        let on = charger.plugOn
        HStack(spacing: 4) {
            if fault {
                Text("‼️").font(.system(size: 9))
            } else {
                Circle().fill(on == true ? Theme.accent : Color.white.opacity(0.35)).frame(width: 6, height: 6)
            }
            Text(on == nil ? "Steckdose ?" : (on! ? "Strom EIN" : "Strom AUS"))
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(fault ? Theme.warning : Theme.textSecondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(fault ? Theme.warning.opacity(0.15) : Color.white.opacity(0.06)))
    }
}

struct ChargeControlCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var charger: ChargeController

    var body: some View {
        let fault = monitor.warnings.contains(.plug)
        Tile(title: "Ladesteuerung", icon: "powerplug.fill", warning: fault, interactive: true) {
            HStack {
                Toggle(isOn: $settings.automationEnabled) {
                    Text("Automatik  \(settings.lowerLimit) % ↔ \(charger.effectiveUpperLimit) %")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
            }
            HStack(spacing: 6) {
                ControlButton(title: "Ein", icon: "bolt.fill") { charger.manualSwitch(true) }
                ControlButton(title: "Aus", icon: "bolt.slash.fill") { charger.manualSwitch(false) }
                ControlButton(title: charger.fullChargeOnce ? "100 % …" : "100 %", icon: "battery.100.bolt",
                              highlighted: charger.fullChargeOnce) { charger.startFullChargeOnce() }
            }
            statusLine
        }
    }

    @ViewBuilder private var statusLine: some View {
        let text: String = {
            switch charger.phase {
            case .switching(let on): return on ? "Schalte Strom ein …" : "Schalte Strom aus …"
            case .error(let msg): return msg
            case .idle:
                if let until = charger.manualHoldUntil, until > Date() {
                    let mins = Int(until.timeIntervalSinceNow / 60) + 1
                    return "Automatik pausiert (manuell) · \(mins) min"
                }
                var t = charger.lastAction
                if let p = charger.plugPower { t += String(format: " · %.0f W", p) }
                return t
            }
        }()
        let isError: Bool = { if case .error = charger.phase { return true }; return charger.plugUnreachable }()
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(isError ? Theme.warning : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if charger.isAutomationPaused {
                Button("Fortsetzen") { charger.resumeAutomation() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .help(text)
    }
}

struct ControlButton: View {
    let title: String
    let icon: String
    var highlighted = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .foregroundStyle(highlighted ? Color.black : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? Theme.accent : Color.white.opacity(hover ? 0.12 : 0.07))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
