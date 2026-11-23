import AppKit

/// Randloses, frei verschiebbares Widget-Fenster. Kann auf jeden angeschlossenen
/// Bildschirm gezogen werden; die Position wird gespeichert und beim Start wiederhergestellt.
final class WidgetWindow: NSPanel {
    static let size = NSSize(width: 288, height: 476)
    private static let originKey = "widgetOrigin"     // obere linke Ecke (x, y) in globalen Koordinaten
    private static let screenKey = "widgetScreen"     // Name des Bildschirms (Information/Fallback)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
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

    func applyBehavior(alwaysOnTop: Bool, allSpaces: Bool) {
        level = alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(allSpaces ? .canJoinAllSpaces : .managed)
        collectionBehavior = behavior
    }

    @objc private func savePosition() {
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        UserDefaults.standard.set([topLeft.x, topLeft.y], forKey: Self.originKey)
        UserDefaults.standard.set(screen?.localizedName, forKey: Self.screenKey)
    }

    private func restorePosition() {
        if let values = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], values.count == 2 {
            let topLeft = NSPoint(x: values[0], y: values[1])
            let rect = NSRect(x: topLeft.x, y: topLeft.y - Self.size.height, width: Self.size.width, height: Self.size.height)
            if isVisibleOnSomeScreen(rect) {
                setFrame(rect, display: false)
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
        setFrameOrigin(NSPoint(x: vf.maxX - Self.size.width - 20, y: vf.maxY - Self.size.height - 20))
    }

    @objc private func screensChanged() {
        if !isVisibleOnSomeScreen(frame) { placeDefault() }
    }

    func resetPosition() {
        placeDefault()
        savePosition()
    }
}
