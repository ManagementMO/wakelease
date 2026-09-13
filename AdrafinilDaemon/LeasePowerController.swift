import AdrafinilShared
import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

actor SimulatedLeasePowerController: LeasePowerControlling {
    func apply(_ demand: WakeDemand) async throws {}
    func prepareForRelease() async {}
    func requestSleep() async throws {}
    func connectionReport() async -> LeasePowerReport { LeasePowerReport() }
}

@MainActor
final class SystemLeasePowerController: LeasePowerControlling {
    private let helper = LeaseHelperConnection()
    private let display = DisplayHold()
    private let maySleep: @MainActor @Sendable () async -> Bool
    private let log = Logger(subsystem: WakeLeaseIdentity.daemonBundleID, category: "Power")
    private var globalBlocked: Bool?
    private var issue: String?
    var onDisconnect: (() -> Void)? {
        get { helper.onDisconnect }
        set { helper.onDisconnect = newValue }
    }

    init(maySleep: @escaping @MainActor @Sendable () async -> Bool) {
        self.maySleep = maySleep
    }

    func apply(_ demand: WakeDemand) async throws {
        display.set(held: demand.display)
        let displayError = display.lastError
        do {
            try await helper.setBlocked(demand.system)
            globalBlocked = try await helper.globalBlocked()
            if let displayError { throw NSError(domain: WakeLeaseIdentity.daemonBundleID, code: Int(displayError)) }
            guard display.isActive == demand.display else { throw LeaseHelperConnection.Failure.rejected }
            issue = nil
            log.notice("sleep_block_reconciled — system=\(demand.system, privacy: .public), display=\(demand.display, privacy: .public)")
        } catch {
            globalBlocked = nil
            issue = "The signed helper or a power assertion failed. Verify service approval and matching app/helper versions."
            throw error
        }
    }

    func prepareForRelease() async {
        NSSound(named: NSSound.Name("Glass"))?.play()
        try? await Task.sleep(for: .milliseconds(300))
    }

    func requestSleep() async throws {
        guard try await !helper.globalBlocked(), await maySleep(), LeaseDeviceMonitor.otherAssertionsPermitSleep() else { return }
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { throw LeaseHelperConnection.Failure.unavailable }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        guard result == kIOReturnSuccess else { throw NSError(domain: WakeLeaseIdentity.daemonBundleID, code: Int(result)) }
        log.notice("closed_lid_sleep_requested")
    }

    func connectionReport() async -> LeasePowerReport {
        LeasePowerReport(error: issue, helperConnected: helper.isConnected, globalBlocked: globalBlocked)
    }

    func disconnect() { helper.disconnect() }
}
