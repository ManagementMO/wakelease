import Foundation

public typealias AdrafinilConstants = WakeLeaseIdentity

public enum WakeLeaseIdentity {
    public static let name = "WakeLease"
    public static let appBundleID = "org.wakelease"
    public static let daemonBundleID = appBundleID + ".daemon"
    public static let helperBundleID = appBundleID + ".helper"
    public static let cliBundleID = appBundleID + ".cli"

    public static let daemonMachServiceName = daemonBundleID
    public static let helperMachServiceName = helperBundleID
    public static let helperMaintenanceMachServiceName = helperBundleID + ".maintenance"

    public static let appSupportDirectoryName = name
    public static let cliSocketFilename = "cli.sock"
    public static let stateFilename = "state.json"
    public static let configFilename = "config.json"
    public static let eventLogFilename = "events.log"

    /// Version the daemon, helper, and CLI report over their version endpoints. The app bundle reads
    /// its own `CFBundleShortVersionString`; keep this in step with the project's `MARKETING_VERSION`
    /// at release time so every component agrees on a single number.
    public static let marketingVersion = "0.1.0"

    public static let cliBinaryName = "wakelease"
    public static let cliInstallPath = "/usr/local/bin/" + cliBinaryName
    public static let cliFallbackInstallPath = "\(NSHomeDirectory())/.local/bin/" + cliBinaryName

    public static var appSupportURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cliSocketURL: URL {
        appSupportURL.appendingPathComponent(cliSocketFilename)
    }
}
