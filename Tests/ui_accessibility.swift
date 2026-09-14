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
        let placeholder: String?
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

    func elements(in root: AXUIElement? = nil) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var visited = Set<CFHashCode>()
        var queue = root.map { [$0] } ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [])
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
        return Node(role: attribute(element, kAXRoleAttribute) as? String ?? "unknown", label: label, title: attribute(element, kAXTitleAttribute) as? String, identifier: attribute(element, kAXIdentifierAttribute) as? String, placeholder: attribute(element, kAXPlaceholderValueAttribute) as? String, value: value as? String ?? (value as? NSNumber)?.stringValue, enabled: (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue)
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
            return (roles.isEmpty || roles.contains(item.role)) && [item.label, item.title, item.value, item.identifier, item.placeholder].contains(name)
        }
    }

    func require(_ name: String, roles: Set<String> = []) throws -> AXUIElement {
        var found: AXUIElement?
        try wait(name) { found = find(name, roles: roles); return found != nil }
        guard let found else { throw AuditFailure(message: "Missing accessibility element: " + name) }
        return found
    }

    func press(_ name: String) throws {
        let element = try require(name, roles: ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXDisclosureTriangle"])
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

    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func settingsWindows() -> [AXUIElement] {
        (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            attribute($0, kAXTitleAttribute) as? String == "WakeLease Settings"
        }
    }

    func menuItemCount() -> Int {
        guard let menu = elementAttribute(application, kAXExtrasMenuBarAttribute) else { return 0 }
        return (attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []).count
    }

    func reopenApplication() async throws {
        let bundle = expected.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", let identifier = Bundle(url: bundle)?.bundleIdentifier,
              identifier.hasPrefix("org.wakelease.ui-test."), NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == identifier else {
            throw AuditFailure(message: "Reopen is restricted to the disposable preview bundle")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--preview", "normal", "--settings", "--preview-pasteboard", pasteboard.name.rawValue, "-ApplePersistenceIgnoreState", "YES"]
        let reopened = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        guard reopened.processIdentifier == pid else {
            if reopened.bundleIdentifier == identifier, reopened.executableURL?.resolvingSymlinksInPath() == expected { reopened.terminate() }
            throw AuditFailure(message: "Reopen started another process instead of reaching the hidden app")
        }
    }

    func reopenWorkflow() async throws {
        _ = try require("Preview data only. No service or power operations are enabled.")
        try wait("the owned menu-bar item") { menuItemCount() == 1 }
        try press("Show in menu bar")
        try wait("menu-bar item removal") { menuItemCount() == 0 }
        checks.append("menu-item-removed")
        guard let window = settingsWindows().first, let close = elementAttribute(window, kAXCloseButtonAttribute),
              AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else { throw AuditFailure(message: "Cannot close the settings window") }
        try wait("closed settings window") { settingsWindows().isEmpty }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { throw AuditFailure(message: "Closing settings terminated the hidden app") }
        checks.append("hidden-app-stays-running")
        try await reopenApplication()
        _ = try require("Preview data only. No service or power operations are enabled.")
        guard settingsWindows().count == 1 else { throw AuditFailure(message: "Reopen did not restore one settings window") }
        checks.append("reopen-restores-settings")
        let toggle = try require("Show in menu bar", roles: ["AXCheckBox"])
        guard node(toggle).value == "0", menuItemCount() == 0 else { throw AuditFailure(message: "Reopen changed the hidden-icon preference") }
        checks.append("reopen-preserves-hidden-preference")
        try await reopenApplication()
        guard settingsWindows().count == 1 else { throw AuditFailure(message: "Reopening visible settings duplicated the window") }
        checks.append("reopen-reuses-window")
        try press("Show in menu bar")
        try wait("restored menu-bar item") { menuItemCount() == 1 }
        checks.append("menu-item-restored")
    }

    func frame(_ element: AXUIElement) throws -> CGRect {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let dimensions = attribute(element, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID() else { throw AuditFailure(message: "Missing native element geometry: \(node(element))") }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw AuditFailure(message: "Invalid native element geometry") }
        return CGRect(origin: origin, size: size)
    }

    func checkHorizontalFit(_ element: AXUIElement, in bounds: CGRect) throws {
        let rect = try frame(element)
        guard rect.minX >= bounds.minX - 2, rect.maxX <= bounds.maxX + 2 else { throw AuditFailure(message: "Element exceeds the sheet width: \(node(element).role), \(rect), \(bounds)") }
    }

    func contentWorkflow() throws {
        _ = try require("Preview data only. No service or power operations are enabled.")
        try press("Integrations")
        try press("Custom Integration…")
        let shortLabel = try require("Work starts / resumes", roles: ["AXStaticText"])
        let shortHeight = try frame(shortLabel).height
        guard let sheet = elements().first(where: { node($0).role == "AXSheet" }) else { throw AuditFailure(message: "Missing custom integration sheet") }
        let bounds = try frame(sheet)
        let source = String(repeating: "s", count: 64)
        let variable = String(repeating: "W", count: 128)
        try setText("Source identifier", source)
        try setText("Work identifier environment variable", variable)
        try press("Name your host events (optional)")
        for (field, label) in [
            ("Start / resume event", String(repeating: "Start ", count: 20) + "resume!!"),
            ("Start / resume event", String(repeating: "S", count: 128)),
            ("Finish / cancel event", String(repeating: "F", count: 128)),
        ] {
            try setText(field, label)
            let text = try require(label, roles: ["AXStaticText"])
            let copy = try require("Copy \(label) command", roles: ["AXButton"])
            let textFrame = try frame(text)
            let copyFrame = try frame(copy)
            try checkHorizontalFit(text, in: bounds)
            try checkHorizontalFit(copy, in: bounds)
            guard textFrame.height > shortHeight, textFrame.maxX <= copyFrame.minX + 1 else { throw AuditFailure(message: "Long event label was truncated or overlapped its copy control") }
            try press("Copy \(label) command")
            try wait("maximum identity command copy") { pasteboard.string(forType: .string)?.contains("${\(variable)}") == true }
        }
        checks.append(contentsOf: ["long-event-labels-wrap", "long-label-copy-buttons-fit"])
        let executable = String(repeating: "x", count: 4_096)
        try setText("Executable for command wrapper", executable)
        try press("Copy recipe as JSON")
        guard let data = pasteboard.string(forType: .string)?.data(using: .utf8),
              let recipe = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              recipe["source"] as? String == source, recipe["sessionVariable"] as? String == variable,
              let wrapper = recipe["wrapper"] as? String, wrapper.hasSuffix("'\(executable)'"),
              let steps = recipe["steps"] as? [[String: Any]], steps.count == 4 else { throw AuditFailure(message: "Maximum-length recipe did not round trip exactly") }
        checks.append("maximum-recipe-content-round-trips")
        for command in steps.compactMap({ $0["command"] as? String }) + [wrapper] {
            try checkHorizontalFit(require(command, roles: ["AXStaticText"]), in: bounds)
        }
        checks.append("long-command-text-stays-in-sheet")
        guard let scroll = elements(in: sheet).first(where: { node($0).role == "AXScrollArea" }),
              let bar = elements(in: scroll).first(where: { node($0).role == "AXScrollBar" && attribute($0, kAXOrientationAttribute) as? String == kAXVerticalOrientationValue }),
              AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: 1)) == .success else { throw AuditFailure(message: "Oversized recipe cannot scroll to its final actions") }
        let copy = try require("Copy command wrapper", roles: ["AXButton"])
        try wait("visible final copy action") {
            guard let viewport = try? frame(scroll), let button = try? frame(copy) else { return false }
            return viewport.insetBy(dx: -2, dy: -2).contains(button)
        }
        try press("Copy command wrapper")
        try wait("complete long wrapper copy") { pasteboard.string(forType: .string) == wrapper }
        try checkHorizontalFit(require("Done", roles: ["AXButton"]), in: bounds)
        checks.append("oversized-content-scrolls-to-actions")
    }

    func validationWorkflow() throws {
        _ = try require("Preview data only. No service or power operations are enabled.")
        try press("Integrations")
        try press("Custom Integration…")
        try setText("Source identifier", "ui-validation")
        try setText("Work identifier environment variable", "JOB_KEY")
        let executable = "Executable for command wrapper"
        try setText(executable, String(repeating: "x", count: 4_097))
        _ = try require("Executable paths and event labels must be nonempty printable text.")
        let field = try require(executable, roles: ["AXTextField"])
        guard node(field).enabled == true else { throw AuditFailure(message: "Invalid executable cannot be edited") }
        checks.append("invalid-executable-remains-editable")
        guard find("Copy recipe as JSON") == nil, find("Copy command wrapper") == nil else { throw AuditFailure(message: "Invalid recipe still offers copy actions") }
        checks.append("invalid-recipe-clears-copy-actions")
        guard (attribute(field, kAXFocusedAttribute) as? NSNumber)?.boolValue == true else { throw AuditFailure(message: "Validation discarded input focus") }
        checks.append("error-focus-preserved")
        try setText(executable, "safe-ui-tool")
        try press("Copy command wrapper")
        try wait("corrected wrapper copy") { pasteboard.string(forType: .string)?.contains("'safe-ui-tool'") == true }
        _ = try require("Copy recipe as JSON")
        guard try node(require("Source identifier", roles: ["AXTextField"])).value == "ui-validation" else { throw AuditFailure(message: "Validation recovery discarded other fields") }
        checks.append("recipe-recovers-after-edit")
        for (name, invalid, restored, error) in [
            ("Source identifier", "", "ui-validation", "Use a source ID of 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number."),
            ("Work identifier environment variable", "${invalid}", "JOB_KEY", "Work ID source must be a shell variable name, not an expression."),
        ] {
            try setText(name, invalid)
            _ = try require(error)
            let input = try require(name, roles: ["AXTextField"])
            guard (attribute(input, kAXFocusedAttribute) as? NSNumber)?.boolValue == true, find("Copy recipe as JSON") == nil else { throw AuditFailure(message: "Invalid identity did not preserve editable focus and block copy") }
            try setText(name, restored)
            _ = try require("Copy recipe as JSON")
        }
        checks.append("invalid-identity-fields-recover")
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
      arguments.count == 3 || ["inspect", "workflow", "reopen", "validation", "content"].contains(arguments[3]) else { exit(64) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is unavailable; no permission change was requested.\n".utf8))
    exit(77)
}
let expected = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
let build = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build").resolvingSymlinksInPath()
guard expected.lastPathComponent == "WakeLeaseMenu", expected.path.hasPrefix(build.path + "/") else { exit(64) }
@MainActor
func runAudit() async -> Int32 {
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
        if arguments.count == 4, arguments[3] == "reopen" { try await auditor.reopenWorkflow() }
        if arguments.count == 4, arguments[3] == "validation" { try auditor.validationWorkflow() }
        if arguments.count == 4, arguments[3] == "content" { try auditor.contentWorkflow() }
        try print(auditor.report())
        return 0
    } catch {
        if owned, let report = try? auditor.report() { print(report) }
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}

Task { @MainActor in await exit(runAudit()) }
RunLoop.main.run()
