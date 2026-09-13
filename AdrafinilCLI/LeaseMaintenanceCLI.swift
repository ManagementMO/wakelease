import AdrafinilShared
import Foundation

enum LeaseMaintenanceCLI {
    static func uninstall(_ plan: LeaseCLIPlan) throws -> Int32 {
        let options: Set = ["--yes", "--dry-run", "--purge", "--remove-app", "--home", "--state-dir"]
        guard plan.positionals.isEmpty, Set(plan.values.keys).union(plan.flags).isSubset(of: options) else {
            throw LeaseCLIUsageError("Use: wakelease uninstall [--dry-run] [--yes] [--purge] [--remove-app]")
        }
        let path = HookCommandSupport.canonicalCLIPath()
        let bundle = LeaseDiagnostics.applicationBundle(containing: URL(fileURLWithPath: path))
        if plan.flags.contains("--dry-run") {
            print("Uninstall order: pause admission → confirm SleepDisabled OFF → remove owned hooks → unregister services → remove owned CLI link.")
            let manager = LeaseIntegrationManager(home: URL(fileURLWithPath: plan.values["--home"] ?? NSHomeDirectory()), stateDirectory: plan.directory, cliPath: path)
            for integration in LeaseIntegrations.all {
                do {
                    let report = try manager.uninstall(integration.id, dryRun: true)
                    if report.changed { print(report.diff) }
                } catch { print("Review required for \(integration.id): \(error.localizedDescription)") }
            }
            print(bundle.map { "Service context: " + $0.path } ?? "No app-bundle context. Production service teardown requires the packaged app.")
            print(plan.flags.contains("--purge") ? "Known local preferences, logs and backups would be removed." : "Local preferences, logs and backups would be retained.")
            return 0
        }
        guard plan.values["--home"] == nil, plan.directory.standardizedFileURL == WakeLeasePaths.standardDirectory.standardizedFileURL else {
            throw LeaseCLIUsageError("Production uninstall uses the standard user state directory. Use integration uninstall for isolated profiles.")
        }
        guard let bundle, let executable = Bundle(url: bundle)?.executableURL else {
            throw LeaseCLIUsageError("Use the CLI inside the installed WakeLease.app to unregister its services. A source checkout can remove its hooks with integrations uninstall.")
        }
        if !plan.flags.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw LeaseCLIUsageError("Review --dry-run, then confirm with --yes.") }
            print("Uninstall WakeLease and allow this Mac to sleep? [y/N] ", terminator: "")
            guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { return 1 }
        }
        var arguments = [executable.path, "--uninstall", "--yes"]
        if plan.flags.contains("--purge") { arguments.append("--purge") }
        if plan.flags.contains("--remove-app") { arguments.append("--remove-app") }
        return CommandProcess.run(arguments: arguments) { _, _ in }
    }
}
