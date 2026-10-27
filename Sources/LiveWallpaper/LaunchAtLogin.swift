import ServiceManagement

/// «Запускать при входе» through SMAppService. Off until the user turns it on.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.event("launch at login change failed: \(error.localizedDescription)")
        }
    }
}
