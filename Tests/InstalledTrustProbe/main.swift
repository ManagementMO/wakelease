import AdrafinilShared
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard ProcessInfo.processInfo.environment["CI"] == "true",
      ProcessInfo.processInfo.environment["WAKELEASE_INSTALLER_PROBE"] == "approved-disposable-runner" else { exit(78) }

do {
    if arguments.count == 2, arguments[0] == "grant-delete", getuid() == 0,
       let uid = UInt32(arguments[1]), uid > 0, let record = try InstalledComponentTrust.load() {
        try record.grantRemoval(to: uid)
        print("Read/delete permission delegated without write access")
    } else if arguments == ["remove"], getuid() != 0, let record = try InstalledComponentTrust.load() {
        try record.remove()
        print("Approved user removed the protected record")
    } else if arguments == ["hold"], getuid() != 0 {
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        Thread.sleep(forTimeInterval: 60)
    } else {
        guard arguments.count == 1, ["absent", "installed"].contains(arguments[0]), getuid() != 0 else { exit(78) }
        let authorized = ComponentTrust.requirement(role: .helper) != nil
        let expected = arguments[0] == "installed"
        guard authorized == expected else {
            FileHandle.standardError.write(Data("Installed component identity did not match the expected administrative approval state.\n".utf8))
            exit(1)
        }
        print(expected ? "Exact installed identity accepted" : "Unapproved identity rejected")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
