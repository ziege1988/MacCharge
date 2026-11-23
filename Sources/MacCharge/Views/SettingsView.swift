import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        TabView {
            ChargingSettings().tabItem { Label("Laden", systemImage: "battery.75") }
            PlugSettings().tabItem { Label("Steckdose", systemImage: "powerplug") }
            WarningSettings().tabItem { Label("Warnungen", systemImage: "exclamationmark.triangle") }
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            UpdateSettings().tabItem {
                Label(updater.updateAvailable ? "Update ●" : "Updates", systemImage: "arrow.down.circle")
            }
        }
        .padding(16)
        .frame(width: 520, height: 470)
    }
}

// MARK: - Laden

private struct ChargingSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var charger: ChargeController

    var body: some View {
        Form {
            Section {
                Toggle("Ladeautomatik aktiv", isOn: $settings.automationEnabled)
                LabeledContent("Laden AUS bei") {
                    Stepper("\(settings.upperLimit) %", value: $settings.upperLimit, in: (settings.lowerLimit + 5)...100, step: 5)
                }
                Slider(value: Binding(get: { Double(settings.upperLimit) },
                                      set: { settings.upperLimit = max(Int($0), settings.lowerLimit + 5) }),
                       in: 50...100, step: 1)
                LabeledContent("Laden EIN bei") {
                    Stepper("\(settings.lowerLimit) %", value: $settings.lowerLimit, in: 5...(settings.upperLimit - 5), step: 5)
                }
                Slider(value: Binding(get: { Double(settings.lowerLimit) },
                                      set: { settings.lowerLimit = min(Int($0), settings.upperLimit - 5) }),
                       in: 5...60, step: 1)
            } header: {
                Text("Ladegrenzen")
            } footer: {
                Text("Erreicht der Akku die obere Grenze, wird die Steckdose ausgeschaltet. Fällt er auf die untere Grenze, wird sie wieder eingeschaltet. Dazwischen wird nicht geschaltet. Empfehlung für die Akkulebensdauer: 20–80 %.")
                    .foregroundStyle(.secondary)
            }
            Section("Aktionen") {
                HStack {
                    Button("Jetzt prüfen & schalten") { Task { await charger.evaluate() } }
                    Button("Einmalig auf 100 % laden") { charger.startFullChargeOnce() }
                }
                Text("Manuelles Ein/Aus im Widget pausiert die Automatik für \(Int(ChargeController.manualHoldMinutes)) Minuten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Steckdose

private struct PlugSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var charger: ChargeController
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Verbindung") {
                Picker("Steuerung über", selection: $settings.backend) {
                    ForEach(PlugBackend.allCases) { Text($0.title).tag($0) }
                }
            }
            switch settings.backend {
            case .shortcuts:
                Section {
                    TextField("Kurzbefehl „Einschalten“", text: $settings.shortcutOn)
                    TextField("Kurzbefehl „Ausschalten“", text: $settings.shortcutOff)
                } header: {
                    Text("Apple Home (HomeKit)")
                } footer: {
                    Text("Lege in der Kurzbefehle-App zwei Kurzbefehle mit der Aktion „Zuhause steuern“ an, die deine Refoss-Steckdose ein- bzw. ausschalten, und benenne sie wie oben. Kostenlos, ohne Cloud-Konto.")
                        .foregroundStyle(.secondary)
                }
            case .refossLocal:
                Section {
                    TextField("IP-Adresse (z. B. 192.168.178.50)", text: $settings.refossHost)
                    Stepper("Kanal (switch-ID): \(settings.refossSwitchID)", value: $settings.refossSwitchID, in: 0...8)
                    TextField("Benutzer (optional)", text: $settings.refossUser)
                    SecureField("Passwort (optional)", text: $settings.refossPassword)
                } header: {
                    Text("Refoss Open API")
                } footer: {
                    Text("Nur für Refoss-Geräte mit „Open API“ (z. B. P11S). Lokale Steuerung im WLAN, liefert zusätzlich die Leistungsaufnahme in Watt. Tipp: Gib der Steckdose im Router eine feste IP.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Test") {
                HStack {
                    Button(testing ? "Teste …" : "Verbindung testen") {
                        testing = true
                        Task {
                            testResult = await charger.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    Button("Strom EIN") { charger.manualSwitch(true) }
                    Button("Strom AUS") { charger.manualSwitch(false) }
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.callout)
                        .foregroundStyle(testResult.hasPrefix("‼️") ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Warnungen

private struct WarningSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                threshold("CPU-Auslastung", value: $settings.cpuWarn, range: 50...100, unit: "%")
                threshold("GPU-Auslastung", value: $settings.gpuWarn, range: 50...100, unit: "%")
                threshold("Arbeitsspeicher", value: $settings.ramWarn, range: 50...100, unit: "%")
                threshold("Akkutemperatur", value: $settings.batteryTempWarn, range: 30...60, unit: "°C")
                threshold("Leistung Steckdose", value: $settings.plugPowerWarn, range: 30...3500, unit: "W", step: 10)
                threshold("Verzögerung", value: $settings.warnDelay, range: 0...60, unit: "s")
            } header: {
                Text("Schwellwerte für ‼️-Warnungen")
            } footer: {
                Text("Wird ein Wert länger als die Verzögerung überschritten, färbt sich der jeweilige Bereich im Widget rot und zeigt ‼️. Thermische Drosselung und Steckdosenfehler werden sofort angezeigt.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func threshold(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, step: Double = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 200)
                Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}

// MARK: - Allgemein

private struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Start & Fenster") {
                Toggle("Beim Anmelden automatisch starten", isOn: $settings.launchAtLogin)
                Toggle("Widget immer im Vordergrund", isOn: $settings.alwaysOnTop)
                Toggle("Auf allen Schreibtischen (Spaces) anzeigen", isOn: $settings.showOnAllSpaces)
                LabeledContent("Deckkraft") {
                    Slider(value: $settings.widgetOpacity, in: 0.5...1.0).frame(width: 220)
                }
            }
            Section {
                Text("Das Widget lässt sich mit der Maus frei auf jeden angeschlossenen Bildschirm ziehen. Die Position wird gespeichert und beim nächsten Start wiederhergestellt. Rechtsklick auf das Widget oder das Menüleisten-Symbol öffnet weitere Optionen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        Form {
            Section("Version") {
                LabeledContent("Installiert", value: "\(AppInfo.version) (\(AppInfo.build))")
                if let latest = updater.latest {
                    LabeledContent("Neueste", value: latest.version)
                }
                if let last = updater.lastCheck {
                    LabeledContent("Zuletzt geprüft", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Automatisch nach Updates suchen", isOn: $settings.autoCheckUpdates)
            }
            Section("Status") {
                stateView
                HStack {
                    Button("Jetzt suchen") { Task { await updater.check() } }
                        .disabled(isBusy)
                    if updater.updateAvailable {
                        Button("Jetzt aktualisieren & neu starten") { Task { await updater.installUpdate() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accentDim)
                            .disabled(isBusy)
                    }
                }
            }
            if updater.updateAvailable, let notes = updater.latest?.body, !notes.isEmpty {
                Section("Neuerungen in \(updater.latest?.version ?? "")") {
                    ScrollView {
                        Text(notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    @ViewBuilder private var stateView: some View {
        switch updater.state {
        case .idle: Text("Noch nicht geprüft").foregroundStyle(.secondary)
        case .checking: HStack { ProgressView().controlSize(.small); Text("Suche nach Updates …") }
        case .upToDate: Text("✅ MacCharge ist aktuell.")
        case .available: Text("⬆️ Version \(updater.latest?.version ?? "") ist verfügbar.").bold()
        case .downloading(let p): ProgressView("Lade herunter …", value: p)
        case .installing: HStack { ProgressView().controlSize(.small); Text("Installiere – MacCharge startet gleich neu …") }
        case .failed(let msg): Text("‼️ \(msg)").foregroundStyle(.red)
        }
    }
}
