import AdrafinilShared
import Foundation
import SwiftUI

struct LeaseSettings: View {
    @Bindable var model: MenuModel
    @State private var confirmUninstall = false
    @State private var purgeState = false
    @State private var removeApplication = false
    @State private var showCustomIntegration = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $model.settingsTab) {
                Text("General").tag("general")
                Text("Waiting").tag("waiting")
                Text("Safety").tag("safety")
                Text("Integrations").tag("integrations")
                Text("Advanced").tag("advanced")
            }
            .pickerStyle(.segmented).labelsHidden().padding(16)
            Group {
                switch model.settingsTab {
                case "waiting": waiting
                case "safety": safety
                case "integrations": integrations
                case "advanced": advanced
                default: general
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = model.problem ?? model.information {
                Divider()
                Text(message).font(.caption).foregroundStyle(model.problem == nil ? Color.secondary : .orange)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 470, idealHeight: 540)
        .onAppear { model.refresh(); model.refreshIntegrations() }
        .sheet(item: $model.pendingIntegration) { change in
            VStack(alignment: .leading, spacing: 16) {
                Text(change.removing ? "Remove integration" : "Review integration changes").font(.title2.weight(.semibold))
                Text("Only recorded WakeLease content is changed. Backups remain private and local.").foregroundStyle(.secondary)
                ScrollView { Text(change.diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Spacer()
                    Button("Cancel") { model.pendingIntegration = nil }.keyboardShortcut(.cancelAction)
                    Button(change.removing ? "Remove" : "Apply") { model.applyIntegration(change) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 580, height: 390)
        }
        .sheet(isPresented: $showCustomIntegration) {
            CustomIntegrationSetup(cliPath: ServiceRegistry.bundledCLI.path, copy: model.copy, close: { showCustomIntegration = false })
        }
        .sheet(isPresented: $confirmUninstall) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Uninstall WakeLease?").font(.title2.weight(.semibold))
                Text("Active jobs may be interrupted by sleep. Coordinate with other Mac users before removing the machine-wide helper. WakeLease will pause, confirm cleanup, remove recorded integrations, and unregister its services. Modified or foreign files stop cleanup rather than being overwritten.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Remove local preferences, logs and backups", isOn: $purgeState)
                Toggle("Move the application to Trash", isOn: $removeApplication)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                    Button("Uninstall", role: .destructive) {
                        confirmUninstall = false
                        model.uninstall(purge: purgeState, removeApp: removeApplication)
                    }
                }
            }.padding(24).frame(width: 450)
        }
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("Status", value: model.presentation.title)
                if model.preview { Text("Preview data only. No service or power operations are enabled.").foregroundStyle(.secondary) }
                else if !ServiceRegistry.canInstall {
                    Text("Run the WakeLease installer from the DMG to approve this exact app and its helper components. Uninstalled development uses simulation; it does not keep the Mac awake.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Enable WakeLease Services…") { model.installServices() }
                    .disabled(model.preview || model.busy || !ServiceRegistry.canInstall)
                Button("Open Login Items & Extensions…") { ServiceRegistry.openApprovalSettings() }.disabled(model.preview)
            } header: { Text("Local services") }
            Section {
                Toggle("Show in menu bar", isOn: preference(\.showMenuBar))
                Toggle("Open menu bar at login", isOn: Binding(get: { model.preferences.launchMenuAtLogin }, set: { model.setLogin($0) }))
                    .disabled(model.preview || !ServiceRegistry.isPackaged)
                Toggle("Play a cue before closed-lid sleep", isOn: preference(\.preSleepCue))
                Toggle("Notify for safety cutoffs", isOn: Binding(get: { model.preferences.notifySafety }, set: { model.setNotifications($0) })).disabled(model.preview)
                Text("Quitting the menu bar does not stop the daemon or release active work. Reopen WakeLease to reach settings if the icon is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Menu bar") }
            Section {
                Toggle("Sleep promptly when the final lease ends", isOn: policy(\.sleepClosedLidOnFinalRelease))
                Text("Only with a confirmed closed lid and no external display or conflicting wake requirement. Otherwise normal macOS sleep behavior is restored.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Final release") }
            Section {
                Button("Uninstall WakeLease…", role: .destructive) { confirmUninstall = true }
                    .disabled(model.preview || model.busy || !ServiceRegistry.isPackaged)
            } header: { Text("Removal") }
        }.formStyle(.grouped)
    }

    private var waiting: some View {
        Form {
            Section {
                Picker("When work needs you", selection: policy(\.waitingPolicy)) {
                    Text("Grace period").tag(AgentWaitingPolicy.grace)
                    Text("Keep until the lease expires").tag(AgentWaitingPolicy.keepAwake)
                    Text("Allow sleep immediately").tag(AgentWaitingPolicy.sleep)
                }
                if model.preferences.policy.waitingPolicy == .grace {
                    Stepper(value: Binding(get: { Int(model.preferences.policy.waitingGraceSeconds / 60) }, set: { value in model.changePreferences { $0.policy.waitingGraceSeconds = Double(value * 60) } }), in: 1 ... 120) {
                        LabeledContent("Grace period", value: "\(Int(model.preferences.policy.waitingGraceSeconds / 60)) minutes")
                    }
                }
                Text("A heartbeat does not restart this grace. Resuming work acquires the lease again. A lease's own expiry always wins.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Waiting signals differ by tool. Some adapters cannot identify every approval or login prompt; finite lifetimes remain the backstop.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Capability limits") }
        }.formStyle(.grouped)
    }

    private var safety: some View {
        Form {
            Section {
                Stepper(value: policy(\.batteryCutoff), in: 10 ... 50) { LabeledContent("Battery cutoff", value: "\(model.preferences.policy.batteryCutoff)%") }
                Stepper(value: policy(\.thermalCutoff), in: 70 ... 95, step: 1) { LabeledContent("Temperature cutoff", value: "\(Int(model.preferences.policy.thermalCutoff)) °C") }
                Text("Cutoffs apply to closed-lid work. Battery re-arms above the cutoff plus five points or on AC. Thermal protection waits for sustained cooling; missing readings do not clear a temperature-dependent latch.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Safety outranks work") }
            Section {
                Stepper(value: Binding(get: { Int(model.preferences.policy.maximumTTLSeconds / 3_600) }, set: { value in model.changePreferences { $0.policy.maximumTTLSeconds = Double(value * 3_600) } }), in: 1 ... 24) {
                    LabeledContent("Maximum lease lifetime", value: "\(Int(model.preferences.policy.maximumTTLSeconds / 3_600)) hours")
                }
                Stepper(value: Binding(get: { Int(model.preferences.policy.defaultTTLSeconds / 3_600) }, set: { value in model.changePreferences { $0.policy.defaultTTLSeconds = Double(value * 3_600) } }), in: 1 ... max(1, Int(model.preferences.policy.maximumTTLSeconds / 3_600))) {
                    LabeledContent("Default lifetime", value: "\(Int(model.preferences.policy.defaultTTLSeconds / 3_600)) hours")
                }
                Text("Process birth identity and finite deadlines guard against crashed jobs and missed hooks. Automatic process sniffing and CPU-idle guesses are not used.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Stale work") }
            Text("Never put an actively computing Mac in a sealed or unventilated bag.").font(.callout.weight(.medium))
        }.formStyle(.grouped)
    }

    private var integrations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect work, not application lifetimes.").font(.headline)
                ForEach(LeaseIntegrations.all) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(model.integrationHealth.first(where: { $0.id == item.id })?.state ?? "Not checked").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.note).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if item.format != .manual {
                                Button("Review Setup…") { model.previewIntegration(item.id, removing: false) }
                                Button("Disconnect…") { model.previewIntegration(item.id, removing: true) }
                            } else {
                                Button("Copy Recipe Command") { model.copy("\(LeaseIntegrations.quote(ServiceRegistry.bundledCLI.path)) hooks generate --source \(item.id)") }
                            }
                        }.disabled(model.preview || model.busy)
                    }
                    Divider()
                }
                Button("Custom Integration…", systemImage: "plus") { showCustomIntegration = true }.disabled(model.busy)
                Text("Configured does not mean live-agent or closed-lid certified. Review the integration notes and test your workflow.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }

    private var advanced: some View {
        Form {
            Section {
                LabeledContent("Version", value: WakeLeaseIdentity.marketingVersion)
                LabeledContent("Mode", value: model.status?.mode ?? "Not connected")
                LabeledContent("Effective leases", value: String(model.status?.snapshot.effectiveCount ?? 0))
                LabeledContent("Helper", value: model.status?.power.helperConnected == true ? "Connected" : "Unconfirmed")
                ForEach(ServiceRegistry.statuses().keys.sorted(), id: \.self) { key in LabeledContent(key, value: ServiceRegistry.statuses()[key] ?? "Unknown") }
                Button("Refresh Diagnostics") { model.refresh(); model.refreshIntegrations() }.disabled(model.preview)
            } header: { Text("Local state") }
            Section {
                Text(WakeLeasePaths.directory.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy Doctor Command") { model.copy("\(LeaseIntegrations.quote(ServiceRegistry.bundledCLI.path)) doctor") }
                Text("No telemetry or automatic update checks. Logs are local and exclude prompts, command contents and lease reasons.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy and diagnostics") }
            Section {
                Text("Based on MIT-licensed engineering from Adrafinil by kageroumado and contributors. Independent project; no upstream endorsement.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Lineage") }
        }.formStyle(.grouped)
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<WakeLeasePreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { value in model.changePreferences { $0[keyPath: keyPath] = value } })
    }

    private func policy<Value>(_ keyPath: WritableKeyPath<LeasePolicy, Value>) -> Binding<Value> {
        Binding(get: { model.preferences.policy[keyPath: keyPath] }, set: { value in model.changePreferences { $0.policy[keyPath: keyPath] = value } })
    }
}
