import Testing
@testable import AdrafinilShared

@Suite("Derivative identity")
struct ProductIdentityTests {
    @Test
    func `services do not collide with upstream`() {
        #expect(AdrafinilConstants.appBundleID == "org.wakelease")
        #expect(AdrafinilConstants.daemonMachServiceName == "org.wakelease.daemon")
        #expect(AdrafinilConstants.helperMachServiceName == "org.wakelease.helper")
    }

    @Test
    func `state and CLI are independent`() {
        #expect(AdrafinilConstants.appSupportDirectoryName == "WakeLease")
        #expect(AdrafinilConstants.cliBinaryName == "wakelease")
        #expect(AdrafinilConstants.cliInstallPath == "/usr/local/bin/wakelease")
    }
}
