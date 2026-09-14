import AdrafinilShared
import Foundation

enum PreviewUIAudit {
    static func pasteboardName(arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: "--preview-pasteboard") else { return nil }
        guard let preview = arguments.firstIndex(of: "--preview"), preview + 1 < arguments.count,
              ["active", "normal", "waiting", "cutout", "paused"].contains(arguments[preview + 1]),
              index + 1 < arguments.count, !arguments.contains("--uninstall"),
              arguments[index + 1].range(of: "\\Awakelease-ui-test-[a-f0-9-]{1,64}\\z", options: .regularExpression) != nil else {
            throw LeaseCLIUsageError("An isolated clipboard requires --preview <state> and a wakelease-ui-test- identifier.")
        }
        return arguments[index + 1]
    }
}
