import AdrafinilShared
import Darwin
import Foundation
import Security

struct InstallerFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

func loadRecord(_ url: URL) throws -> InstalledComponentTrust {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let data = try handle.read(upToCount: 16_385), data.count <= 16_384 else { throw LocalIOError.unsafePath }
    let record = try JSONDecoder().decode(InstalledComponentTrust.self, from: data)
    guard record.requirement(identifier: WakeLeaseIdentity.appBundleID) != nil else { throw LocalIOError.unsafePath }
    return record
}

func verifyBundle(_ bundle: URL, record: InstalledComponentTrust) throws {
    let components = [
        (WakeLeaseIdentity.appBundleID, bundle),
        (WakeLeaseIdentity.cliBundleID, bundle.appendingPathComponent("Contents/Helpers/wakelease")),
        (WakeLeaseIdentity.daemonBundleID, bundle.appendingPathComponent("Contents/Library/LaunchAgents/WakeLeaseDaemon")),
        (WakeLeaseIdentity.helperBundleID, bundle.appendingPathComponent("Contents/Library/LaunchDaemons/WakeLeaseHelper")),
    ]
    let forbidden = [
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-jit",
    ]
    for (identifier, url) in components {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var information: CFDictionary?
        guard let text = record.requirement(identifier: identifier),
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw InstallerFailure(message: "Installed component failed code-hash, signature or hardened-runtime validation: " + identifier)
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard !forbidden.contains(where: { (entitlements[$0] as? NSNumber)?.boolValue == true }) else {
            throw InstallerFailure(message: "A component contains development-only execution entitlements: " + identifier)
        }
    }
}

func prepareSystemDirectory() throws {
    let parent = InstalledComponentTrust.standardDirectory.deletingLastPathComponent()
    let created = mkdir(parent.path, 0o755) == 0
    guard created || errno == EEXIST else { throw LocalIOError.system(errno) }
    let storage = try SecureDirectory(url: parent, create: false, privateDirectory: false, ownerUID: 0, requireProtectedACLs: true)
    if created {
        guard fchmod(storage.descriptor, 0o755) == 0 else { throw LocalIOError.system(errno) }
    }
    var info = stat()
    guard fstat(storage.descriptor, &info) == 0, info.st_mode & 0o005 == 0o005 else {
        throw InstallerFailure(message: "The protected helper directory is not readable by local applications. Its existing permissions were not changed.")
    }
}

func verifyIdle() throws {
    let helper = try BoundedProcess.run(arguments: ["/bin/launchctl", "print", "system/" + WakeLeaseIdentity.helperBundleID], timeout: 5)
    guard helper.status == 113 else {
        throw InstallerFailure(message: "WakeLease services must be uninstalled from the app before replacing this installation. No active work was stopped.")
    }
    for name in ["WakeLease", "WakeLeaseMenu", "WakeLeaseDaemon", "WakeLeaseHelper"] {
        let process = try BoundedProcess.run(arguments: ["/usr/bin/pgrep", "-x", name], timeout: 5)
        guard process.status == 1 else { throw InstallerFailure(message: "Quit WakeLease and stop its services in every logged-in user account before installing.") }
    }
    guard try PowerManagementInspector.readSleepDisabled() == false else {
        throw InstallerFailure(message: "SleepDisabled is not confirmed off. The installer will not change power settings; resolve the existing state first.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.count == 3, arguments[0] == "verify", arguments[1].hasPrefix("/"), arguments[2].hasPrefix("/") {
        try verifyBundle(URL(fileURLWithPath: arguments[1]), record: loadRecord(URL(fileURLWithPath: arguments[2])))
        print("Package component identities verified")
    } else {
        guard getuid() == 0, arguments.count == 2, arguments[1] == "/", ["preflight", "activate", "cancel", "remove-approval"].contains(arguments[0]),
              let executable = Bundle.main.executableURL else { throw InstallerFailure(message: "Use the administrator-approved WakeLease installer package.") }
        let record = try loadRecord(executable.deletingLastPathComponent().appendingPathComponent("components.json"))
        let transaction = InstalledPackageTransaction()
        switch arguments[0] {
        case "preflight":
            try prepareSystemDirectory()
            try transaction.begin(record, verifyIdle: verifyIdle)
        case "activate":
            try transaction.activate(record) { try verifyBundle(URL(fileURLWithPath: "/Applications/WakeLease.app"), record: record) }
        case "cancel": try transaction.cancel(record, verifyIdle: verifyIdle)
        case "remove-approval":
            try prepareSystemDirectory()
            let installed = try InstalledComponentTrust.load() ?? record
            try transaction.begin(installed, verifyIdle: verifyIdle)
            try transaction.revoke(installed)
        default: throw LocalIOError.unsafePath
        }
        print("WakeLease installer phase completed: " + arguments[0])
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
