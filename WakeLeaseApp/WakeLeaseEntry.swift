import AdrafinilShared
import AppKit
import Foundation
import SwiftUI

@main
enum WakeLeaseEntry {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            print("WakeLease \(WakeLeaseIdentity.marketingVersion)")
            return
        }
        if arguments.contains("--uninstall") {
            guard Set(arguments).isSubset(of: ["--uninstall", "--yes", "--purge", "--remove-app", "--dry-run"]) else { exit(64) }
            if arguments.contains("--dry-run") {
                print("Would confirm sleep is allowed, remove recorded hooks, unregister WakeLease services, and remove the owned CLI link.")
                print(arguments.contains("--purge") ? "Known local preferences, logs and backups would also be removed; unknown files would be retained." : "Preferences, logs and backups would be retained.")
                return
            }
            guard arguments.contains("--yes") else {
                FileHandle.standardError.write(Data("Review --uninstall --dry-run, then confirm with --yes.\n".utf8))
                exit(64)
            }
            Task { @MainActor in
                do {
                    try await UninstallCoordinator.run(environment: AppUninstallEnvironment(), purge: arguments.contains("--purge"))
                    print("WakeLease services, recorded integrations, and owned CLI link removed. Sleep disabling was confirmed OFF before teardown.")
                    if arguments.contains("--remove-app") {
                        try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
                        print("Application moved to Trash.")
                    } else { print("You may now move WakeLease.app to Trash.") }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data(("Uninstall stopped safely: " + error.localizedDescription + "\n").utf8))
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        WakeLeaseApp.main()
    }
}
