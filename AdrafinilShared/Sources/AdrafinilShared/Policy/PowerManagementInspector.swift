import Foundation
import IOKit

public enum PowerManagementInspector {
    public static func parseSleepDisabled(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2, parts[0] == "SleepDisabled" {
                if parts[1] == "0" { return false }
                if parts[1] == "1" { return true }
            }
        }
        return nil
    }

    static func resolveSleepDisabled(_ text: String, liveSetting: Bool?) -> Bool? {
        if let configured = parseSleepDisabled(text) { return configured || liveSetting == true }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("System-wide power settings:"), lines.contains("Currently in use:"),
              !lines.contains(where: { $0.hasPrefix("SleepDisabled") }) else { return nil }
        return liveSetting
    }

    public static func readSleepDisabled() throws -> Bool? {
        let result = try BoundedProcess.run(arguments: ["/usr/bin/pmset", "-g"], timeout: 2)
        guard result.status == 0 else { throw LocalIOError.system(result.status) }
        return resolveSleepDisabled(String(decoding: result.output, as: UTF8.self), liveSetting: readLiveSleepDisabled())
    }

    private static func readLiveSleepDisabled() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}
