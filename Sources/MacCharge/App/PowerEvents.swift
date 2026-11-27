import Foundation
import IOKit
import IOKit.pwr_mgt

/// Meldet Ruhezustand und Aufwachen des Macs über IOKit.
/// Anders als die NSWorkspace-Benachrichtigung darf hier der Schlaf kurz aufgehalten werden
/// (max. ca. 30 s), damit der Kurzbefehl die Steckdose noch sicher abschalten kann.
final class PowerEvents {
    /// Wird vor dem Einschlafen aufgerufen; `done()` muss aufgerufen werden, damit der Mac schläft.
    var onWillSleep: ((_ done: @escaping () -> Void) -> Void)?
    var onDidWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // iokit_common_msg(x) = 0xE0000000 | x
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType: messageType, argument: argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            Log.info("Ruhezustand-Überwachung nicht verfügbar")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                           .commonModes)
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            if let onWillSleep {
                var allowed = false
                let allow = { [weak self] in
                    guard let self, !allowed else { return }
                    allowed = true
                    IOAllowPowerChange(self.rootPort, token)
                }
                onWillSleep { DispatchQueue.main.async(execute: allow) }
            } else {
                IOAllowPowerChange(rootPort, token)
            }
        case Self.systemHasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }
}
