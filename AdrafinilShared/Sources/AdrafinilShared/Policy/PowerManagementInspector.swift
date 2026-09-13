import Foundation

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

    public static func readSleepDisabled() throws -> Bool? {
        let result = try BoundedProcess.run(arguments: ["/usr/bin/pmset", "-g"], timeout: 2)
        guard result.status == 0 else { throw LocalIOError.system(result.status) }
        return parseSleepDisabled(String(decoding: result.output, as: UTF8.self))
    }
}
