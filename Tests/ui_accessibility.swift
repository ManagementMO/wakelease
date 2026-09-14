import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AuditFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

@MainActor
final class UIAuditor {
    struct Node: Encodable {
        let role: String
        let label: String?
        let title: String?
        let identifier: String?
        let value: String?
        let enabled: Bool?
    }

    let pid: pid_t
    let application: AXUIElement
    let pasteboard: NSPasteboard
    var checks: [String] = []

    init(pid: pid_t, clipboard: String) {
        self.pid = pid
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: clipboard))
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func elements() -> [AXUIElement] {
        var result: [AXUIElement] = []
        var visited = Set<CFHashCode>()
        var queue = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        while let element = queue.popLast(), result.count < 2_000 {
            guard visited.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return result
    }

    func node(_ element: AXUIElement) -> Node {
        let value = attribute(element, kAXValueAttribute)
        var label = attribute(element, kAXDescriptionAttribute) as? String
        if label == nil, let linked = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(linked) == AXUIElementGetTypeID() {
            let titleElement = unsafeBitCast(linked, to: AXUIElement.self)
            label = attribute(titleElement, kAXValueAttribute) as? String ?? attribute(titleElement, kAXTitleAttribute) as? String
        }
        return Node(role: attribute(element, kAXRoleAttribute) as? String ?? "unknown", label: label, title: attribute(element, kAXTitleAttribute) as? String, identifier: attribute(element, kAXIdentifierAttribute) as? String, value: value as? String ?? (value as? NSNumber)?.stringValue, enabled: (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue)
    }

    func wait(_ description: String, until predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AuditFailure(message: "Timed out waiting for " + description)
    }

    func find(_ name: String, roles: Set<String> = []) -> AXUIElement? {
        elements().first { element in
            let item = node(element)
            return (roles.isEmpty || roles.contains(item.role)) && [item.label, item.title, item.value, item.identifier].contains(name)
        }
    }

    func require(_ name: String, roles: Set<String> = []) throws -> AXUIElement {
        var found: AXUIElement?
        try wait(name) { found = find(name, roles: roles); return found != nil }
        guard let found else { throw AuditFailure(message: "Missing accessibility element: " + name) }
        return found
    }

    func press(_ name: String) throws {
        let element = try require(name, roles: ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton"])
        guard node(element).enabled == true else { throw AuditFailure(message: "Control is disabled: " + name) }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else { throw AuditFailure(message: "Press failed: \(name), \(result.rawValue)") }
    }

    func setText(_ name: String, _ text: String) throws {
        let element = try require(name, roles: ["AXTextField"])
        guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
            throw AuditFailure(message: "Text editing failed: " + name)
        }
        try wait("updated " + name) { attribute(element, kAXValueAttribute) as? String == text }
    }

    func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw AuditFailure(message: "Keyboard event unavailable") }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    func customCommands() throws {
        let source = "Source identifier"
        let variable = "Work identifier environment variable"
        _ = try require(source, roles: ["AXTextField"])
        _ = try require(variable, roles: ["AXTextField"])
        checks.append("native-accessibility-labels")
        try setText(source, "ui-audit-one")
        try key(48)
        let next = try require(variable, roles: ["AXTextField"])
        try wait("Tab focus") { (attribute(next, kAXFocusedAttribute) as? NSNumber)?.boolValue == true }
        try key(48, flags: .maskShift)
        let previous = try require(source, roles: ["AXTextField"])
        try wait("Shift-Tab focus") { (attribute(previous, kAXFocusedAttribute) as? NSNumber)?.boolValue == true }
        checks.append("tab-navigation")
        try setText(variable, "JOB_KEY")
        try press("Copy Work starts / resumes command")
        try wait("isolated copied command") {
            let text = pasteboard.string(forType: .string) ?? ""
            return text.contains("ui-audit-one:") && text.contains("${JOB_KEY}")
        }
        checks.append("isolated-copy-command")
        _ = try require("Command or recipe copied.")
        try setText(source, "ui-audit-two")
        _ = try require("Nothing is installed automatically.")
        checks.append("copy-feedback-invalidated-on-edit")
        try press("Keep the display awake for screen-dependent work")
        try press("Copy recipe as JSON")
        try wait("current JSON recipe") {
            guard let text = pasteboard.string(forType: .string), let data = text.data(using: .utf8),
                  let recipe = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return recipe["source"] as? String == "ui-audit-two" && recipe["wakeClass"] as? String == "display" && recipe["sessionVariable"] as? String == "JOB_KEY"
        }
        checks.append("display-and-json-recipe")
        try setText(variable, "${invalid}")
        try wait("invalid recipe copy removal") { find("Copy recipe as JSON") == nil }
        _ = try require("Work ID source must be a shell variable name, not an expression.")
        checks.append("invalid-recipe-blocks-copy")
        try setText(variable, "JOB_KEY")
    }

    func settingsWorkflow() throws {
        _ = try require("Preview data only. No service or power operations are enabled.")
        let services = try require("Enable WakeLease Services…")
        guard node(services).enabled == false else { throw AuditFailure(message: "Preview unexpectedly permits service installation") }
        let toggle = try require("Show in menu bar", roles: ["AXCheckBox"])
        let original = node(toggle).value
        try press("Show in menu bar")
        try wait("hidden menu-bar setting") { node(toggle).value != original }
        try press("Show in menu bar")
        try wait("restored menu-bar setting") { node(toggle).value == original }
        checks.append("menu-visibility-toggle")
        for (section, content) in [("Waiting", "When work needs you"), ("Safety", "Safety outranks work"), ("Advanced", "Privacy and diagnostics"), ("Integrations", "Connect work, not application lifetimes.")] {
            try press(section)
            _ = try require(content)
        }
        checks.append("settings-section-navigation")
        try press("Custom Integration…")
        try customCommands()
        try key(53)
        try wait("Escape dismisses custom setup") { find("Source identifier", roles: ["AXTextField"]) == nil }
        checks.append("escape-closes-custom-sheet")
        try press("Custom Integration…")
        _ = try require("Source identifier", roles: ["AXTextField"])
        try key(36)
        try wait("Return dismisses custom setup") { find("Source identifier", roles: ["AXTextField"]) == nil }
        checks.append("return-closes-custom-sheet")
    }

    func report() throws -> String {
        struct Report: Encodable {
            let version = 1
            let scope = "preview-only"
            let clipboardIsolated: Bool
            let checks: [String]
            let nodes: [Node]
        }
        let report = Report(clipboardIsolated: pasteboard.name != NSPasteboard.general.name, checks: checks, nodes: elements().map(node))
        return try String(decoding: JSONEncoder().encode(report), as: UTF8.self)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (3 ... 4).contains(arguments.count), let pid = pid_t(arguments[0]), pid > 0,
      arguments[2].range(of: "\\Awakelease-ui-test-[a-f0-9-]{1,64}\\z", options: .regularExpression) != nil,
      arguments.count == 3 || ["inspect", "workflow"].contains(arguments[3]) else { exit(64) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is unavailable; no permission change was requested.\n".utf8))
    exit(77)
}
let expected = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").resolvingSymlinksInPath()
guard expected.lastPathComponent == "WakeLeaseMenu", expected.path.hasPrefix(build.path + "/") else { exit(64) }
@MainActor
func runAudit() -> Int32 {
    let auditor = UIAuditor(pid: pid, clipboard: arguments[2])
    var owned = false
    defer { auditor.pasteboard.releaseGlobally() }
    do {
        try auditor.wait("the owned preview process") {
            NSRunningApplication(processIdentifier: pid)?.executableURL?.resolvingSymlinksInPath() == expected
        }
        owned = true
        try auditor.wait("native accessibility controls") { auditor.elements().count > 10 }
        if arguments.count == 4, arguments[3] == "workflow" { try auditor.settingsWorkflow() }
        try print(auditor.report())
        return 0
    } catch {
        if owned, let report = try? auditor.report() { print(report) }
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}

Task { @MainActor in exit(runAudit()) }
RunLoop.main.run()
