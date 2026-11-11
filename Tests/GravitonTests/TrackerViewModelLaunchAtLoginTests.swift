import Testing
import Foundation
@testable import Graviton

@Suite("TrackerViewModel Launch at Login Tests")
struct TrackerViewModelLaunchAtLoginTests {
    @Test("TrackerViewModel reflects initial manager state")
    @MainActor
    func testInitialState() {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: true)
        let vm = TrackerViewModel(startBackgroundServices: false, launchAtLoginManager: mock)

        #expect(vm.isLaunchAtLoginAvailable == true)
        #expect(vm.isLaunchAtLoginEnabled == true)
        #expect(vm.launchAtLoginError == nil)
    }

    @Test("TrackerViewModel successfully toggles launch at login")
    @MainActor
    func testSetLaunchAtLoginSuccess() {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        let vm = TrackerViewModel(startBackgroundServices: false, launchAtLoginManager: mock)

        vm.setLaunchAtLogin(enabled: true)
        #expect(vm.isLaunchAtLoginEnabled == true)
        #expect(mock.registerCalled == true)
        #expect(vm.launchAtLoginError == nil)

        vm.setLaunchAtLogin(enabled: false)
        #expect(vm.isLaunchAtLoginEnabled == false)
        #expect(mock.unregisterCalled == true)
    }

    @Test("TrackerViewModel handles error and reverts state")
    @MainActor
    func testSetLaunchAtLoginFailure() {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        mock.shouldThrowError = LaunchAtLoginError.unavailable
        let vm = TrackerViewModel(startBackgroundServices: false, launchAtLoginManager: mock)

        vm.setLaunchAtLogin(enabled: true)
        #expect(vm.isLaunchAtLoginEnabled == false)
        #expect(vm.launchAtLoginError != nil)
    }

    @Test("TrackerViewModel refresh syncs with external changes")
    @MainActor
    func testRefreshSyncsState() {
        let mock = MockLaunchAtLoginManager(isAvailable: true, isEnabled: false)
        let vm = TrackerViewModel(startBackgroundServices: false, launchAtLoginManager: mock)
        #expect(!vm.isLaunchAtLoginEnabled)

        // Simulate external state change (e.g. toggled in macOS System Settings)
        mock.isEnabled = true
        vm.refreshLaunchAtLoginStatus()
        #expect(vm.isLaunchAtLoginEnabled == true)
    }
}
