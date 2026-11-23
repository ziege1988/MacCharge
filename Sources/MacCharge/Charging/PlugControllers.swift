import Foundation

struct PlugStatus {
    var isOn: Bool?
    var powerWatts: Double?
}

enum PlugError: LocalizedError {
    case notConfigured(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .commandFailed(let s): return s
        }
    }
}

protocol PlugController {
    func setPower(_ on: Bool) async throws
    /// Optional: Zustand direkt von der Steckdose lesen (nil = nicht unterstützt).
    func status() async throws -> PlugStatus?
}

// MARK: - Apple Home über Kurzbefehle

/// Schaltet die Steckdose über zwei Kurzbefehle der macOS-Kurzbefehle-App
/// (Aktion "Zuhause steuern"). Funktioniert mit jeder HomeKit-Steckdose,
/// ohne Cloud-Konto, ohne Kosten und ohne Apple-Entwicklerzugang.
struct ShortcutsPlug: PlugController {
    let onName: String
    let offName: String

    func setPower(_ on: Bool) async throws {
        let name = (on ? onName : offName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw PlugError.notConfigured("Kein Kurzbefehl-Name hinterlegt") }
        try await Self.run(["run", name])
    }

    func status() async throws -> PlugStatus? { nil }

    static func availableShortcuts() async -> [String] {
        (try? await run(["list"]))?
            .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty } ?? []
    }

    @discardableResult
    private static func run(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { p in
                let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    let msg = error.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: PlugError.commandFailed(msg.isEmpty ? "Kurzbefehl fehlgeschlagen (\(p.terminationStatus))" : msg))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - Refoss Open API (lokal)

/// Refoss-Geräte mit "Open API" (z. B. P11S) sprechen JSON-RPC im lokalen Netz.
/// Methoden laut offizieller Home-Assistant-Integration von Refoss:
///   Switch.Action.Set {id, action: on|off|toggle}, Refoss.Status.Get → "switch:<id>": {output, apower}
final class RefossPlug: NSObject, PlugController, URLSessionTaskDelegate {
    let host: String
    let switchID: Int
    let user: String
    let password: String
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(host: String, switchID: Int, user: String, password: String) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.switchID = switchID
        self.user = user
        self.password = password
    }

    func setPower(_ on: Bool) async throws {
        _ = try await call("Switch.Action.Set", params: ["id": switchID, "action": on ? "on" : "off"])
    }

    func status() async throws -> PlugStatus? {
        let result = try await call("Refoss.Status.Get", params: [:])
        guard let sw = result["switch:\(switchID)"] as? [String: Any] else {
            throw PlugError.commandFailed("Kanal switch:\(switchID) nicht gefunden")
        }
        return PlugStatus(isOn: sw["output"] as? Bool, powerWatts: (sw["apower"] as? NSNumber)?.doubleValue)
    }

    func deviceInfo() async throws -> [String: Any] {
        try await call("Refoss.DeviceInfo.Get", params: [:])
    }

    /// Versucht zuerst HTTP GET /rpc/<Methode>?..., danach JSON-RPC per POST /rpc.
    private func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard !host.isEmpty else { throw PlugError.notConfigured("Keine IP-Adresse der Steckdose hinterlegt") }
        do {
            return try await callGET(method, params: params)
        } catch {
            return try await callPOST(method, params: params)
        }
    }

    private func callGET(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.path = "/rpc/\(method)"
        if !params.isEmpty {
            comps.queryItems = params.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }
        guard let url = comps.url else { throw PlugError.notConfigured("Ungültige Adresse: \(host)") }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func callPOST(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "http://\(host)/rpc") else { throw PlugError.notConfigured("Ungültige Adresse: \(host)") }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["id": 1, "src": "maccharge", "method": method]
        if !params.isEmpty { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlugError.commandFailed("Keine Antwort") }
        guard (200..<300).contains(http.statusCode) else {
            throw PlugError.commandFailed(http.statusCode == 401 ? "Anmeldung abgelehnt (401)" : "HTTP \(http.statusCode)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] {
            throw PlugError.commandFailed("Gerät meldet Fehler: \(error["message"] ?? error)")
        }
        return (json["result"] as? [String: Any]) ?? json
    }

    // HTTP-Digest/Basic-Anmeldung, falls in der Refoss-App ein Passwort gesetzt ist.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !password.isEmpty, challenge.previousFailureCount == 0 {
            let name = user.isEmpty ? "admin" : user
            completionHandler(.useCredential, URLCredential(user: name, password: password, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
