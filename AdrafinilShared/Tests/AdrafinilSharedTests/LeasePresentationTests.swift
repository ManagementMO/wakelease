import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Truthful UI status")
struct LeasePresentationTests {
    private func status(work: Bool, applied: WakeDemand?, error: String? = nil, mode: String = "system") throws -> LeaseServiceStatus {
        var book = LeaseBook(bootID: "test")
        if work { _ = try book.acquire(LeaseProposal(key: "job"), at: LeaseTime(wall: Date(), continuous: 1)) }
        return LeaseServiceStatus(protocolVersion: 1, version: "0.1.0", mode: mode, snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport(applied: applied, error: error, helperConnected: error == nil))
    }

    @Test
    func `does not confuse demand with confirmed power`() throws {
        let state = try status(work: true, applied: nil, error: "unavailable")
        #expect(LeasePresentation(status: state).kind == .unconfirmed)
    }

    @Test
    func `failed cleanup is not presented as normal sleep`() throws {
        let state = try status(work: false, applied: WakeDemand(system: true, display: false), error: "clear failed")
        #expect(LeasePresentation(status: state).kind == .unconfirmed)
    }

    @Test
    func `simulation is never presented as real protection`() throws {
        let state = try status(work: true, applied: WakeDemand(system: true, display: false), mode: "simulation")
        #expect(LeasePresentation(status: state).kind == .simulation)
    }

    @Test
    func `waiting grace has its own status rather than working`() throws {
        var book = LeaseBook(bootID: "test")
        _ = try book.acquire(LeaseProposal(key: "a"), at: LeaseTime(wall: Date(), continuous: 1))
        _ = try book.wait(key: "a", at: LeaseTime(wall: Date(), continuous: 2))
        let state = LeaseServiceStatus(mode: "system", snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport(applied: book.demand, helperConnected: true))
        #expect(LeasePresentation(status: state).kind == .waiting)
    }

    @Test
    func `another user claim is not presented as normal sleep`() {
        let book = LeaseBook(bootID: "test")
        let state = LeaseServiceStatus(mode: "system", snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport(applied: WakeDemand.none, helperConnected: true, globalBlocked: true))
        let presentation = LeasePresentation(status: state)
        #expect(presentation.title != "Normal sleep")
        #expect(presentation.detail.contains("Another user"))
    }

    @Test
    func `normal sleep and active states have distinct semantics`() throws {
        #expect(try LeasePresentation(status: status(work: false, applied: WakeDemand.none)).kind == .normal)
        #expect(try LeasePresentation(status: status(work: true, applied: WakeDemand(system: true, display: false))).kind == .active)
        #expect(LeasePresentation(status: nil).kind == .unavailable)
    }
}
