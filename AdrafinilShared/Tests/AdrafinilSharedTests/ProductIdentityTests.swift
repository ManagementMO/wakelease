import Testing
@testable import AdrafinilShared

@Suite("Derivative identity")
struct ProductIdentityTests {
    @Test func servicesDoNotCollideWithUpstream() {
        #expect(AdrafinilConstants.appBundleID == "org.wakelease")
        #expect(AdrafinilConstants.daemonMachServiceName == "org.wakelease.daemon")
        #expect(AdrafinilConstants.helperMachServiceName == "org.wakelease.helper")
    }

    @Test func stateAndCLIAreIndependent() {
        #expect(AdrafinilConstants.appSupportDirectoryName == "WakeLease")
        #expect(AdrafinilConstants.cliBinaryName == "wakelease")
        #expect(AdrafinilConstants.cliInstallPath == "/usr/local/bin/wakelease")
    }
}
