import SwiftUI
import AppKit

enum Theme {
    static let background = Color(red: 0.07, green: 0.075, blue: 0.09)
    static let card = Color(red: 0.12, green: 0.125, blue: 0.145)
    static let stroke = Color.white.opacity(0.07)
    static let accent = Color(red: 0.27, green: 0.89, blue: 0.42)      // Logo-Grün
    static let accentDim = Color(red: 0.16, green: 0.55, blue: 0.27)
    static let warning = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.2)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.55)
    static let splash = Color(red: 0.17, green: 0.17, blue: 0.19)     // dunkelgrau
}

/// Karte mit optionaler Überlastungswarnung (roter Rahmen + ‼️).
struct Tile<Content: View>: View {
    let title: String
    var icon: String? = nil
    var warning: Bool = false
    /// false = reine Anzeige: Klicks gehen an die Ziehfläche, damit das Widget überall verschiebbar ist.
    var interactive: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                Spacer(minLength: 0)
                if warning {
                    Text("‼️").font(.system(size: 11))
                        .scaleEffect(pulse ? 1.15 : 0.9)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                        }
                        .onDisappear { pulse = false }
                        .help("Überlastung")
                }
            }
            .foregroundStyle(warning ? Theme.warning : Theme.textSecondary)
            .allowsHitTesting(warning) // ‼️ zeigt Tooltip
            content()
                .allowsHitTesting(interactive)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(warning ? Theme.warning.opacity(0.13) : Theme.card)
                WindowDragArea()
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(warning ? Theme.warning.opacity(0.9) : Theme.stroke, lineWidth: warning ? 1.5 : 1)
        )
        .animation(.easeInOut(duration: 0.25), value: warning)
    }
}

/// Kleiner Verlaufsgraph (z. B. CPU der letzten 2 Minuten).
struct Sparkline: View {
    let values: [Double]   // 0…100
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(SystemMonitor.historyLength - 1)
        let offset = CGFloat(SystemMonitor.historyLength - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100))
        }
    }
}

/// Horizontaler Balken 0…100 %.
struct Meter: View {
    let value: Double
    var color: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(height, geo.size.width * CGFloat(min(max(value, 0), 100)) / 100))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

/// Erlaubt das Verschieben des randlosen Widgets per Ziehen auf freien Flächen.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            menu = window?.menu
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Schriftzug "MacCharge" im Stil des Logos.
struct BrandText: View {
    var size: CGFloat = 13
    var body: some View {
        (Text("Mac").foregroundColor(.white) + Text("Charge").foregroundColor(Theme.accent))
            .font(.system(size: size, weight: .bold, design: .rounded))
    }
}

// MARK: - Ampelfarben

enum Level {
    case ok, high, critical

    var color: Color {
        switch self {
        case .ok: return Theme.accent
        case .high: return Theme.orange
        case .critical: return Theme.warning
        }
    }

    /// Auslastung: grün < hoch ≤ orange < kritisch ≤ rot
    static func load(_ value: Double, high: Double, critical: Double) -> Level {
        if value >= critical { return .critical }
        if value >= high { return .high }
        return .ok
    }

    /// Akku: ≥ 40 % grün, 20–39 % orange, < 20 % rot
    static func battery(_ percent: Int) -> Level {
        if percent < BatteryThresholds.red { return .critical }
        if percent < BatteryThresholds.orange { return .high }
        return .ok
    }
}

enum BatteryThresholds {
    static let orange = 40
    static let red = 20
    /// Ab hier blinkt im Akkufeld die Warnung "LADEN".
    static let chargeNow = 15
}

extension Theme {
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
}

/// Balkendiagramm des Verlaufs: jeder Balken in seiner Ampelfarbe.
struct LoadBarChart: View {
    let values: [Double]          // 0…100, ältester zuerst
    let high: Double
    let critical: Double
    var bars: Int = 24            // ≈ 48 s bei 2-s-Takt

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 1.5
            let barWidth = max(1, (geo.size.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
            let recent = Array(values.suffix(bars))
            let padding = bars - recent.count
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<bars, id: \.self) { i in
                    let value = i >= padding ? recent[i - padding] : nil
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(value.map { Level.load($0, high: high, critical: critical).color } ?? Color.white.opacity(0.06))
                        .opacity(value == nil ? 1 : (i == bars - 1 ? 1 : 0.85))
                        .frame(width: barWidth,
                               height: max(2, geo.size.height * CGFloat(min(max(value ?? 0, 0), 100)) / 100))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            .background(alignment: .bottom) {
                // Hilfslinien für orange/rot
                ZStack(alignment: .bottom) {
                    guide(at: high, height: geo.size.height, color: Theme.orange)
                    guide(at: critical, height: geo.size.height, color: Theme.warning)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: values.last ?? 0)
    }

    private func guide(at value: Double, height: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color.opacity(0.25))
            .frame(height: 0.5)
            .offset(y: -height * CGFloat(value) / 100)
    }
}

/// Blinkender roter Hinweis "⚠️ LADEN".
struct BlinkingChargeWarning: View {
    @State private var on = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("LADEN")
        }
        .font(.system(size: 11, weight: .heavy))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Theme.warning))
        .opacity(on ? 1 : 0.25)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
        }
        .help("Akku kritisch – bitte laden")
    }
}
