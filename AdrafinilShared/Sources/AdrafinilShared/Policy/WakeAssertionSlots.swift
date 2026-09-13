public struct WakeAssertionSlots: Sendable {
    public var display: UInt32
    public var userActivity: UInt32

    public init(display: UInt32 = 0, userActivity: UInt32 = 0) {
        self.display = display
        self.userActivity = userActivity
    }

    public mutating func releaseAll(_ release: (UInt32) -> Bool) -> Bool {
        var cleared = true
        if display != 0 {
            if release(display) { display = 0 }
            else { cleared = false }
        }
        if userActivity != 0 {
            if release(userActivity) { userActivity = 0 }
            else { cleared = false }
        }
        return cleared
    }
}
