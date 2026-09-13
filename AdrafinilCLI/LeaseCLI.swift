import AdrafinilShared
import Darwin
import Foundation

struct LeaseRemoteError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WakeLeaseCLI {
    static func execute(_ arguments: [String]) -> Int32 {
        do {
            let plan = try LeaseCLIPlan(arguments: arguments)
            if plan.command == "help" || plan.flags.contains("--help") { print(help); return 0 }
            if plan.command == "version" { print("wakelease \(WakeLeaseIdentity.marketingVersion) (protocol 1)"); return 0 }
            let client = LeaseSocketClient(directory: plan.directory)
            if plan.command == "run" { return try run(plan, client: client) }
            if plan.command == "watch" { return try watch(plan, client: client) }
            let reply = try checked(client.send(plan.request()))
            if plan.command == "status" || plan.command == "doctor" {
                guard let status = reply.status else { throw LeaseRemoteError(message: "The daemon omitted its status.") }
                if plan.flags.contains("--json") { printJSON(status) }
                else if plan.command == "doctor" { return doctor(status, directory: plan.directory) }
                else { printStatus(status) }
            } else if plan.flags.contains("--json") {
                printJSON(reply)
            } else if let lease = reply.lease {
                print(lease.key)
                if plan.command == "hold" { error("Lease expires in \(Int(lease.ttlSeconds)) seconds; release it when the work finishes.") }
                warnIfSimulation(reply)
            } else if plan.command == "release" {
                print(reply.changed == false ? "No matching live lease; nothing changed." : "Lease released.")
                if reply.changed == false, plan.flags.contains("--strict") { return 1 }
            } else if plan.command == "sleep" || plan.command == "pause" {
                print("WakeLease paused. New leases are blocked until wakelease resume.")
            } else if plan.command == "resume" {
                print("WakeLease resumed. Work producers may acquire leases again.")
            }
            return 0
        } catch let error as LeaseCLIUsageError {
            self.error(error.localizedDescription)
            return 2
        } catch {
            self.error(error.localizedDescription)
            return 1
        }
    }

    private static func run(_ plan: LeaseCLIPlan, client: LeaseSocketClient) throws -> Int32 {
        let request = try plan.request()
        let key = request.key!
        defer { _ = try? client.send(LeaseRequest(operation: "release", key: key)) }
        let reply = try checked(client.send(request))
        try requireProtection(reply)
        warnIfSimulation(reply)
        var warned = false
        return CommandProcess.run(arguments: plan.childArguments) { event, pid in
            var update = LeaseRequest(operation: "renew", key: key)
            switch event {
            case .started, .continued:
                guard let identity = SystemProcessIdentity.read(pid) else { return }
                update = request
                update.owner = identity
                update.issuedAt = SystemLeaseClock().now().continuous
                update.requestID = UUID()
            case .stopped: update.operation = "wait"
            case .heartbeat: break
            }
            do { _ = try checked(client.send(update)) }
            catch {
                if !warned { self.error("Lease renewal failed; the command is still running but wake protection may expire."); warned = true }
            }
        }
    }

    private static func watch(_ plan: LeaseCLIPlan, client: LeaseSocketClient) throws -> Int32 {
        let request = try plan.request()
        guard let owner = request.owner, let key = request.key else { throw LeaseCLIUsageError("watch requires a live --pid.") }
        defer { _ = try? client.send(LeaseRequest(operation: "release", key: key)) }
        let reply = try checked(client.send(request))
        try requireProtection(reply)
        warnIfSimulation(reply)
        var failure: Error?
        let result = CommandProcess.watch(pid: owner.pid) { pid in
            guard SystemProcessIdentity.read(pid) == owner else { return false }
            do {
                _ = try checked(client.send(LeaseRequest(operation: "renew", key: key)))
                return true
            } catch {
                failure = error
                return false
            }
        }
        if let failure { throw failure }
        return result
    }

    private static func checked(_ reply: LeaseReply) throws -> LeaseReply {
        guard reply.ok else { throw LeaseRemoteError(message: reply.error?.message ?? "The daemon refused the operation.") }
        return reply
    }

