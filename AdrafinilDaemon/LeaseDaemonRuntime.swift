import AdrafinilShared
import Foundation
import os
import OSLog

private actor StartupGate {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        ready = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class LeasePersistence: Sendable {
    let directory: SecureDirectory
    private let errorState = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let eventLines = OSAllocatedUnfairLock(initialState: [Data]())
    var error: String? { errorState.withLock { $0 } }

    init(directory: SecureDirectory) { self.directory = directory }

    func save(_ book: LeaseBook, events: [LeaseEvent]) {
        do {
            try directory.write(JSONEncoder().encode(book), name: "leases.json")
            if !events.isEmpty {
                let lines = try events.map { event -> Data in
                    var data = try LeaseJSON.encode(event)
                    data.append(10)
                    return data
                }
                let output = eventLines.withLock { buffer in
                    buffer.append(contentsOf: lines)
                    if buffer.count > 512 { buffer.removeFirst(buffer.count - 512) }
                    return buffer.reduce(into: Data()) { $0.append($1) }
                }
                try directory.write(output, name: "events.log")
            }
            errorState.withLock { $0 = nil }
        } catch {
            errorState.withLock { $0 = "Local state could not be persisted. Check state-directory ownership and available disk space." }
        }
    }
}

@MainActor
final class LeaseDaemonRuntime {
    private let log = Logger(subsystem: WakeLeaseIdentity.daemonBundleID, category: "LeaseRuntime")
    private let directoryURL: URL
    private var server: LeaseSocketServer?
    private var broker: LeaseBroker?
    private var observer: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var persistence: LeasePersistence?
    private var stopping = false

    init(directory: URL) { directoryURL = directory }

    func start() async throws {
        let directory = try SecureDirectory(url: directoryURL, create: true)
        let persistence = LeasePersistence(directory: directory)
        self.persistence = persistence
        let broker = LeaseBroker(persist: { book, events in persistence.save(book, events: events) })
        self.broker = broker
        let gate = StartupGate()
        let service = LeaseProtocolService(broker: broker, mode: "simulation", onMutation: { [weak self] snapshot in
            await self?.scheduleMaintenance(snapshot)
        }, power: {
            LeasePowerReport(applied: WakeDemand.none, error: persistence.error, helperConnected: false)
        })
        let server = LeaseSocketServer(directory: directoryURL) { request, peer in
            await gate.wait()
            return await service.handle(request, peer: peer)
        }
        try server.start()
        self.server = server
        if let data = try directory.read(name: "leases.json") {
            do { try await broker.restore(data) }
            catch {
                log.error("recovery_failed — invalid persisted state; pausing admission")
                await broker.setPaused(true)
            }
        }
        observer = Task { @MainActor [weak self, broker] in
            for await snapshot in broker.changes {
                guard let self, !stopping else { break }
                scheduleMaintenance(snapshot)
            }
        }
        scheduleMaintenance(await broker.snapshot())
        await gate.open()
        log.notice("daemon_started — simulation; no power mechanisms loaded")
    }

    private func scheduleMaintenance(_ snapshot: LeaseSnapshot) {
        maintenance?.cancel()
        guard !stopping, let broker, !snapshot.leases.isEmpty || !snapshot.cutouts.isEmpty else {
            maintenance = nil
            return
        }
        let clock = SystemLeaseClock()
        let delay = max(0.005, min(30, (snapshot.nextDeadline ?? clock.now().continuous + 30) - clock.now().continuous))
        maintenance = Task { @MainActor [weak self, broker] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !stopping else { return }
            await broker.sweep()
            scheduleMaintenance(await broker.snapshot())
        }
    }

    func shutdown() async {
        stopping = true
        observer?.cancel()
        maintenance?.cancel()
        server?.stop()
        server = nil
        log.notice("daemon_stopped — simulation")
    }
}
