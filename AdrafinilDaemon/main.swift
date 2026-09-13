import AdrafinilShared
import Foundation
import OSLog

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") {
    print("WakeLeaseDaemon --simulate [--state-dir <private-directory>]")
    exit(0)
}
var directory = WakeLeasePaths.directory
var simulate = false
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--simulate": simulate = true
    case "--state-dir":
        index += 1
        guard index < arguments.count, arguments[index].hasPrefix("/") else { exit(64) }
        directory = URL(fileURLWithPath: arguments[index], isDirectory: true)
    default:
        FileHandle.standardError.write(Data("Unknown daemon argument. Use --help.\n".utf8))
        exit(64)
    }
    index += 1
}
guard simulate else {
    FileHandle.standardError.write(Data("Production power control is not enabled in this development stage. Use --simulate; it does not keep the Mac awake.\n".utf8))
    exit(78)
}
let daemon = LeaseDaemonRuntime(directory: directory)

// SIGTERM (launchctl bootout, logout, system shutdown) must clear the helper's sleep block
// before exit: `disablesleep` is a persistent power-management pref that survives this process —
// and the helper, and even a reboot — so an unload while blocked would otherwise leave the Mac
// unable to sleep with nothing left to fix it. The dispatch source delivers the signal on the
// main queue, where the MainActor daemon can run its bounded cleanup.
let signalSources = [SIGTERM, SIGINT].map { value in
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler {
        Task { @MainActor in
            await daemon.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

Task { @MainActor in
    do {
        try await daemon.start()
        try FileHandle.standardOutput.write(contentsOf: Data("WakeLeaseDaemon ready (simulation)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("WakeLeaseDaemon failed to start: \(error.localizedDescription)\n".utf8))
        await daemon.shutdown()
        exit(1)
    }
}
RunLoop.main.run()
