import Foundation
import os
import Testing
@testable import AdrafinilShared

@Suite("Once-only asynchronous replies")
struct OnceResumerTests {
    @Test
    @MainActor
    func `a main actor continuation can resume from a background callback`() async {
        let value = await withCheckedContinuation { continuation in
            let once = OnceResumer<Int> { continuation.resume(returning: $0) }
            DispatchQueue.global().async { once.resume(42); once.resume(7) }
        }
        #expect(value == 42)
    }

    @Test
    func `concurrent reply timeout and error callbacks only complete once`() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let once = OnceResumer<Int> { _ in calls.withLock { $0 += 1 } }
        await withTaskGroup(of: Void.self) { group in
            for value in 0 ..< 100 {
                group.addTask { once.resume(value) }
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }
}
