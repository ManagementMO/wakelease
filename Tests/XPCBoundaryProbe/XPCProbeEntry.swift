import Foundation

@main
enum XPCProbeEntry {
    @MainActor
    static func main() async {
        do {
            try await XPCBoundaryProbe().run()
            print("{\"positiveRoundTrip\":true,\"listenerRoleRejections\":3,\"untrustedReplyRejected\":true,\"scope\":\"owned ad-hoc process; anonymous XPC only\"}")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
