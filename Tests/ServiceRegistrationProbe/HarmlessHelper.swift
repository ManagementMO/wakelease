import Foundation

@main
private enum HarmlessRegistrationHelper {
    static func main() {
        print("WakeLease harmless CI registration helper; no power operations")
        guard let evidence = ProcessInfo.processInfo.environment["WAKELEASE_PROBE_EVIDENCE"], evidence.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: evidence)
        let directory = url.deletingLastPathComponent().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory),
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value, owner == getuid() || getuid() == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.uint32Value & 0o077 == 0 else { return }
        let report: [String: Any] = [
            "scope": "harmless dummy helper startup; no power operations",
            "pid": getpid(),
            "uid": getuid(),
            "parentPID": getppid(),
            "label": ProcessInfo.processInfo.environment["WAKELEASE_PROBE_LABEL"] ?? "",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .withoutOverwriting)
    }
}
