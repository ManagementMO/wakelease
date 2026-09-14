import Foundation

@objc
public protocol HelperMaintenanceProtocol {
    func reserveRemoval(_ identifier: String, reply: @escaping @Sendable (Bool, NSError?) -> Void)
    func cancelRemoval(_ identifier: String, reply: @escaping @Sendable (Bool, NSError?) -> Void)
    func currentRemoval(reply: @escaping @Sendable (String?, UInt32, NSError?) -> Void)
    func version(reply: @escaping @Sendable (String) -> Void)
}
