import Foundation

/// Akkuverlauf der letzten 24 Stunden (1 Messpunkt pro Minute plus jeder Netzteilwechsel).
/// Wird in ~/Library/Application Support/MacCharge/history.json gespeichert und übersteht Neustarts.
@MainActor
final class BatteryHistory: ObservableObject {
    struct Sample: Codable, Equatable {
        let t: Date
        let p: Int      // Ladestand %
        let ac: Bool    // Netzteil liefert Strom (Steckdose an)
    }

    static let window: TimeInterval = 24 * 3600
    private static let interval: TimeInterval = 60

    @Published private(set) var samples: [Sample] = []

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacCharge/history.json")
    }()
    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            samples = Self.demoSamples()
        } else {
            load()
        }
    }

    func record(_ battery: BatteryReading) {
        guard battery.hasBattery, !demo else { return }
        let now = Date()
        if let last = samples.last,
           last.ac == battery.externalPower,
           now.timeIntervalSince(last.t) < Self.interval {
            return
        }
        samples.append(Sample(t: now, p: battery.percent, ac: battery.externalPower))
        samples.removeAll { now.timeIntervalSince($0.t) > Self.window }
        save()
    }

    /// Zeitpunkte, an denen das Netzteil an- bzw. abgeschaltet wurde (= Steckdose geschaltet).
    var switchEvents: [(t: Date, on: Bool)] {
        var events: [(Date, Bool)] = []
        for (a, b) in zip(samples, samples.dropFirst()) where a.ac != b.ac {
            events.append((b.t, b.ac))
        }
        return events
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Sample].self, from: data) else { return }
        let now = Date()
        samples = decoded.filter { now.timeIntervalSince($0.t) <= Self.window }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(samples).write(to: fileURL, options: .atomic)
        } catch {
            Log.info("Verlauf konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    /// Simulierter Tagesverlauf (20 % ↔ 85 %) für den Demo-Modus.
    private static func demoSamples() -> [Sample] {
        var result: [Sample] = []
        var p = 60.0
        var ac = false
        let start = Date().addingTimeInterval(-window)
        for minute in stride(from: 0, to: Int(window / 60), by: 5) {
            p += ac ? 1.6 : -0.45
            if p >= 85 { p = 85; ac = false }
            if p <= 20 { p = 20; ac = true }
            result.append(Sample(t: start.addingTimeInterval(Double(minute) * 60), p: Int(p), ac: ac))
        }
        return result
    }
}
