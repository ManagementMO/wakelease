import Foundation

public enum HelperRemovalFailure: String, Error, LocalizedError, Sendable {
    case activeWork
    case reserved
    case invalidReservation
    case unsafeStorage

    public var errorDescription: String? {
        switch self {
        case .activeWork: "Other work still requires the helper. Removal was not reserved."
        case .reserved: "The helper is reserved for removal and cannot accept new wake claims."
        case .invalidReservation: "The removal transaction or authenticated owner does not match."
        case .unsafeStorage: "Removal state could not be verified. Wake admission remains closed pending recovery."
        }
    }
}

public struct HelperRemovalReservation: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let uid: UInt32

    public init(id: UUID, uid: UInt32) {
        version = 1
        self.id = id
        self.uid = uid
    }

    private enum CodingKeys: String, CodingKey { case version, id, uid }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        let uid = try values.decode(UInt32.self, forKey: .uid)
        guard version == 1, uid > 0 else { throw HelperRemovalFailure.invalidReservation }
        try self.init(id: values.decode(UUID.self, forKey: .id), uid: uid)
    }
}
