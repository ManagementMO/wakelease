import Foundation

public struct LeasePowerIntent: Sendable, Equatable {
    public let version: UInt64
    public let demand: WakeDemand
    public let maySleepOnRelease: Bool
    public let cue: Bool

    public init(version: UInt64, demand: WakeDemand, lidClosed: Bool?, externalDisplay: Bool?, promptSleep: Bool, cue: Bool = false) {
        self.version = version
        self.demand = demand
        maySleepOnRelease = promptSleep && lidClosed == true && externalDisplay == false
        self.cue = cue
    }
}

public protocol LeasePowerControlling: Sendable {
    func apply(_ demand: WakeDemand) async throws
    func prepareForRelease() async
    func requestSleep() async throws
    func connectionReport() async -> LeasePowerReport
}

public actor LeasePowerReconciler {
    private struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<LeasePowerReport, Never>
    }
    private let controller: any LeasePowerControlling
    private let retry: @Sendable (Int) async -> Void
    private let stillCurrent: @Sendable (LeasePowerIntent) async -> Bool
    private let onChange: @Sendable () -> Void
    private var desired: LeasePowerIntent?
    private var applied: WakeDemand?
    private var lastError: String?
    private var token: UInt64 = 0
    private var forceApply = false
    private var worker: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var waiters: [Waiter] = []

    public init(controller: any LeasePowerControlling, stillCurrent: @escaping @Sendable (LeasePowerIntent) async -> Bool = { _ in true }, onChange: @escaping @Sendable () -> Void = {}, retry: @escaping @Sendable (Int) async -> Void = { attempt in
        try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(attempt, 5))))))
    }) {
        self.controller = controller
        self.stillCurrent = stillCurrent
        self.onChange = onChange
        self.retry = retry
    }

    public func invalidate() {
        applied = nil
        lastError = "Helper connectivity changed; protection must be reconfirmed."
        forceApply = true
        token &+= 1
        retryTask?.cancel()
        cueTask?.cancel()
        onChange()
    }

    public func submit(_ intent: LeasePowerIntent, force: Bool = false) {
        if let desired, intent.version < desired.version { return }
        if desired != intent || force {
            desired = intent
            token &+= 1
            forceApply = forceApply || force
            retryTask?.cancel()
            cueTask?.cancel()
        }
        if worker == nil { worker = Task { await drain() } }
    }

    public func reconcile(_ intent: LeasePowerIntent, force: Bool = false) async -> LeasePowerReport {
        if let desired, intent.version < desired.version { return await report() }
        if worker == nil, !force, applied == intent.demand, lastError == nil {
            desired = intent
            return await report()
        }
        submit(intent, force: force)
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(token: token, continuation: continuation))
        }
    }

    public func report() async -> LeasePowerReport {
        var report = await controller.connectionReport()
        report.applied = applied
        report.error = lastError ?? report.error
        return report
    }

    public func flush() async {
        while let worker {
            await worker.value
        }
    }

    private func drain() async {
        var attempts = 0
        var cueForToken: UInt64?
        while let target = desired {
            let currentToken = token
            let wasBlocking = applied?.system == true
            let releasing = wasBlocking && !target.demand.system
            let mustApply = applied != target.demand || forceApply || lastError != nil
            if mustApply {
                if releasing, target.maySleepOnRelease, target.cue, cueForToken != currentToken {
                    cueForToken = currentToken
                    let cue = Task { await controller.prepareForRelease() }
                    cueTask = cue
                    await cue.value
                    cueTask = nil
                    if token != currentToken { continue }
                }
                let valid = await stillCurrent(target)
                if token != currentToken { continue }
                if !valid {
                    await complete(upTo: currentToken)
                    if token != currentToken { continue }
                    worker = nil
                    return
                }
                forceApply = false
                do {
                    try await controller.apply(target.demand)
                    applied = target.demand
                    lastError = nil
                    attempts = 0
                } catch {
                    lastError = "Power reconciliation failed (\((error as NSError).code)). Protection is unconfirmed; inspect wakelease doctor."
                }
                if lastError == nil, releasing, target.maySleepOnRelease, token == currentToken {
                    let valid = await stillCurrent(target)
                    if valid, token == currentToken {
                        do { try await controller.requestSleep() }
                        catch { lastError = "Wake protection was removed, but the immediate sleep request failed." }
                    }
                }
            }
            await complete(upTo: currentToken)
            if token != currentToken { continue }
            if lastError != nil {
                let pause = Task { [attempts] in await retry(attempts) }
                retryTask = pause
                await pause.value
                retryTask = nil
                attempts = min(5, attempts + 1)
                continue
            }
            worker = nil
            return
        }
        worker = nil
    }

    private func complete(upTo completed: UInt64) async {
        let result = await report()
        onChange()
        let ready = waiters.filter { $0.token <= completed }
        waiters.removeAll { $0.token <= completed }
        for waiter in ready {
            waiter.continuation.resume(returning: result)
        }
    }
}
