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
    private let simulation: Bool
    private var server: LeaseSocketServer?
    private var broker: LeaseBroker?
    private var driver: LeasePowerReconciler?
    private var systemController: SystemLeasePowerController?
    private var devices: LeaseDeviceMonitor?
    private var observer: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var nextMaintenance = EarliestDeadline()
    private var maintenanceGeneration: UInt64 = 0
    private var persistence: LeasePersistence?
    private var stopping = false

    init(directory: URL, simulation: Bool) {
        directoryURL = directory
        self.simulation = simulation
    }

    func start() async throws {
        let directory = try SecureDirectory(url: directoryURL, create: true)
        let persistence = LeasePersistence(directory: directory)
        self.persistence = persistence
        let broker = LeaseBroker(persist: { book, events in persistence.save(book, events: events) })
        self.broker = broker
        let gate = StartupGate()
        let service = LeaseProtocolService(broker: broker, mode: simulation ? "simulation" : "system", beforeMutation: { [weak self] request in
            await self?.refreshSafety(anticipatingWork: ["acquire", "hold"].contains(request.operation))
        }, onMutation: { [weak self] _ in
            await self?.synchronizePower()
        }, power: { [weak self] in
            await self?.powerReport() ?? LeasePowerReport(error: "Daemon is stopping.")
        })
        let server = LeaseSocketServer(directory: directoryURL) { request, peer in
            await gate.wait()
            return await service.handle(request, peer: peer)
        }
        try server.start()
        self.server = server
        let controller: any LeasePowerControlling
        if simulation {
            controller = SimulatedLeasePowerController()
        } else {
            devices = LeaseDeviceMonitor()
            let system = SystemLeasePowerController { [weak self, broker] in
                guard let self, !self.stopping, let devices = self.devices else { return false }
                let current = await broker.snapshot()
                guard !current.demand.system else { return false }
                let conditions = devices.sample(includeTemperature: false)
                return conditions.lidClosed == true && conditions.externalDisplayConnected == false
            }
            systemController = system
            system.onDisconnect = { [weak self] in
                Task { @MainActor in
                    guard let self, !self.stopping else { return }
                    await self.driver?.invalidate()
                    await self.synchronizePower(force: true)
                }
            }
            devices?.onChange = { [weak self] in Task { @MainActor in await self?.refreshSafety() } }
            devices?.onWake = { [weak self, broker] in
                Task { @MainActor in
                    await broker.sweep()
                    await self?.refreshSafety()
                    await self?.synchronizePower(force: true)
                }
            }
            controller = system
        }
        driver = LeasePowerReconciler(controller: controller, stillCurrent: { target in
            await broker.snapshot().demand == target.demand
        }, onChange: { [weak self] in
            Task { @MainActor in self?.notifyStatus() }
        })
        if let data = try directory.read(name: "leases.json") {
            do { try await broker.restore(data) }
            catch {
                log.error("recovery_failed — invalid persisted state; pausing admission")
                await broker.setPaused(true)
            }
        }
        await refreshSafety()
        await synchronizePower(force: true)
        observer = Task { @MainActor [weak self, broker] in
            for await _ in broker.changes {
                guard let self, !self.stopping, let driver = self.driver else { break }
                let latest = await broker.snapshot()
                await driver.submit(self.intent(latest))
                self.scheduleMaintenance(latest)
                self.notifyStatus()
            }
        }
        scheduleMaintenance(await broker.snapshot())
        await gate.open()
        log.notice("daemon_started — mode=\(self.simulation ? "simulation" : "system", privacy: .public)")
    }

    private func refreshSafety(anticipatingWork: Bool = false) async {
        guard !stopping, let devices, let broker else { return }
        let current = await broker.snapshot()
        let quick = devices.sample(includeTemperature: false)
        let measure = current.cutouts.contains(.thermal) || (quick.lidClosed == true && (anticipatingWork || current.demand.system))
        await broker.updateSafety(measure ? devices.sample(includeTemperature: true) : quick)
        let latest = await broker.snapshot()
        await driver?.submit(intent(latest))
        scheduleMaintenance(latest)
    }

    private func intent(_ snapshot: LeaseSnapshot, stopping: Bool = false) -> LeasePowerIntent {
        LeasePowerIntent(version: snapshot.generation, demand: snapshot.demand, lidClosed: snapshot.safety.lidClosed, externalDisplay: snapshot.safety.externalDisplayConnected, promptSleep: !stopping && snapshot.sleepClosedLidOnFinalRelease, cue: false)
    }

    private func synchronizePower(force: Bool = false) async {
        guard !stopping, let broker, let driver else { return }
        _ = await driver.reconcile(intent(await broker.snapshot()), force: force)
        scheduleMaintenance(await broker.snapshot())
        notifyStatus()
    }

    private func powerReport() async -> LeasePowerReport {
        var report = await driver?.report() ?? LeasePowerReport()
        report.error = report.error ?? persistence?.error
        return report
    }

    private func scheduleMaintenance(_ snapshot: LeaseSnapshot) {
        guard snapshot.generation >= maintenanceGeneration else { return }
        maintenanceGeneration = snapshot.generation
        guard !stopping, let broker, !snapshot.leases.isEmpty || !snapshot.cutouts.isEmpty else {
            maintenance?.cancel()
            maintenance = nil
            nextMaintenance.fired()
            return
        }
        let now = SystemLeaseClock().now().continuous
        let interval: Double = snapshot.safety.lidClosed == true && snapshot.demand.system ? 15 : 30
        guard nextMaintenance.arm(min(snapshot.nextDeadline ?? now + interval, now + interval)), let due = nextMaintenance.value else { return }
        maintenance?.cancel()
        maintenance = Task { @MainActor [weak self, broker] in
            do { try await Task.sleep(for: .seconds(max(0.005, due - SystemLeaseClock().now().continuous))) }
            catch { return }
            guard let self, !self.stopping else { return }
            self.nextMaintenance.fired()
            self.maintenance = nil
            await broker.sweep()
            await self.refreshSafety()
            let current = await broker.snapshot()
            await self.synchronizePower(force: current.demand.system)
            self.scheduleMaintenance(await broker.snapshot())
        }
    }

    private func notifyStatus() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(WakeLeaseIdentity.appBundleID + ".statusChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    func shutdown() async {
        guard !stopping else { return }
        stopping = true
        observer?.cancel()
        maintenance?.cancel()
        server?.stop()
        server = nil
        if let broker, let driver {
            let snapshot = await broker.beginShutdown()
            let report = await driver.reconcile(intent(snapshot, stopping: true), force: true)
            if report.error != nil { log.error("shutdown_clear_unconfirmed — helper recovery remains responsible") }
        }
        systemController?.disconnect()
        log.notice("daemon_stopped")
    }
}
