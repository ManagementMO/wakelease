import Foundation

public struct LeasePresentation: Sendable, Equatable {
    public enum Kind: Sendable { case unavailable, simulation, normal, active, waiting, paused, cutOut, unconfirmed, otherUser }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let symbol: String

    public init(status: LeaseServiceStatus?) {
        guard let status else {
            kind = .unavailable; title = "Not connected"; detail = "Enable the local services to begin."; symbol = "bolt.slash"
            return
        }
        let state = status.snapshot
        if status.mode == "simulation" {
            kind = .simulation; title = "Simulation"; detail = "\(state.effectiveCount) effective leases · no power changes"; symbol = "testtube.2"
        } else if status.power.error != nil || !status.power.helperConnected || status.power.applied == nil {
            kind = .unconfirmed; title = "Protection unconfirmed"; detail = "Check the helper before relying on closed-lid work."; symbol = "exclamationmark.shield"
        } else if status.power.applied?.system != state.demand.system {
            kind = .unconfirmed; title = "Updating wake protection"; detail = "Waiting for the system to confirm the change."; symbol = "clock"
        } else if !state.cutouts.isEmpty {
            kind = .cutOut; title = "Safety cutoff"; detail = state.cutouts.contains(.thermal) ? "Thermal protection released the wake leases." : "Battery protection released the wake leases."; symbol = "shield.lefthalf.filled"
        } else if state.paused {
            kind = .paused; title = "Paused"; detail = "New leases are blocked until you resume."; symbol = "pause.circle"
        } else if !state.demand.system, status.power.globalBlocked == true {
            kind = .otherUser; title = "Other work active"; detail = "No wake demand for this user. Another user still has a helper claim."; symbol = "person.2"
        } else if !state.leases.isEmpty, state.leases.allSatisfy({ $0.state == .waitingForUser }) {
            kind = .waiting; title = "Waiting for you"; detail = state.effectiveCount > 0 ? "Wake protection remains during the grace period." : "Grace has ended. Normal sleep is allowed."; symbol = "hourglass"
        } else if state.effectiveCount > 0, status.power.applied?.system == true {
            kind = .active; title = "Awake — \(state.effectiveCount) lease\(state.effectiveCount == 1 ? "" : "s")"; detail = "Your Mac works while the work works."; symbol = "circle.inset.filled"
        } else if state.effectiveCount > 0 || status.power.applied?.system == true {
            kind = .unconfirmed; title = "Updating wake protection"; detail = "Waiting for the system to confirm the change."; symbol = "clock"
        } else if state.leases.contains(where: { $0.state == .waitingForUser }) {
            kind = .waiting; title = "Waiting for you"; detail = "Grace has ended. Normal sleep is allowed."; symbol = "hourglass"
        } else {
            kind = .normal; title = "Normal sleep"; detail = "No active work. WakeLease is out of the way."; symbol = "moon"
        }
    }
}
