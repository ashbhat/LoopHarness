//
//  LaunchAtLoginManager.swift
//  LoopMac
//
//  Thin wrapper around SMAppService.mainApp so the onboarding flow can
//  register Loop as a login item without each call site re-importing
//  ServiceManagement and re-handling the macOS 13+ availability gate.
//

import ServiceManagement

enum LaunchAtLoginManager {
    /// True when SMAppService says Loop is registered as a login item. macOS
    /// 12 has no equivalent we want to ship, so we report `false` and the
    /// onboarding step's "enable" action still no-ops cleanly.
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Register Loop as a login item. Returns the resulting status so the
    /// caller can react to `.requiresApproval` (user must confirm in
    /// System Settings → General → Login Items) vs `.enabled` (already done).
    @discardableResult
    static func enable() throws -> SMAppService.Status {
        guard #available(macOS 13.0, *) else { return .notFound }
        let svc = SMAppService.mainApp
        if svc.status != .enabled {
            try svc.register()
        }
        return svc.status
    }

    static func disable() throws {
        guard #available(macOS 13.0, *) else { return }
        try SMAppService.mainApp.unregister()
    }
}
