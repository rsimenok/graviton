import Testing
import Foundation
@testable import AGYTokenTracker

@Suite("LaunchAtLoginManager Tests")
struct LaunchAtLoginManagerTests {
    @Test("MockLaunchAtLoginManager toggles state correctly")
    func testMockToggleState() throws {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        #expect(!mock.isEnabled)
        #expect(mock.isAvailable)

        try mock.setEnabled(true)
        #expect(mock.isEnabled)
        #expect(mock.registerCalled)

        try mock.setEnabled(false)
        #expect(!mock.isEnabled)
        #expect(mock.unregisterCalled)
    }

    @Test("MockLaunchAtLoginManager throws when configured with error")
    func testMockThrowsError() {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        mock.shouldThrowError = LaunchAtLoginError.unavailable

        #expect(throws: LaunchAtLoginError.self) {
            try mock.setEnabled(true)
        }
    }

    @Test("LaunchAtLoginManager idempotency prevents duplicate registrations")
    func testIdempotency() throws {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        try mock.setEnabled(true)
        #expect(mock.isEnabled)
        #expect(mock.registerCount == 1)

        // Second call when already enabled should be a no-op
        try mock.setEnabled(true)
        #expect(mock.isEnabled)
        #expect(mock.registerCount == 1)

        try mock.setEnabled(false)
        #expect(!mock.isEnabled)
        #expect(mock.unregisterCount == 1)

        // Second call when already disabled should be a no-op
        try mock.setEnabled(false)
        #expect(!mock.isEnabled)
        #expect(mock.unregisterCount == 1)
    }

    @Test("LaunchAtLoginError requiresApproval provides descriptive message")
    func testRequiresApprovalError() {
        let error = LaunchAtLoginError.requiresApproval
        #expect(error.errorDescription == "Approval required in macOS System Settings → General → Login Items.")
    }

    @Test("LaunchAtLoginManager checks availability safely when unpackaged")
    func testProductionManagerUnpackagedAvailability() {
        let manager = LaunchAtLoginManager.shared
        // When running in bare test runner outside an installed .app bundle, isAvailable should return false safely
        if Bundle.main.bundleURL.pathExtension != "app" {
            #expect(!manager.isAvailable)
            #expect(!manager.isEnabled)
        }
    }
}
