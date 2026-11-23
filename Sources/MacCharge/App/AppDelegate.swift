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
