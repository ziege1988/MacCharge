import AppKit

/// Kostenlose Update-Funktion über GitHub Releases des öffentlichen Repositorys.
/// Ablauf: Release prüfen → ZIP laden → entpacken → App ersetzen → Neustart.
@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }
        var zipAsset: Asset? { assets.first { $0.name.hasSuffix(".zip") } }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: Release?
    @Published private(set) var lastCheck: Date?

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest.version, than: AppInfo.version)
    }

    private let settings: AppSettings
    private var timer: Timer?
    private var downloadObservation: NSKeyValueObservation?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        if settings.autoCheckUpdates {
            Task { await check() }
        }
        // alle 6 Stunden erneut prüfen
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.settings.autoCheckUpdates else { return }
                await self.check()
            }
        }
    }

    func check() async {
        state = .checking
        let url = URL(string: "https://api.github.com/repos/\(AppInfo.repoOwner)/\(AppInfo.repoName)/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacCharge-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastCheck = Date()
            if code == 404 {
                latest = nil
                state = .upToDate // noch kein Release veröffentlicht
                return
            }
            guard code == 200 else { throw PlugError.commandFailed("GitHub antwortet mit HTTP \(code)") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release
            state = updateAvailable ? .available : .upToDate
        } catch {
            state = .failed("Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func installUpdate() async {
        guard let release = latest, let asset = release.zipAsset else {
            state = .failed("Im Release wurde keine ZIP-Datei gefunden.")
            return
        }
        let appURL = Bundle.main.bundleURL
        if appURL.path.contains("/AppTranslocation/") {
            state = .failed("Bitte MacCharge zuerst in den Ordner „Programme“ verschieben und neu starten.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("Keine Schreibrechte für \(appURL.deletingLastPathComponent().path).")
            return
        }

        do {
            state = .downloading(0)
            let zipURL = try await download(asset.browser_download_url)

            state = .installing
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacChargeUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, work.path])

            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw PlugError.commandFailed("Die ZIP-Datei enthält keine App.")
            }
            try relaunch(replacing: appURL, with: newApp)
        } catch {
            state = .failed("Update fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: PlugError.commandFailed("Download fehlgeschlagen"))
                    return
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MacCharge-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            downloadObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in self?.state = .downloading(value) }
            }
            task.resume()
        }
    }

    /// Startet ein kleines Hilfsskript, das wartet bis MacCharge beendet ist,
    /// die App austauscht (mit Rücksicherung) und die neue Version startet.
    private func relaunch(replacing current: URL, with newApp: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; SRC="$2"; DST="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$DST.old"
        if mv "$DST" "$DST.old" && /usr/bin/ditto "$SRC" "$DST"; then
            rm -rf "$DST.old"
        else
            rm -rf "$DST"; mv "$DST.old" "$DST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null
        /usr/bin/open "$DST"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("maccharge-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, "\(ProcessInfo.processInfo.processIdentifier)", newApp.path, current.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PlugError.commandFailed("\(tool) fehlgeschlagen") }
    }

    /// Vergleicht Versionsnummern wie 1.2.10 numerisch.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
