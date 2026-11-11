import Foundation
import ServiceManagement

public protocol LaunchAtLoginManaging: Sendable {
    var isAvailable: Bool { get }
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public enum LaunchAtLoginError: LocalizedError, Equatable {
    case unavailable
    case requiresApproval

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Launch at Login is only available when running from an installed application bundle."
        case .requiresApproval:
            return "Approval required in macOS System Settings → General → Login Items."
        }
    }
}

public final class LaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    public static let shared = LaunchAtLoginManager()

    public var isAvailable: Bool {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            return false
        }
        return true
    }

    public var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else {
            throw LaunchAtLoginError.unavailable
        }
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw LaunchAtLoginError.requiresApproval
            }
        } else {
            guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}

public final class MockLaunchAtLoginManager: LaunchAtLoginManaging, @unchecked Sendable {
    public var isAvailable: Bool
    public var isEnabled: Bool
    public var registerCount: Int = 0
    public var unregisterCount: Int = 0
    public var registerCalled: Bool { registerCount > 0 }
    public var unregisterCalled: Bool { unregisterCount > 0 }
    public var shouldThrowError: Error?

    public init(isAvailable: Bool = true, isEnabled: Bool = false) {
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if let error = shouldThrowError {
            throw error
        }
        if enabled {
            guard !isEnabled else { return }
            registerCount += 1
            isEnabled = true
        } else {
            guard isEnabled else { return }
            unregisterCount += 1
            isEnabled = false
        }
    }
}
