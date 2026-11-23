import AppKit

/// Randloses, frei verschiebbares Widget-Fenster. Kann auf jeden angeschlossenen
/// Bildschirm gezogen werden. Die Position wird je Darstellung (Hochformat / Leiste)
/// getrennt gespeichert und beim Start wiederhergestellt.
final class WidgetWindow: NSPanel {
    private(set) var layout: WidgetLayout
    private var isApplyingLayout = false

    init(layout: WidgetLayout) {
        self.layout = layout
        super.init(contentRect: NSRect(origin: .zero, size: layout.size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isMovableByWindowBackground = false  // Verschieben übernimmt WindowDragArea (Buttons bleiben klickbar)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        restorePosition()

        NotificationCenter.default.addObserver(self, selector: #selector(savePosition),
                                               name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Hochformat: "widgetOrigin" (kompatibel zu 1.0), Leiste: "widgetOrigin.bar".
    private func originKey(_ layout: WidgetLayout) -> String {
        layout == .tall ? "widgetOrigin" : "widgetOrigin.\(layout.rawValue)"
    }

    func applyBehavior(alwaysOnTop: Bool, allSpaces: Bool) {
        level = alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(allSpaces ? .canJoinAllSpaces : .managed)
        collectionBehavior = behavior
    }

    /// Wechselt die Darstellung: neue Größe an der für diese Darstellung gespeicherten Position.
    func apply(layout newLayout: WidgetLayout) {
        guard newLayout != layout else { return }
        savePosition()
        layout = newLayout
        restorePosition()
    }

    @objc private func savePosition() {
        guard !isApplyingLayout else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        UserDefaults.standard.set([topLeft.x, topLeft.y], forKey: originKey(layout))
    }

    private func restorePosition() {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let size = layout.size
        if let values = UserDefaults.standard.array(forKey: originKey(layout)) as? [Double], values.count == 2 {
            let rect = NSRect(x: values[0], y: values[1] - size.height, width: size.width, height: size.height)
            if isVisibleOnSomeScreen(rect) {
                setFrame(rect, display: true, animate: false)
                return
            }
        }
        placeDefault()
    }

    /// Mindestens 60 % des Widgets müssen auf einem Bildschirm sichtbar sein,
    /// sonst (z. B. externer Monitor abgesteckt) wird es auf den Hauptbildschirm geholt.
    private func isVisibleOnSomeScreen(_ rect: NSRect) -> Bool {
        let area = rect.width * rect.height
        return NSScreen.screens.contains { screen in
            let i = screen.visibleFrame.intersection(rect)
            return !i.isNull && (i.width * i.height) >= area * 0.6
        }
    }

    private func placeDefault() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let size = layout.size
        let origin: NSPoint
        switch layout {
        case .tall:
            origin = NSPoint(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 20)
        case .bar:
            // oben mittig, direkt unter der Menüleiste
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 6)
        }
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    @objc private func screensChanged() {
        if !isVisibleOnSomeScreen(frame) { placeDefault() }
    }

    func resetPosition() {
        placeDefault()
        savePosition()
    }
}
