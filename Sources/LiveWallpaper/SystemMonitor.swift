import AppKit
import IOKit.ps

/// Watches everything outside the app that should pause the wallpaper: sleep, display sleep, lock screen,
/// fast user switching, Low Power Mode and the power source.
@MainActor
final class SystemMonitor {
    private(set) var systemSleeping = false
    private(set) var screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private(set) var screenLocked = SystemMonitor.isScreenLockedNow()
    private(set) var sessionActive = true
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var onBattery = SystemMonitor.isOnBatteryNow()

    var onChange: (() -> Void)?
    /// After wake the display layout may have changed while we were asleep.
    var onWake: (() -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
        watch(workspace, NSWorkspace.didWakeNotification) {
            $0.systemSleeping = false
            $0.onWake?()
        }
        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification) {
            $0.screensAsleep = false
            $0.onWake?()
        }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true }

        let distributed = DistributedNotificationCenter.default()
        watch(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }

        watch(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.onBattery = SystemMonitor.isOnBatteryNow()
                Log.event("power source: \(monitor.onBattery ? "battery" : "AC")")
                monitor.onChange?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// Notifications can arrive on any thread (power state does); handlers always run on the main queue.
    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping @MainActor (SystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                Log.event("system: \(name.rawValue)")
                self.onChange?()
            }
        }
        tokens.append((center, token))
    }

    private static func isOnBatteryNow() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    private static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
