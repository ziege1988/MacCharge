import SwiftUI

/// Flache, breite Darstellung ("Leiste"), z. B. oben am Zweitbildschirm.
/// Gleiche Daten und Warnlogik wie das Hochformat, nur nebeneinander angeordnet.
struct BarDashboardView: View {
    let openSettings: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var charger: ChargeController
    @EnvironmentObject var updater: UpdateManager
    @EnvironmentObject var history: BatteryHistory

    private let segmentPadding: CGFloat = 7

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.background, Color(red: 0.09, green: 0.1, blue: 0.115)],
                           startPoint: .top, endPoint: .bottom)
            WindowDragArea()
            HStack(spacing: 6) {
                brand.frame(width: 104)
                batterySegment.frame(width: 178)
                historySegment.frame(width: 150)
                loadSegment("CPU", icon: "cpu", area: .cpu, value: monitor.cpu,
                            history: monitor.cpuHistory, critical: settings.cpuWarn)
                loadSegment("GPU", icon: "square.stack.3d.up.fill", area: .gpu, value: monitor.gpu,
                            history: monitor.gpuHistory, critical: settings.gpuWarn)
                loadSegment("RAM", icon: "memorychip", area: .ram, value: monitor.memory?.percent,
                            history: monitor.ramHistory, critical: settings.ramWarn)
                thermalSegment.frame(width: 84)
                controlSegment.frame(width: 176)
            }
            .padding(6)
        }
    }

    // MARK: Segmente

    private var brand: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(nsImage: AppInfo.logo).resizable().frame(width: 18, height: 18)
                BrandText(size: 12).fixedSize()
            }
            PlugPill()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .allowsHitTesting(false)
    }

    private var batterySegment: some View {
        let b = monitor.battery
        let level = Level.battery(b.percent)
        let critical = b.hasBattery && b.percent <= BatteryThresholds.chargeNow && !b.isCharging
        return Tile(title: "Akku", icon: b.isCharging ? "bolt.fill" : "battery.25",
                    warning: monitor.warnings.contains(.battery) || critical, padding: segmentPadding) {
            HStack(spacing: 8) {
                Text(b.hasBattery ? "\(b.percent) %" : "–")
                    .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(level == .ok ? Theme.textPrimary : level.color)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    if critical {
                        BlinkingChargeWarning().scaleEffect(0.8, anchor: .leading)
                            .frame(height: 12, alignment: .leading)
                    } else {
                        Text(shortStatus(b))
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(b.isCharging ? Theme.accent : Theme.textSecondary)
                            .lineLimit(1)
                            .frame(height: 12, alignment: .leading)
                    }
                    LimitBar(percent: b.percent, lower: settings.lowerLimit,
                             upper: charger.effectiveUpperLimit, level: level)
                        .scaleEffect(y: 0.6)
                        .frame(height: 12)
                }
            }
        }
    }

    private var historySegment: some View {
        let b = monitor.battery
        let chart = BatteryHistoryChart(samples: history.samples, events: history.switchEvents,
                                        lower: settings.lowerLimit, upper: charger.effectiveUpperLimit)
            .padding(EdgeInsets(top: 21, leading: 6, bottom: 4, trailing: 6))
        return Tile(title: "24 h", icon: "chart.xyaxis.line", backdrop: AnyView(chart), padding: segmentPadding) {
            Color.clear.frame(height: 20)
        }
        .overlay(alignment: .topTrailing) {
            Text("🔌 " + AdapterInfo.text(b, compact: true))
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundStyle(AdapterInfo.atLimit(b) ? Theme.orange : Theme.textSecondary)
                .lineLimit(1)
                .padding(.top, segmentPadding)
                .padding(.trailing, segmentPadding)
                .allowsHitTesting(false)
        }
    }

    private func loadSegment(_ title: String, icon: String, area: WarningArea, value: Double?,
                             history: [Double], critical: Double) -> some View {
        let level = value.map { Level.load($0, high: settings.loadHigh, critical: critical) } ?? .ok
        let chart = LoadBarChart(values: history, high: settings.loadHigh, critical: critical, bars: 16, gap: 1.5)
        return Tile(title: title, icon: icon, warning: monitor.warnings.contains(area),
                    backdrop: AnyView(chart), padding: segmentPadding) {
            Text(value.map { String(format: "%.0f %%", $0) } ?? "n. v.")
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.textSecondary : (level == .ok ? Theme.textPrimary : level.color))
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(height: 20)
        }
    }

    private var thermalSegment: some View {
        let state = monitor.thermalState
        let (label, color): (String, Color) = {
            switch state {
            case .nominal: return ("Normal", Theme.textPrimary)
            case .fair: return ("Erhöht", Theme.orange)
            case .serious: return ("Hoch", Theme.warning)
            case .critical: return ("Kritisch", Theme.warning)
            @unknown default: return ("–", Theme.textSecondary)
            }
        }()
        return Tile(title: "Thermik", icon: "thermometer.medium",
                    warning: monitor.warnings.contains(.thermal), padding: segmentPadding) {
            Text(label)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(height: 20)
        }
    }

    private var controlSegment: some View {
        Tile(title: "Laden \(settings.lowerLimit)–\(charger.effectiveUpperLimit) %", icon: "powerplug.fill",
             warning: monitor.warnings.contains(.plug), interactive: true, padding: segmentPadding) {
            HStack(spacing: 5) {
                Toggle("", isOn: $settings.automationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.accent)
                    .help("Ladeautomatik")
                let powered = PowerIndicator.isOn(monitor)
                IconButton(icon: "bolt.fill",
                           help: powered ? "Netzbetrieb – Strom fließt" : "Strom ein (pausiert Automatik 30 min)",
                           highlighted: powered, activeColor: PowerIndicator.onColor,
                           pulsing: PowerIndicator.switching(to: true, charger)) { charger.manualSwitch(true) }
                IconButton(icon: "bolt.slash.fill",
                           help: !powered ? "Akkubetrieb – kein Strom" : "Strom aus (pausiert Automatik 30 min)",
                           highlighted: !powered, activeColor: PowerIndicator.offColor,
                           pulsing: PowerIndicator.switching(to: false, charger)) { charger.manualSwitch(false) }
                IconButton(icon: "battery.100.bolt", help: "Einmalig auf 100 % laden",
                           highlighted: charger.fullChargeOnce) { charger.startFullChargeOnce() }
                IconButton(icon: "gearshape.fill", help: updater.updateAvailable ? "Update verfügbar" : "Einstellungen",
                           badge: updater.updateAvailable, action: openSettings)
            }
            .frame(height: 20)
        }
    }

    private func shortStatus(_ b: BatteryReading) -> String {
        if !b.hasBattery { return "Kein Akku" }
        if b.isCharging {
            if let m = b.minutesToFull { return "Lädt · \(m / 60):\(String(format: "%02d", m % 60))" }
            return "Lädt"
        }
        if b.externalPower { return b.fullyCharged ? "Voll" : "Pausiert" }
        if let m = b.minutesToEmpty { return "Akku · \(m / 60):\(String(format: "%02d", m % 60))" }
        return "Akkubetrieb"
    }
}

/// Kleiner quadratischer Symbol-Button für die Leiste.
struct IconButton: View {
    let icon: String
    let help: String
    var highlighted = false
    var activeColor: Color = Theme.accent
    var pulsing = false
    var badge = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .foregroundStyle(highlighted ? Color.black : Theme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlighted ? activeColor : Color.white.opacity(hover ? 0.14 : 0.07))
                )
                .shadow(color: highlighted ? activeColor.opacity(0.55) : .clear, radius: 5)
                .modifier(Pulse(active: pulsing))
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 1, y: -1) }
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
