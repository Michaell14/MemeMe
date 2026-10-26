import Foundation
import os
import ServiceManagement

private let loginLog = Logger(subsystem: "com.mememe.app", category: "login")

/// "Open at Login" through `SMAppService.mainApp` (macOS 13+; no helper app needed).
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Registered with the system. Awaiting the user's approval in System Settings counts: the choice is made.
    static var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    /// False when the system can't find the app as a login item at all (for example, an unbundled `swift run`).
    static var isAvailable: Bool {
        status != .notFound
    }

    /// Registers or unregisters the app and returns the resulting `isEnabled`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
                if service.status == .requiresApproval {
                    // macOS asks the user to allow it under Login Items; take them there.
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            loginLog.error("Changing Open at Login failed: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
