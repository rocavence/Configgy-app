import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Registering may surface the
/// app under System Settings › General › Login Items, where macOS can also ask
/// the user to approve it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but waiting for the user's OK in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns the error message when it didn't work.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.write("Login item \(enabled ? "register" : "unregister") failed: \(error)", home: NSHomeDirectory(), error: true)
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
