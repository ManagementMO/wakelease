import Darwin
import Foundation

public struct CLILinkManager: Sendable {
    private struct Receipt: Codable {
        let version: Int
        let destination: String
        let target: String
    }
    public let home: URL
    public let stateDirectory: URL
    public var destination: URL {
        home.appendingPathComponent(".local/bin/" + WakeLeaseIdentity.cliBinaryName)
    }
    private let receiptName = "cli-install.json"

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), stateDirectory: URL = WakeLeasePaths.directory) {
        self.home = home
        self.stateDirectory = stateDirectory
    }

    public func install(target: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: target.path) else { throw LocalIOError.unsafePath }
        let directory = try SecureDirectory(url: destination.deletingLastPathComponent(), create: true, privateDirectory: false)
        let state = try SecureDirectory(url: stateDirectory, create: true)
        let lock = try state.lock(name: "cli-install.lock")
        defer { Darwin.close(lock) }
        let receipt = try readReceipt(state)
        if let current = try directory.symbolicLinkTarget(name: destination.lastPathComponent) {
            guard receipt?.target == current, current == target.path else { throw LeaseIntegrationFailure.unmanaged }
            return
        }
        let next = Receipt(version: 1, destination: destination.path, target: target.path)
        try state.write(JSONEncoder().encode(next), name: receiptName)
        try directory.createSymbolicLink(name: destination.lastPathComponent, target: target.path)
    }

    public func uninstall() throws {
        let state: SecureDirectory
        do { state = try SecureDirectory(url: stateDirectory, create: false) }
        catch LocalIOError.system(ENOENT) { return }
        let lock = try state.lock(name: "cli-install.lock")
        defer { Darwin.close(lock) }
        guard let receipt = try readReceipt(state) else { return }
        do {
            let directory = try SecureDirectory(url: destination.deletingLastPathComponent(), create: false, privateDirectory: false)
            if let current = try directory.symbolicLinkTarget(name: destination.lastPathComponent) {
                guard current == receipt.target else { throw LeaseIntegrationFailure.modified }
                try directory.removeSymbolicLink(name: destination.lastPathComponent, target: receipt.target)
            }
        } catch LocalIOError.system(ENOENT) {}
        if let data = try state.read(name: receiptName) { try state.remove(name: receiptName, matching: data) }
    }

    public func inspect() -> String {
        do {
            let state = try SecureDirectory(url: stateDirectory, create: false)
            guard let receipt = try readReceipt(state) else { return "not installed by WakeLease" }
            let directory = try SecureDirectory(url: destination.deletingLastPathComponent(), create: false, privateDirectory: false)
            guard try directory.symbolicLinkTarget(name: destination.lastPathComponent) == receipt.target else { return "externally modified" }
            return FileManager.default.isExecutableFile(atPath: receipt.target) ? "owned link is healthy" : "owned link target is missing"
        } catch { return "not installed or unverifiable" }
    }

    private func readReceipt(_ directory: SecureDirectory) throws -> Receipt? {
        guard let data = try directory.read(name: receiptName, maximum: 16_384) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.version == 1, receipt.destination == destination.path, receipt.target.hasPrefix("/"), !receipt.target.utf8.contains(0) else { throw LeaseIntegrationFailure.invalidReceipt }
        return receipt
    }
}
