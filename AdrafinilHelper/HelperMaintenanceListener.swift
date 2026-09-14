import AdrafinilShared
import Foundation

final class HelperMaintenanceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let controller: HelperPowerController

    init(controller: HelperPowerController) {
        self.controller = controller
        super.init()
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ComponentTrust.currentTeam != nil, connection.effectiveUserIdentifier > 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: HelperMaintenanceProtocol.self)
        connection.exportedObject = HelperMaintenanceService(controller: controller, uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private final class HelperMaintenanceService: NSObject, HelperMaintenanceProtocol, @unchecked Sendable {
    private let controller: HelperPowerController
    private let uid: UInt32

    init(controller: HelperPowerController, uid: UInt32) {
        self.controller = controller
        self.uid = uid
        super.init()
    }

    func reserveRemoval(_ identifier: String, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        guard let id = UUID(uuidString: identifier) else { reply(false, HelperRemovalFailure.invalidReservation as NSError); return }
        controller.reserveRemoval(uid: uid, id: id, reply: reply)
    }

    func cancelRemoval(_ identifier: String, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        guard let id = UUID(uuidString: identifier) else { reply(false, HelperRemovalFailure.invalidReservation as NSError); return }
        controller.cancelRemoval(uid: uid, id: id, reply: reply)
    }

    func currentRemoval(reply: @escaping @Sendable (String?, UInt32, NSError?) -> Void) {
        controller.currentRemoval(uid: uid, reply: reply)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperVersion.string)
    }
}
