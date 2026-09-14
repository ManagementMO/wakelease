import AdrafinilShared
import Foundation
import OSLog

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] || arguments == ["version"] {
    print("WakeLeaseHelper \(WakeLeaseIdentity.marketingVersion)")
    exit(0)
}
if arguments == ["--help"] {
    print("WakeLeaseHelper is managed by SMAppService. It requires root and installer-approved component pins or an Apple-issued team signature. Use WakeLeaseDaemon --simulate for uninstalled development.")
    exit(0)
}
guard arguments.isEmpty, getuid() == 0, let requirement = ComponentTrust.requirement(role: .daemon), let maintenanceRequirement = ComponentTrust.requirement(role: .app) else {
    FileHandle.standardError.write(Data("WakeLeaseHelper refuses unsigned or unprivileged execution. No power settings were changed.\n".utf8))
    exit(78)
}
let bootLog = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Boot")
bootLog.notice("helper \(HelperVersion.string, privacy: .public) starting — uid=\(getuid(), privacy: .public), listening on \(AdrafinilConstants.helperMachServiceName, privacy: .public)")

let listener = NSXPCListener(machServiceName: AdrafinilConstants.helperMachServiceName)
listener.setConnectionCodeSigningRequirement(requirement)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()
let maintenanceListener = NSXPCListener(machServiceName: WakeLeaseIdentity.helperMaintenanceMachServiceName)
let maintenanceDelegate = HelperMaintenanceListener(controller: delegate.controller)
maintenanceListener.setConnectionCodeSigningRequirement(maintenanceRequirement)
maintenanceListener.delegate = maintenanceDelegate
maintenanceListener.resume()

// SIGTERM is how launchd ends this process at machine shutdown (and on unregister). The kernel
// reclaims the idle IOPMAssertion with the process, but `disablesleep` is a persistent
// power-management pref that survives the helper AND the reboot — clear it on the way out so a
// Mac shut down mid-block can sleep at the next login window.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    bootLog.notice("SIGTERM — clearing sleep block before exit")
    delegate.controller.shutdown { success in exit(success ? 0 : 70) }
}
termSource.resume()

RunLoop.main.run()
