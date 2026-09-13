import AdrafinilShared
import Foundation

@MainActor
final class LeaseHelperConnection {
    enum Failure: Int, Error, Sendable {
        case signingRequired = 1, unavailable, timedOut, rejected, versionMismatch
    }
    private var connection: NSXPCConnection?
    private var connectionToken: UUID?
    private var verifiedVersion: String?
    private(set) var isConnected = false
    var onDisconnect: (() -> Void)?

    func setBlocked(_ value: Bool) async throws {
        if verifiedVersion == nil {
            let version: String = try await call { proxy, once in
                proxy.version { once.resume(.success($0)) }
            }
            guard version == WakeLeaseIdentity.marketingVersion else { throw Failure.versionMismatch }
            verifiedVersion = version
        }
        let applied: Bool = try await call { proxy, once in
            proxy.setSleepBlocked(value) { applied, error in
                once.resume(error == nil ? .success(applied) : .failure(.rejected))
            }
        }
        guard applied == value else { throw Failure.rejected }
    }

    func globalBlocked() async throws -> Bool {
        try await call { proxy, once in proxy.sleepBlockedState { once.resume(.success($0)) } }
    }

    func disconnect() {
        let old = connection
        connection = nil
        connectionToken = nil
        verifiedVersion = nil
        isConnected = false
        old?.invalidate()
    }

    private func call<T: Sendable>(_ send: (HelperXPCProtocol, OnceResumer<Result<T, Failure>>) -> Void) async throws -> T {
        let conn = try ensureConnection()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Failure>, Never>) in
            let once = OnceResumer<Result<T, Failure>> { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { once.resume(.failure(.timedOut)) }
            let onError: @Sendable (any Error) -> Void = { _ in once.resume(.failure(.unavailable)) }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler(onError) as? HelperXPCProtocol else {
                once.resume(.failure(.unavailable))
                return
            }
            send(proxy, once)
        }
        do {
            let value = try result.get()
            guard conn === connection, conn.effectiveUserIdentifier == 0 else { throw Failure.unavailable }
            isConnected = true
            return value
        } catch {
            if conn === connection { disconnect() }
            throw error
        }
    }

    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let requirement = ComponentTrust.requirement(role: .helper) else { throw Failure.signingRequired }
        let connection = NSXPCConnection(machServiceName: WakeLeaseIdentity.helperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        let token = UUID()
        connectionToken = token
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionToken == token else { return }
                self.disconnect()
                self.onDisconnect?()
            }
        }
        connection.interruptionHandler = ended
        connection.invalidationHandler = ended
        self.connection = connection
        connection.resume()
        return connection
    }
}
