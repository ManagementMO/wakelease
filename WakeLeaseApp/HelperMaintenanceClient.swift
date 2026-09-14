import AdrafinilShared
import Foundation

@MainActor
final class HelperMaintenanceClient {
    private struct Failure: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? {
            message
        }
    }
    private var connection: NSXPCConnection?
    private var verified = false

    func reserve(_ id: UUID) async throws {
        try await verifyVersion()
        let accepted: Bool = try await call { proxy, once in
            proxy.reserveRemoval(id.uuidString) { value, error in
                once.resume(error.map { .failure(Failure(message: $0.localizedDescription)) } ?? .success(value))
            }
        }
        guard accepted else { throw HelperRemovalFailure.reserved }
    }

    func cancel(_ id: UUID) async throws {
        try await verifyVersion()
        let cancelled: Bool = try await call { proxy, once in
            proxy.cancelRemoval(id.uuidString) { value, error in
                once.resume(error.map { .failure(Failure(message: $0.localizedDescription)) } ?? .success(value))
            }
        }
        guard cancelled else { throw HelperRemovalFailure.invalidReservation }
    }

    func current() async throws -> HelperRemovalReservation? {
        try await verifyVersion()
        return try await call { proxy, once in
            proxy.currentRemoval { identifier, uid, error in
                if let error { once.resume(.failure(Failure(message: error.localizedDescription))); return }
                guard uid != 0 else { once.resume(.success(nil)); return }
                guard uid == getuid(), let identifier, let id = UUID(uuidString: identifier) else {
                    once.resume(.failure(Failure(message: "Another user owns a pending helper removal. Ask that user to finish or restore it.")))
                    return
                }
                once.resume(.success(HelperRemovalReservation(id: id, uid: uid)))
            }
        }
    }

    private func verifyVersion() async throws {
        guard !verified else { return }
        let version: String = try await call { proxy, once in proxy.version { once.resume(.success($0)) } }
        guard version == WakeLeaseIdentity.marketingVersion else { throw Failure(message: "The helper and application versions differ. Restore a matching bundle before removal.") }
        verified = true
    }

    private func call<Value: Sendable>(_ send: (HelperMaintenanceProtocol, OnceResumer<Result<Value, Failure>>) -> Void) async throws -> Value {
        let connection = try ensureConnection()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Failure>, Never>) in
            let once = OnceResumer<Result<Value, Failure>> { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { once.resume(.failure(Failure(message: "Helper maintenance timed out. Its outcome is unknown; retry or restore the pending transaction."))) }
            let failure: @Sendable (any Error) -> Void = { _ in once.resume(.failure(Failure(message: "The signed helper maintenance service is unavailable. Check approval and matching versions."))) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(failure) as? HelperMaintenanceProtocol else { failure(HelperRemovalFailure.invalidReservation); return }
            send(proxy, once)
        }
        do {
            let value = try result.get()
            guard connection === self.connection, connection.effectiveUserIdentifier == 0 else { throw Failure(message: "Helper maintenance peer changed during the operation.") }
            return value
        } catch {
            if connection === self.connection { connection.invalidate(); self.connection = nil; verified = false }
            throw error
        }
    }

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let requirement = ComponentTrust.requirement(role: .helper) else { throw Failure(message: "Maintenance requires a team-signed application and helper.") }
        let connection = NSXPCConnection(machServiceName: WakeLeaseIdentity.helperMaintenanceMachServiceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperMaintenanceProtocol.self)
        self.connection = connection
        connection.resume()
        return connection
    }

    isolated deinit { connection?.invalidate() }
}
