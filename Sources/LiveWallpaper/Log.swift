import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "io.github.livewallpapermac", category: "app")

    /// LW_DIAG=1 mirrors events to stderr with an uptime stamp and turns on the loop seam meter (scripts/dev checks).
    static let diagnostics = ProcessInfo.processInfo.environment["LW_DIAG"] == "1"

    static func event(_ message: String) {
        app.info("\(message, privacy: .public)")
        guard diagnostics else { return }
        let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
