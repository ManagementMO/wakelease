import Darwin
import Foundation

public protocol LeaseClock: Sendable {
    var bootID: String { get }
    func now() -> LeaseTime
}

public struct SystemLeaseClock: LeaseClock {
    public init() {}

    public var bootID: String { Self.kernelBootID }

    public func now() -> LeaseTime {
        LeaseTime(wall: Date(), continuous: Double(mach_continuous_time()) * Self.secondsPerTick)
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private static let kernelBootID: String = {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 0, count <= 128 else {
            return "unverified-" + UUID().uuidString
        }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else {
            return "unverified-" + UUID().uuidString
        }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}

public enum SystemProcessIdentity {
    public static func read(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              Int32(exactly: info.pbi_pid) == pid, info.pbi_start_tvsec > 0, info.pbi_status != SZOMB else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}