    private static func requireProtection(_ reply: LeaseReply) throws {
        guard reply.status?.mode == "simulation" || reply.status?.power.applied?.system == true else {
            throw LeaseRemoteError(message: "Wake protection is not confirmed. The command was not started.")
        }
    }

    private static func warnIfSimulation(_ reply: LeaseReply) {
        if reply.status?.mode == "simulation" { error("Simulation mode: no macOS power settings or assertions are changed.") }
    }

    private static func printJSON(_ value: some Encodable) {
        if let data = try? LeaseJSON.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    private static func printStatus(_ status: LeaseServiceStatus) {
        let state = status.snapshot
        let title: String
        if status.mode == "simulation" { title = "SIMULATION (no power changes)" }
        else if status.power.applied?.system == true { title = "AWAKE" }
        else if state.demand.system { title = "WAKE PROTECTION UNCONFIRMED" }
        else { title = "NORMAL SLEEP" }
        print("\(title) · \(state.effectiveCount) effective lease(s)")
        if state.paused { print("Paused — new leases are blocked.") }
        print("")
        for lease in state.leases {
            let age = max(0, Int(Date().timeIntervalSince(lease.acquiredAt) / 60))
            let label = lease.state == .waitingForUser ? "waiting for you" : "working"
            print("\(lease.source)  \(label) · \(age)m · \(lease.wakeClass.rawValue)")
            print("  \(lease.key)\(lease.reason.map { " — " + $0 } ?? "")")
        }
        if state.leases.isEmpty { print("No active work.") }
        print("\nLid: \(state.safety.lidClosed.map { $0 ? "closed" : "open" } ?? "unknown")")
        print("Thermal: \(state.safety.thermalState.rawValue)")
        if !state.cutouts.isEmpty { print("Safety cutout: \(state.cutouts.map(\.rawValue).sorted().joined(separator: ", "))") }
        if let error = status.power.error { print("Warning: \(error)") }
    }

    private static func doctor(_ status: LeaseServiceStatus, directory: URL) -> Int32 {
        print("WakeLease doctor\n")
        print("Daemon           reachable (\(status.version))")
        print("Protocol         \(status.protocolVersion)")
        print("Mode             \(status.mode)")
        print("Socket           user-scoped; peer credentials verified")
        print("State directory  \(directory.path)")
        print("Leases           \(status.snapshot.effectiveCount) effective / \(status.snapshot.leases.count) retained")
        if status.mode == "simulation" {
            print("Power control    NOT ACTIVE — simulation deliberately uses no helper")
            print("Hardware tests   NOT VERIFIED by this diagnostic")
        } else {
            print("Helper           \(status.power.helperConnected ? "connected" : "unavailable")")
        }
        if let error = status.power.error { print("Problem          \(error)"); return 1 }
        return 0
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("wakelease: " + message + "\n").utf8))
    }

    static let help = """
    wakelease — keep your Mac working only while work holds a lease

    Usage:
      wakelease acquire <key> [--source <name>] [--reason <text>] [--ttl <seconds>]
      wakelease renew <key> [--ttl <seconds>]
      wakelease heartbeat <key>
      wakelease wait <key> [--reason <text>]
      wakelease release <key> [--strict] | --all
      wakelease hold --for <duration> [--source <name>] [--reason <text>]
      wakelease run [--source <name>] -- command [arguments]
      wakelease watch --pid <pid> [--source <name>]
      wakelease status [--json]
      wakelease doctor [--json]
      wakelease pause | resume
      wakelease sleep
      wakelease version

    Acquire/hold/run/watch accept --display to keep the display awake too.
    System-only is the default. --pid records and verifies process birth identity.
    --parent <lease-uuid> records an independent child lease; parent release never
    cascades. Keys are literal: release accepts exactly what status prints.

    Leases are finite (default 4h, maximum 24h); renew before the deadline.
    Waiting defaults to a 10-minute grace, bounded by the lease's own expiry.
    run inherits the terminal and streams, forwards signals and preserves exit status.
    sleep currently pauses lease admission and restores normal sleep policy; it
    does not force immediate open-lid sleep. resume explicitly enables admission.

    Development: start WakeLeaseDaemon --simulate to exercise the protocol without
    touching power management. Simulation is visibly labeled and does NOT keep
    the Mac awake. WAKELEASE_STATE_DIR selects an owned, private state directory.
    """
}
