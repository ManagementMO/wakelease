import Foundation

public struct EarliestDeadline: Sendable {
    public private(set) var value: TimeInterval?
    public init() {}

    @discardableResult
    public mutating func arm(_ candidate: TimeInterval?) -> Bool {
        let next = candidate.map { min(value ?? $0, $0) }
        guard next != value else { return false }
        value = next
        return true
    }

    public mutating func fired() { value = nil }
}
