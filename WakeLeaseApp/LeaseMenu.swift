import AdrafinilShared
import AppKit
import Foundation
import SwiftUI

struct LeaseMenu: View {
    @Bindable var model: MenuModel
    @State private var confirmPause = false
    @State private var releasing: WakeLease?

    private var accent: Color {
        switch model.presentation.kind {
        case .active: .accentColor
        case .unconfirmed, .cutOut: .orange
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(WakeLeaseIdentity.name).font(.headline)
                Spacer()
                Text("WORK-AWARE SLEEP").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
            if model.preview {
                Text("PREVIEW DATA · NO POWER CHANGES")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.presentation.symbol)
                    .font(.system(size: 25, weight: .regular)).foregroundStyle(accent)
                    .frame(width: 32, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.presentation.title).font(.title3.weight(.semibold))
                    Text(model.presentation.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)
            Divider()
            if model.leases.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.status == nil ? "The daemon is not reachable." : "No wake-requiring work.")
                        .font(.subheadline)
                    Button(model.status == nil ? "Set Up WakeLease…" : "Configure Integrations…") {
                        model.settingsTab = model.status == nil ? "general" : "integrations"
                        LeaseAppDelegate.shared?.showSettings()
                    }
                    .disabled(model.preview)
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.leases) { lease in
                            LeaseRow(lease: lease, release: { releasing = lease })
                                .disabled(model.busy || model.preview)
                            if lease.id != model.leases.last?.id { Divider().padding(.vertical, 12) }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .frame(height: min(285, CGFloat(model.leases.count) * 80 + 16))
            }
            Divider()
            if let conditions = model.status?.snapshot.safety {
                HStack(alignment: .top, spacing: 24) {
                    indicator("Lid", conditions.lidClosed.map { $0 ? "Closed" : "Open" } ?? "Unknown")
                    indicator("Power", conditions.onBattery.map { $0 ? "Battery" : "AC" } ?? "Unknown")
                    indicator("Thermal", conditions.thermalState.rawValue.capitalized)
                }
                .padding(.vertical, 14)
            }
            if let problem = model.problem {
                Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            if model.status != nil {
                Button {
                    if model.status?.snapshot.paused == true { model.perform("resume") }
                    else { confirmPause = true }
                } label: {
                    Text(model.status?.snapshot.paused == true ? "Resume WakeLease" : "Allow Sleep Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || model.preview)
                .padding(.bottom, 14)
            }
            HStack {
                Button("Settings…") { LeaseAppDelegate.shared?.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .labelStyle(.iconOnly).help("Refresh lease and helper status")
                    .accessibilityLabel("Refresh status")
                Button("Quit Menu Bar") { NSApplication.shared.terminate(nil) }
                    .help("The daemon continues protecting active work.")
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(20)
        .frame(width: 382)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .alert("Allow this Mac to sleep?", isPresented: $confirmPause) {
            Button("Cancel", role: .cancel) {}
            Button("Pause and Allow Sleep", role: .destructive) { model.perform("pause") }
        } message: {
            Text("Active jobs may be interrupted. All leases will be released and new leases blocked until you resume WakeLease.")
        }
        .alert("Release this lease?", isPresented: Binding(get: { releasing != nil }, set: { if !$0 { releasing = nil } })) {
            Button("Cancel", role: .cancel) { releasing = nil }
            Button("Release Lease", role: .destructive) {
                if let lease = releasing { model.perform("release", key: lease.key) }
                releasing = nil
            }
        } message: { Text("Other leases are preserved. Releasing the final lease allows normal sleep.") }
    }

    private func indicator(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

private struct LeaseRow: View {
    let lease: WakeLease
    let release: () -> Void
    private var name: String { LeaseIntegrations.all.first(where: { $0.id == lease.source })?.displayName ?? lease.source }
    private var age: String {
        let minutes = max(0, Int(Date().timeIntervalSince(lease.acquiredAt) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: lease.wakeClass == .display ? "display" : "terminal")
                .frame(width: 22).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(age).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(lease.reason ?? lease.key).font(.caption).lineLimit(2)
                HStack(spacing: 5) {
                    Text(lease.state == .waitingForUser ? "Waiting for you" : "Working")
                    if lease.state == .waitingForUser, let expiry = lease.waitingExpiresAt, expiry > Date() {
                        Text("·")
                        Text(min(expiry, lease.expiresAt), style: .timer).monospacedDigit()
                    }
                    if lease.parentLeaseID != nil || lease.metadata["scope"] == "subagent" { Text("· independent child") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Button("Release", systemImage: "xmark.circle", action: release)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Release only this lease")
                .accessibilityLabel("Release \(name) lease")
        }
        .accessibilityElement(children: .contain)
    }
}
