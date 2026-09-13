import Darwin
import Foundation
import WakeLeaseProcess

public struct BoundedProcessResult: Sendable {
    public let status: Int32
    public let pid: Int32
    public let output: Data
    public var timedOut: Bool {
        status == -ETIMEDOUT
    }
    public var unreaped: Bool {
        status == -EBUSY
    }
}

public enum BoundedProcess {
    public static func run(arguments: [String], timeout: TimeInterval, maximumOutput: Int = 65_536) throws -> BoundedProcessResult {
        guard let executable = arguments.first, executable.hasPrefix("/"), arguments.allSatisfy({ !$0.utf8.contains(0) }),
              timeout.isFinite, timeout > 0, timeout <= 60, maximumOutput > 0, maximumOutput <= 1_024 * 1_024 else { throw LocalIOError.unsafePath }
        var pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw LocalIOError.system(ENOMEM) }
        pointers.append(nil)
        var output = [UInt8](repeating: 0, count: maximumOutput)
        var length = 0
        var pid: Int32 = 0
        let status = pointers.withUnsafeMutableBufferPointer { argv in
            wakelease_capture(argv.baseAddress!, timeout, &output, maximumOutput, &length, &pid)
        }
        return BoundedProcessResult(status: status, pid: pid, output: Data(output.prefix(length)))
    }
}
