import AdrafinilShared
import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct WakeLeaseApp: App {
    @NSApplicationDelegateAdaptor(LeaseAppDelegate.self) private var delegate
    @State private var model: MenuModel

    init() {
        let arguments = CommandLine.arguments
        let preview = arguments.firstIndex(of: "--preview").map { index in index + 1 < arguments.count ? arguments[index + 1] : "active" }
        let model = MenuModel(previewState: preview)
        _model = State(initialValue: model)
        LeaseAppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.preferences.showMenuBar }, set: { value in model.changePreferences { $0.showMenuBar = value } })) {
            LeaseMenu(model: model)
        } label: {
            Image(systemName: model.presentation.symbol)
                .accessibilityLabel(WakeLeaseIdentity.name + ": " + model.presentation.title)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { LeaseAppDelegate.shared?.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class LeaseAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    weak static var shared: LeaseAppDelegate?
    static var model: MenuModel?
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self
        ProcessInfo.processInfo.disableAutomaticTermination(WakeLeaseIdentity.name + " is a resident menu-bar utility")
        NSApp.setActivationPolicy(.accessory)
        guard let model = Self.model else { return }
        if !model.preview, let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != getpid() }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        if model.preview {
            if CommandLine.arguments.contains("--custom-integration") {
                previewWindow = window(title: "WakeLease Custom Integration", view: CustomIntegrationSetup(cliPath: ServiceRegistry.bundledCLI.path, copy: model.copy, close: {}), size: NSSize(width: 620, height: 650))
                exportSnapshotIfRequested(previewWindow)
            } else if CommandLine.arguments.contains("--settings") {
                showSettings()
                exportSnapshotIfRequested(settingsWindow)
            } else {
                previewWindow = window(title: "WakeLease Preview", view: LeaseMenu(model: model), size: NSSize(width: 382, height: 510))
                exportSnapshotIfRequested(previewWindow)
            }
        } else {
            UNUserNotificationCenter.current().delegate = self
            model.start()
            if !ServiceRegistry.isPackaged || ServiceRegistry.statuses()["Daemon"] != "Enabled" { showSettings() }
        }
    }

    private func exportSnapshotIfRequested(_ window: NSWindow?) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count, let window else { return }
        if arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let view = window.contentView?.superview else { return }
            view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                if let data = image.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .withoutOverwriting) }
                    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        guard let model = Self.model else { return }
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        settingsWindow = window(title: "WakeLease Settings", view: LeaseSettings(model: model), size: NSSize(width: 640, height: 540))
    }

    private func window(title: String, view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { settingsWindow = nil }
        if notification.object as? NSWindow === previewWindow { previewWindow = nil }
        if settingsWindow == nil, previewWindow == nil { NSApp.setActivationPolicy(.accessory) }
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
