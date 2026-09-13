import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Public CLI contract")
struct LeaseCLIPlanTests {
    @Test
    func `source is not an implicit key prefix`() throws {
        let plan = try LeaseCLIPlan(arguments: ["acquire", "future:turn", "--source", "future-tool"])
        let request = try plan.request()
        #expect(request.key == "future:turn")
        #expect(request.source == "future-tool")
        #expect(request.operation == "acquire")
    }

    @Test
    func `flags never consume the following key`() throws {
        let request = try LeaseCLIPlan(arguments: ["acquire", "--display", "key"]).request()
        #expect(request.key == "key")
        #expect(request.wakeClass == .display)
    }

    @Test
    func `command arguments are passed literally`() throws {
        let plan = try LeaseCLIPlan(arguments: ["run", "--", "printf", "%s", "a b; $HOME", "--flag"])
        #expect(plan.childArguments == ["printf", "%s", "a b; $HOME", "--flag"])
    }

    @Test
    func `invalid flags and durations are rejected`() {
        for args in [["acquire", "k", "--unknown"], ["hold", "--for", "0"], ["acquire", "k", "--ttl", "nan"], ["acquire", "k", "--source"], ["watch", "--pid", "0"], ["release", "k", "--all"]] {
            #expect(throws: (any Error).self) { _ = try LeaseCLIPlan(arguments: args).request() }
        }
    }

    @Test
    func `timed holds use finite durations and unique keys`() throws {
        let first = try LeaseCLIPlan(arguments: ["hold", "--for", "2h"]).request()
        let second = try LeaseCLIPlan(arguments: ["hold", "--for", "2h"]).request()
        #expect(first.ttlSeconds == 7_200)
        #expect(first.sourceKind == .timed)
        #expect(first.key != second.key)
    }

    @Test
    func `release all has an explicit operation`() throws {
        #expect(try LeaseCLIPlan(arguments: ["release", "--all"]).request().operation == "releaseAll")
    }

    @Test
    func `run requires an explicit argument boundary`() {
        #expect(throws: (any Error).self) { _ = try LeaseCLIPlan(arguments: ["run", "npm", "build"]) }
    }
}
