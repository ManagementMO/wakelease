import AdrafinilShared
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard ProcessInfo.processInfo.environment["CI"] == "true",
      ProcessInfo.processInfo.environment["WAKELEASE_INSTALLER_PROBE"] == "approved-disposable-runner",
      arguments.count == 1, ["absent", "installed"].contains(arguments[0]), getuid() != 0 else { exit(78) }
let authorized = ComponentTrust.requirement(role: .helper) != nil
let expected = arguments[0] == "installed"
guard authorized == expected else {
    FileHandle.standardError.write(Data("Installed component identity did not match the expected administrative approval state.\n".utf8))
    exit(1)
}
print(expected ? "Exact installed identity accepted" : "Unapproved identity rejected")
