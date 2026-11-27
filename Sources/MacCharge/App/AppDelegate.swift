import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    private(set) lazy var monitor = SystemMonitor(settings: settings)
    private(set) lazy var charger = ChargeController(settings: settings, monitor: monitor)
    private(set) lazy var updater = UpdateManager(settings: settings)

    private var widget: WidgetWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let powerEvents = PowerEvents()

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.normalizeLimits()

        monitor.plugPowerProvider = { [weak self] in self?.charger.plugPower }
        monitor.plugFaultProvider = { [weak self] in
            guard let self else { return false }
            if self.charger.plugUnreachable { return true }
            if case .error = self.charger.phase { return true }
            return false
        }

        monitor.start()
        charger.start()
        updater.start()
        LaunchAtLogin.apply(settings.launchAtLogin)

        setupWidget()
        setupStatusItem()
        observeSettings()
        setupPowerEvents()
    }

    // MARK: Herunterfahren & Ruhezustand

    /// Einmaliger Abschaltvorgang beim Herunterfahren (wird von allen Signalen gemeinsam genutzt,
    /// damit ein Umschalt-Kurzbefehl nie doppelt ausgeführt wird).
    private var shutdownTask: Task<Void, Never>?

    private func setupPowerEvents() {
        Log.info("MacCharge \(AppInfo.version) gestartet")
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willPowerOff(_:)),
                                                          name: NSWorkspace.willPowerOffNotification, object: nil)

        powerEvents.onWillSleep = { [weak self] done in
            Task { @MainActor in
                guard let self else { done(); return }
                let b = self.monitor.battery
                Log.info("Ruhezustand angekündigt (Netzbetrieb=\(b.externalPower), Akku \(b.percent) %)")
                // Nicht abschalten, wenn der Akku ohnehin niedrig ist – sonst wacht man mit leerem Akku auf
                if self.settings.offOnSleep, b.externalPower, b.percent > self.settings.lowerLimit {
                    await self.charger.switchOffForPowerEvent(reason: "Ruhezustand → Strom aus", timeout: 15)
                }
                done()
            }
        }
        powerEvents.onDidWake = { [weak self] in
            Task { @MainActor in
                Log.info("Aufgewacht – Automatik prüft neu")
                self?.charger.didWake()
            }
        }
        powerEvents.start()
    }

    /// Erstes Signal beim Herunterfahren/Neustart/Abmelden: sofort abschalten, solange
    /// WLAN, Home-Dienste und Kurzbefehle noch laufen.
    @objc private func willPowerOff(_ note: Notification) {
        Log.info("macOS meldet: Herunterfahren / Neustart / Abmelden")
        startShutdownSwitchOff(trigger: "Herunterfahren")
    }

    private func startShutdownSwitchOff(trigger: String) {
        guard shutdownTask == nil else { return }
        guard settings.offOnShutdown else {
            Log.info("Abschalten beim Herunterfahren ist in den Einstellungen deaktiviert")
            shutdownTask = Task {}
            return
        }
        shutdownTask = Task { @MainActor in
            await self.charger.switchOffForPowerEvent(reason: "\(trigger) → Strom aus", timeout: 20)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = Self.quitReason()
        Log.info("Beenden angefordert (Grund: \(reason ?? "MacCharge beenden"))")
        // Nur beim Herunterfahren/Neustart/Abmelden – nicht beim normalen Beenden oder bei Updates
        if reason != nil { startShutdownSwitchOff(trigger: reason!) }
        guard let task = shutdownTask else { return .terminateNow }
        Task { @MainActor in
            await task.value
            Log.info("Bereit zum Beenden")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Liest aus der Quit-Anfrage von macOS, ob heruntergefahren/neu gestartet/abgemeldet wird.
    private static func quitReason() -> String? {
        func code(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let value = event.attributeDescriptor(forKeyword: code("why?"))?.enumCodeValue else { return nil }
        switch value {
        case code("shut"): return "Herunterfahren"
        case code("rest"): return "Neustart"
        case code("rlgo"), code("logo"): return "Abmelden"
        default: return nil
        }
    }

    /// Sicherer Weg: erst Strom aus (bestätigt), dann den Mac über macOS herunterfahren.
    @objc private func shutDownWithPowerOff() {
        Log.info("„Strom aus & Mac ausschalten“ gewählt")
        shutdownTask = Task { @MainActor in
            await self.charger.switchOffForPowerEvent(reason: "Ausschalten über MacCharge → Strom aus", timeout: 20)
        }
        Task { @MainActor in
            await self.shutdownTask?.value
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
            if let error {
                Log.info("Herunterfahren fehlgeschlagen: \(error)")
                let alert = NSAlert()
                alert.messageText = "Der Mac konnte nicht heruntergefahren werden"
                alert.informativeText = "Bitte MacCharge unter Systemeinstellungen → Datenschutz & Sicherheit → Automation erlauben, „System Events“ zu steuern. Die Steckdose wurde bereits abgeschaltet."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                self.shutdownTask = nil
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget()
        return true
    }

    // MARK: Widget

    private func setupWidget() {
        let window = WidgetWindow(layout: settings.layout)
        window.contentView = makeHostingView(layout: settings.layout, splash: true)
        window.menu = contextMenu()
        window.contentView?.menu = window.menu
        window.applyBehavior(levelMode: settings.windowLevel, allSpaces: settings.showOnAllSpaces)
        window.alphaValue = settings.widgetOpacity
        window.orderFrontRegardless()
        widget = window

        // Nur für automatisierte Tests: Darstellung zur Laufzeit umschalten
        if ProcessInfo.processInfo.environment["MACCHARGE_TEST_TOGGLE_LAYOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.toggleLayout() }
        }
    }

    /// Baut die SwiftUI-Ansicht für eine Darstellung. Die Fenstergröße bestimmt allein
    /// WidgetWindow (sizingOptions = []), sonst würde SwiftUI das Fenster auf die alte Größe festnageln.
    private func makeHostingView(layout: WidgetLayout, splash: Bool) -> NSView {
        let root = RootView(layout: layout, showSplash: splash,
                            openSettings: { [weak self] in self?.openSettings() })
            .environmentObject(settings)
            .environmentObject(monitor)
            .environmentObject(charger)
            .environmentObject(updater)
            .environmentObject(monitor.history)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: layout.size)
        hosting.autoresizingMask = [.width, .height]
        hosting.appearance = NSAppearance(named: .darkAqua)
        return hosting
    }

    private func switchLayout(to layout: WidgetLayout) {
        guard let widget, widget.layout != layout else { return }
        let hosting = makeHostingView(layout: layout, splash: false)
        hosting.menu = widget.menu
        widget.contentView = hosting
        widget.apply(layout: layout)
        widget.orderFrontRegardless()
    }

    @objc func showWidget() {
        widget?.orderFrontRegardless()
    }

    @objc private func toggleWidget() {
        guard let widget else { return }
        widget.isVisible ? widget.orderOut(nil) : widget.orderFrontRegardless()
    }

    @objc private func toggleLayout() {
        settings.layout = settings.layout == .tall ? .bar : .tall
    }

    @objc private func resetWidgetPosition() {
        widget?.resetPosition()
        widget?.orderFrontRegardless()
    }

    // MARK: Einstellungen

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(settings)
                .environmentObject(charger)
                .environmentObject(updater)
                .environmentObject(monitor)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "MacCharge Einstellungen"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menü

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Widget ein-/ausblenden", action: #selector(toggleWidget), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Darstellung wechseln (Widget/Leiste)", action: #selector(toggleLayout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Widget-Position zurücksetzen", action: #selector(resetWidgetPosition), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Strom aus & Mac ausschalten …", action: #selector(shutDownWithPowerOff), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "MacCharge beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: "MacCharge")
        item.button?.imagePosition = .imageLeading
        item.menu = contextMenu()
        statusItem = item

        // Akkustand in der Menüleiste
        monitor.$battery
            .map { $0.hasBattery ? "\($0.percent) %" : "" }
            .removeDuplicates()
            .sink { [weak item] text in item?.button?.title = text }
            .store(in: &cancellables)
    }

    private func observeSettings() {
        settings.$windowLevel.combineLatest(settings.$showOnAllSpaces)
            .dropFirst()
            .sink { [weak self] mode, spaces in self?.widget?.applyBehavior(levelMode: mode, allSpaces: spaces) }
            .store(in: &cancellables)
        settings.$layout
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] layout in self?.switchLayout(to: layout) }
            .store(in: &cancellables)
        settings.$widgetOpacity
            .dropFirst()
            .sink { [weak self] value in self?.widget?.alphaValue = value }
            .store(in: &cancellables)
        settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { LaunchAtLogin.apply($0) }
            .store(in: &cancellables)
    }
}
