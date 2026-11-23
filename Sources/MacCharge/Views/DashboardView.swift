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
        loadTile(title: "CPU", icon: "cpu", area: .cpu, value: monitor.cpu,
                 history: monitor.cpuHistory, critical: settings.cpuWarn, detail: nil)
    }

    private var gpuTile: some View {
        loadTile(title: "GPU", icon: "square.stack.3d.up.fill", area: .gpu, value: monitor.gpu,
                 history: monitor.gpuHistory, critical: settings.gpuWarn, detail: nil)
    }

    private var ramTile: some View {
        let mem = monitor.memory
        return loadTile(title: "RAM", icon: "memorychip", area: .ram, value: mem?.percent,
                        history: monitor.ramHistory, critical: settings.ramWarn,
                        detail: mem.map { "\(gb($0.usedBytes))/\(gb($0.totalBytes)) GB" })
    }

    /// Kachel mit aktuellem Wert (in Ampelfarbe); das Balkendiagramm hinterlegt die ganze Kachel.
    private func loadTile(title: String, icon: String, area: WarningArea, value: Double?,
                          history: [Double], critical: Double, detail: String?) -> some View {
        let level = value.map { Level.load($0, high: settings.loadHigh, critical: critical) } ?? .ok
        let chart = LoadBarChart(values: history, high: settings.loadHigh, critical: critical)
        return Tile(title: title, icon: icon, warning: monitor.warnings.contains(area), backdrop: AnyView(chart)) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: "%.0f %%", $0) } ?? "n. v.")
                    .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(value == nil ? Theme.textSecondary : (level == .ok ? Theme.textPrimary : level.color))
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(detail ?? " ")
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22, alignment: .top)
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
                .foregroundStyle((state == .serious || state == .critical) ? Theme.warning
                                 : (state == .fair ? Theme.orange : Theme.textPrimary))
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Meter(value: level, color: (state == .serious || state == .critical) ? Theme.warning
                                           : (state == .fair ? Theme.orange : Theme.accent))
                Text(monitor.battery.temperatureC.map { String(format: "Akku %.1f °C", $0) } ?? " ")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(monitor.warnings.contains(.battery) ? Theme.warning : Theme.textSecondary)
            }
            .frame(height: 22)
        }
    }

    private func valueLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
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
    @EnvironmentObject var history: BatteryHistory
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var charger: ChargeController

    var body: some View {
        let b = monitor.battery
        let warn = monitor.warnings.contains(.battery)
        let level = Level.battery(b.percent)
        let critical = b.hasBattery && b.percent <= BatteryThresholds.chargeNow && !b.isCharging
        Tile(title: "Akku", icon: b.isCharging ? "bolt.fill" : "battery.25", warning: warn || critical) {
            if !b.hasBattery {
                Text("Kein Akku gefunden").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(alignment: .center) {
                    (Text("\(b.percent)")
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(level == .ok ? Theme.textPrimary : level.color)
                    + Text(" %").font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textSecondary))
                    Spacer()
                    if critical {
                        BlinkingChargeWarning()
                    } else {
                        Text(statusText(b)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(b.isCharging ? Theme.accent : Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                LimitBar(percent: b.percent, lower: settings.lowerLimit, upper: charger.effectiveUpperLimit,
                         level: level)
                Text(critical ? "Akku kritisch · \(statusText(b))" : detailText(b))
                    .font(.system(size: 9.5, weight: critical ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(warn || critical ? Theme.warning : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    Text("VERLAUF 24 H").font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Image(systemName: "powerplug.fill").font(.system(size: 8))
                    Text(AdapterInfo.text(b)).font(.system(size: 9, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(AdapterInfo.atLimit(b) ? Theme.orange : Theme.textSecondary)
                .help(AdapterInfo.atLimit(b) ? "Netzteil arbeitet am Limit – evtl. zu schwach" : "Netzteil-Nennleistung und aktuelle Aufnahme")
                .padding(.top, 2)
                BatteryHistoryChart(samples: history.samples, events: history.switchEvents,
                                    lower: settings.lowerLimit, upper: charger.effectiveUpperLimit)
                    .frame(height: 34)
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
    let level: Level

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
                    .fill(LinearGradient(colors: [level.color.opacity(0.65), level.color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, w * CGFloat(percent) / 100))
                marker(at: lower, width: w, label: "\(lower)")
                marker(at: upper, width: w, label: "\(upper)")
            }
        }
        .frame(height: 10)
        .padding(.vertical, 3)
        .animation(.easeOut(duration: 0.5), value: percent)
    }

    private func marker(at value: Int, width: CGFloat, label: String) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.85))
            .frame(width: 2, height: 16)
            .offset(x: width * CGFloat(value) / 100 - 1)
            .help("Grenze \(label) %")
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
