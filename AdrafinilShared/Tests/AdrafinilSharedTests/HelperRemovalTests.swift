import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Transactional helper removal")
struct HelperRemovalTests {
    @Test
    func `active work prevents a removal reservation`() throws {
        var ledger = HelperDemandLedger()
        let owner = UUID(), other = UUID()
        try ledger.connect(uid: 501, token: owner)
        try ledger.connect(uid: 502, token: other)
        try ledger.set(uid: 502, token: other, blocked: true, at: 100)
        #expect(throws: (any Error).self) { try ledger.reserveRemoval(uid: 501, token: owner, id: UUID()) }
        #expect(ledger.removal == nil)
        #expect(ledger.shouldBlock)
    }

    @Test
    func `an authorized removal retires only the initiating user claim`() throws {
        var ledger = HelperDemandLedger()
        let token = UUID()
        try ledger.connect(uid: 501, token: token)
        try ledger.set(uid: 501, token: token, blocked: true, at: 100)
        try ledger.reserveRemoval(uid: 501, id: UUID())
        #expect(!ledger.shouldBlock)
        #expect(ledger.removal?.uid == 501)
    }

    @Test
    func `reserved removal closes admission for existing and new peers`() throws {
        var ledger = HelperDemandLedger()
        let owner = UUID(), other = UUID(), later = UUID(), id = UUID()
        try ledger.connect(uid: 501, token: owner)
        try ledger.connect(uid: 502, token: other)
        try ledger.reserveRemoval(uid: 501, token: owner, id: id)
        try ledger.reserveRemoval(uid: 501, token: owner, id: id)
        #expect(throws: (any Error).self) { try ledger.set(uid: 502, token: other, blocked: true, at: 101) }
        try ledger.connect(uid: 503, token: later)
        #expect(throws: (any Error).self) { try ledger.set(uid: 503, token: later, blocked: true, at: 102) }
        try ledger.set(uid: 501, token: owner, blocked: false, at: 103)
        ledger.disconnect(uid: 501, token: owner, at: 104)
        ledger.expire(at: 10_000)
        #expect(ledger.removal?.id == id)
        #expect(!ledger.shouldBlock)
    }

    @Test
    func `a restored reservation stays closed across helper restarts`() throws {
        let reservation = HelperRemovalReservation(id: UUID(), uid: 501)
        let data = try JSONEncoder().encode(reservation)
        let restored = try JSONDecoder().decode(HelperRemovalReservation.self, from: data)
        var ledger = HelperDemandLedger(removal: restored)
        let peer = UUID()
        try ledger.connect(uid: 502, token: peer)
        #expect(throws: (any Error).self) { try ledger.set(uid: 502, token: peer, blocked: true, at: 1) }
        #expect(!ledger.shouldBlock)
    }

    @Test
    func `only the current owner and transaction may cancel removal`() throws {
        var ledger = HelperDemandLedger()
        let old = UUID(), current = UUID(), other = UUID(), first = UUID(), second = UUID()
        try ledger.connect(uid: 501, token: old)
        try ledger.connect(uid: 502, token: other)
        try ledger.reserveRemoval(uid: 501, token: old, id: first)
        try ledger.connect(uid: 501, token: current)
        #expect(throws: (any Error).self) { try ledger.cancelRemoval(uid: 501, token: old, id: first) }
        #expect(throws: (any Error).self) { try ledger.cancelRemoval(uid: 502, token: other, id: first) }
        try ledger.cancelRemoval(uid: 501, token: current, id: first)
        try ledger.reserveRemoval(uid: 501, token: current, id: second)
        #expect(throws: (any Error).self) { try ledger.cancelRemoval(uid: 501, token: current, id: first) }
        #expect(ledger.removal?.id == second)
        try ledger.cancelRemoval(uid: 501, token: current, id: second)
        try ledger.set(uid: 502, token: other, blocked: true, at: 100)
        #expect(ledger.shouldBlock)
    }

    @Test
    func `unsupported or corrupt reservations fail closed`() {
        for text in [
            #"{"version":2,"id":"00000000-0000-0000-0000-000000000001","uid":501}"#,
            #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","uid":0}"#,
        ] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(HelperRemovalReservation.self, from: Data(text.utf8)) }
        }
    }
}
