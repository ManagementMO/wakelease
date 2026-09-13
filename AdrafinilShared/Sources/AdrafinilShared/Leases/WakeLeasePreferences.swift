import Foundation

public struct WakeLeasePreferences: Codable, Sendable, Equatable {
    public let version: Int
    public var policy: LeasePolicy
    public var preSleepCue: Bool
    public var notifySafety: Bool
    public var launchMenuAtLogin: Bool
    public var showMenuBar: Bool

    public init(policy: LeasePolicy = LeasePolicy(), preSleepCue: Bool = false, notifySafety: Bool = false, launchMenuAtLogin: Bool = true, showMenuBar: Bool = true) {
        version = 1
        self.policy = policy
        self.preSleepCue = preSleepCue
        self.notifySafety = notifySafety
        self.launchMenuAtLogin = launchMenuAtLogin
        self.showMenuBar = showMenuBar
    }

    public func normalized() -> WakeLeasePreferences {
        var copy = self
        copy.policy = policy.normalized()
        return copy
    }

    public static func load(from directory: SecureDirectory) throws -> WakeLeasePreferences {
        guard let data = try directory.read(name: WakeLeaseIdentity.configFilename, maximum: 65536) else { return WakeLeasePreferences() }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to directory: SecureDirectory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try directory.write(encoder.encode(normalized()), name: WakeLeaseIdentity.configFilename)
    }

    private enum CodingKeys: String, CodingKey {
        case version, policy, preSleepCue, notifySafety, launchMenuAtLogin, showMenuBar
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported preferences version") }
        self.init(
            policy: try values.decodeIfPresent(LeasePolicy.self, forKey: .policy) ?? LeasePolicy(),
            preSleepCue: try values.decodeIfPresent(Bool.self, forKey: .preSleepCue) ?? false,
            notifySafety: try values.decodeIfPresent(Bool.self, forKey: .notifySafety) ?? false,
            launchMenuAtLogin: try values.decodeIfPresent(Bool.self, forKey: .launchMenuAtLogin) ?? true,
            showMenuBar: try values.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        )
    }
}
