import CryptoKit
import Darwin
import Foundation

public struct LeaseIntegrationReport: Sendable {
    public let changed: Bool
    public let diff: String
}

public struct LeaseIntegrationHealth: Codable, Sendable {
    public let id: String
    public let state: String
    public let note: String
}

public struct LeaseIntegrationManager: Sendable {
    private struct FileReceipt: Codable {
        var path: String
        var originalHash: String?
        var installedHash: String
        var backupName: String?
        var permissions: UInt16
        var bindings: [ManagedLeaseHook]
    }
    private struct Receipt: Codable {
        let version: Int
        let id: String
        let cliPath: String
        var files: [FileReceipt]
    }
    private struct Prepared {
        let url: URL
        let before: Data?
        let after: Data
        var receipt: FileReceipt
    }

    public let home: URL
    public let stateDirectory: URL
    public let cliPath: String
    private var receiptDirectory: URL {
        stateDirectory.appendingPathComponent("integrations", isDirectory: true)
    }

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), stateDirectory: URL = WakeLeasePaths.directory, cliPath: String) {
        self.home = home
        self.stateDirectory = stateDirectory
        self.cliPath = cliPath
    }

    public func configurationURLs(for id: String) throws -> [URL] {
        try LeaseIntegrations.descriptor(id).relativeFiles.map { home.appendingPathComponent($0) }
    }

    public func install(_ id: String, dryRun: Bool = false) throws -> LeaseIntegrationReport {
        let descriptor = try LeaseIntegrations.descriptor(id)
        guard descriptor.format != .manual else { throw LeaseIntegrationFailure.manual(descriptor.note) }
        let storage = try dryRun ? nil : SecureDirectory(url: receiptDirectory, create: true)
        let lock = try storage?.lock(name: "install.lock") ?? -1
        defer { if lock >= 0 { Darwin.close(lock) } }
        let old = try loadReceipt(id)
        let bindings = descriptor.hooks.map { ManagedLeaseHook(event: $0.event, matcher: $0.matcher, command: LeaseIntegrations.command(cliPath: cliPath, id: id, action: $0.action)) }
        var prepared: [Prepared] = []
        for (index, relative) in descriptor.relativeFiles.enumerated() {
            let url = home.appendingPathComponent(relative)
            let before = try read(url)
            let oldFile = old?.files.first { $0.path == relative }
            let after: Data
            switch descriptor.format {
            case .nestedJSON, .flatJSON:
                var editor = try LeaseJSONHooks(data: before, flat: descriptor.format == .flatJSON)
                after = try editor.replace(old: oldFile?.bindings ?? [], new: bindings, original: before)
            case .piPlugin, .openCodePlugin, .scripts:
                if let before {
                    guard let oldFile else { throw LeaseIntegrationFailure.unmanaged }
                    guard digest(before) == oldFile.installedHash else { throw LeaseIntegrationFailure.modified }
                } else if oldFile != nil { throw LeaseIntegrationFailure.modified }
                if descriptor.format == .scripts {
                    after = Data(("#!/bin/sh\nexec " + LeaseIntegrations.command(cliPath: cliPath, id: id, action: descriptor.hooks[index].action) + "\n").utf8)
                } else { after = Data(LeaseIntegrations.plugin(descriptor, cliPath: cliPath).utf8) }
            case .manual: throw LeaseIntegrationFailure.manual(descriptor.note)
            }
            let originalPermissions = try permissions(url) ?? (descriptor.format == .scripts ? 0o700 : 0o600)
            var record = oldFile ?? FileReceipt(path: relative, originalHash: before.map(digest), installedHash: digest(after), backupName: before == nil ? nil : "backup-" + UUID().uuidString + ".bin", permissions: originalPermissions, bindings: [])
            record.installedHash = digest(after)
            record.bindings = descriptor.format == .nestedJSON || descriptor.format == .flatJSON ? bindings : []
            prepared.append(Prepared(url: url, before: before, after: after, receipt: record))
        }
        let changed = prepared.contains { $0.before != $0.after }
        let diff = changed ? prepared.filter { $0.before != $0.after }.map { file in
            let commands = file.receipt.bindings.map { "  \($0.event): \($0.command)" }.joined(separator: "\n")
            return "\(file.before == nil ? "+" : "~") \(file.url.path)\n" + (commands.isEmpty ? "  WakeLease-owned integration file" : commands)
        }.joined(separator: "\n") : "(unchanged)"
        guard !dryRun, let storage, changed else { return LeaseIntegrationReport(changed: changed, diff: diff) }
        if old == nil {
            for file in prepared {
                if let backup = file.receipt.backupName, let before = file.before { try storage.write(before, name: backup) }
            }
        }
        let receipt = Receipt(version: 1, id: id, cliPath: cliPath, files: prepared.map(\.receipt))
        try storage.write(JSONEncoder().encode(receipt), name: id + ".json")
        for file in prepared where file.before != file.after {
            guard try read(file.url) == file.before else { throw LeaseIntegrationFailure.concurrentModification }
            let parent = try SecureDirectory(url: file.url.deletingLastPathComponent(), create: true, privateDirectory: false)
            try parent.write(file.after, name: file.url.lastPathComponent, permissions: file.receipt.permissions)
        }
        return LeaseIntegrationReport(changed: true, diff: diff)
    }

    public func uninstall(_ id: String, dryRun: Bool = false) throws -> LeaseIntegrationReport {
        let descriptor = try LeaseIntegrations.descriptor(id)
        guard try loadReceipt(id) != nil else { return LeaseIntegrationReport(changed: false, diff: "(unchanged)") }
        let storage = try SecureDirectory(url: receiptDirectory, create: false)
        let lock = try dryRun ? -1 : storage.lock(name: "install.lock")
        defer { if lock >= 0 { Darwin.close(lock) } }
        guard let receipt = try loadReceipt(id) else { return LeaseIntegrationReport(changed: false, diff: "(unchanged)") }
        var changes: [(URL, Data, Data?, UInt16)] = []
        for (index, file) in receipt.files.enumerated() {
            let url = home.appendingPathComponent(file.path)
            guard let current = try read(url) else { continue }
            let original = try backupData(for: id, fileIndex: index)
            if digest(current) == file.originalHash { continue }
            let restored: Data?
            if digest(current) == file.installedHash { restored = original }
            else if descriptor.format == .nestedJSON || descriptor.format == .flatJSON {
                var editor = try LeaseJSONHooks(data: current, flat: descriptor.format == .flatJSON)
                restored = try editor.replace(old: file.bindings, new: [], original: current, removing: true)
            } else { throw LeaseIntegrationFailure.modified }
            changes.append((url, current, restored, file.permissions))
        }
        let diff = changes.isEmpty ? "(unchanged)" : changes.map { "\($0.2 == nil ? "-" : "~") \($0.0.path): remove only recorded WakeLease content" }.joined(separator: "\n")
        guard !dryRun else { return LeaseIntegrationReport(changed: !changes.isEmpty, diff: diff) }
        for (url, before, after, permissions) in changes {
            guard try read(url) == before else { throw LeaseIntegrationFailure.concurrentModification }
            let parent = try SecureDirectory(url: url.deletingLastPathComponent(), create: false, privateDirectory: false)
            if let after { try parent.write(after, name: url.lastPathComponent, permissions: permissions) }
            else { try parent.remove(name: url.lastPathComponent, matching: before) }
        }
        if let receiptData = try storage.read(name: id + ".json") { try storage.remove(name: id + ".json", matching: receiptData) }
        return LeaseIntegrationReport(changed: !changes.isEmpty, diff: diff)
    }

    public func backupData(for id: String, fileIndex: Int) throws -> Data? {
        guard let receipt = try loadReceipt(id), receipt.files.indices.contains(fileIndex) else { return nil }
        let file = receipt.files[fileIndex]
        guard let name = file.backupName else { return nil }
        let storage = try SecureDirectory(url: receiptDirectory, create: false)
        guard let data = try storage.read(name: name), digest(data) == file.originalHash else { throw LeaseIntegrationFailure.invalidReceipt }
        return data
    }

    public func health(_ id: String) -> LeaseIntegrationHealth {
        do {
            let descriptor = try LeaseIntegrations.descriptor(id)
            if descriptor.format == .manual { return LeaseIntegrationHealth(id: id, state: "manual", note: descriptor.note) }
            guard let receipt = try loadReceipt(id) else {
                if descriptor.format == .nestedJSON || descriptor.format == .flatJSON, let data = try read(home.appendingPathComponent(descriptor.relativePath)) {
                    _ = try LeaseJSONHooks(data: data, flat: descriptor.format == .flatJSON)
                }
                return LeaseIntegrationHealth(id: id, state: "notConfigured", note: descriptor.note)
            }
            guard FileManager.default.isExecutableFile(atPath: receipt.cliPath) else { return LeaseIntegrationHealth(id: id, state: "missingExecutable", note: "The recorded hook executable is missing. Review setup from the current app.") }
            for file in receipt.files {
                guard let data = try read(home.appendingPathComponent(file.path)) else { throw LeaseIntegrationFailure.modified }
                if descriptor.format == .nestedJSON || descriptor.format == .flatJSON {
                    let editor = try LeaseJSONHooks(data: data, flat: descriptor.format == .flatJSON)
                    for hook in file.bindings where try !editor.contains(hook) {
                        throw LeaseIntegrationFailure.modified
                    }
                } else if digest(data) != file.installedHash { throw LeaseIntegrationFailure.modified }
            }
            return LeaseIntegrationHealth(id: id, state: descriptor.requiresApproval ? "needsApproval" : "configured", note: descriptor.note)
        } catch { return LeaseIntegrationHealth(id: id, state: "modifiedOrUnreadable", note: error.localizedDescription) }
    }

    private func loadReceipt(_ id: String) throws -> Receipt? {
        let descriptor = try LeaseIntegrations.descriptor(id)
        do {
            let storage = try SecureDirectory(url: receiptDirectory, create: false)
            guard let data = try storage.read(name: id + ".json", maximum: 131_072) else { return nil }
            let receipt = try JSONDecoder().decode(Receipt.self, from: data)
            guard receipt.version == 1, receipt.id == id, receipt.files.map(\.path) == descriptor.relativeFiles else { throw LeaseIntegrationFailure.invalidReceipt }
            return receipt
        } catch LocalIOError.system(ENOENT) { return nil }
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try SecureDirectory(url: url.deletingLastPathComponent(), create: false, privateDirectory: false).read(name: url.lastPathComponent) }
        catch LocalIOError.system(ENOENT) { return nil }
    }

    private func permissions(_ url: URL) throws -> UInt16? {
        do { return try SecureDirectory(url: url.deletingLastPathComponent(), create: false, privateDirectory: false).permissions(name: url.lastPathComponent) }
        catch LocalIOError.system(ENOENT) { return nil }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
