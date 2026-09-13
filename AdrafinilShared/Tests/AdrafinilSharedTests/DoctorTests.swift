import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Read-only doctor findings")
struct DoctorTests {
    @Test
    func `stranded override is reported when daemon is absent`() {
        let checks = LeaseDiagnostics.powerChecks(status: nil, sleepDisabled: true)
        #expect(checks.contains { $0.id == "sleepOverride" && $0.level == .failure })
    }

    @Test
    func `simulation does not claim hardware health`() {
        let book = LeaseBook(bootID: "test")
        let status = LeaseServiceStatus(mode: "simulation", snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport())
        let checks = LeaseDiagnostics.powerChecks(status: status, sleepDisabled: nil)
        #expect(checks.contains { $0.id == "powerControl" && $0.level == .skipped })
        #expect(!checks.contains { $0.level == .failure })
    }

    @Test
    func `desired awake without applied protection is A failure`() throws {
        var book = LeaseBook(bootID: "test")
        _ = try book.acquire(LeaseProposal(key: "job"), at: LeaseTime(wall: Date(), continuous: 1))
        let status = LeaseServiceStatus(mode: "system", snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport(error: "helper unavailable"))
        let checks = LeaseDiagnostics.powerChecks(status: status, sleepDisabled: false)
        #expect(checks.contains { $0.id == "powerControl" && $0.level == .failure })
    }
}
