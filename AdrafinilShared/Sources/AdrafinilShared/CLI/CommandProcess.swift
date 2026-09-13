import Darwin
import Foundation
import WakeLeaseProcess

public enum CommandProcess {
    public enum Event: Int32 { case started = 1, heartbeat = 2, stopped = 3, continued = 4 }

    private final class Callbacks {
        let notify: (Event, Int32) -> Void
        init(_ notify: @escaping (Event, Int32) -> Void) { self.notify = notify }
    }

    private final class Watcher {
        let check: (Int32) -> Bool
        init(_ check: @escaping (Int32) -> Bool) { self.check = check }
    }

    public static func watch(pid: Int32, whileActive: @escaping (Int32) -> Bool) -> Int32 {
        let box = Unmanaged.passRetained(Watcher(whileActive))
        defer { box.release() }
        return wakelease_watch(pid, box.toOpaque()) { pid, context in
            guard let context else { return 0 }
            return Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().check(pid) ? 1 : 0
        }
    }

    public static func run(arguments: [String], onEvent: @escaping (Event, Int32) -> Void) -> Int32 {
        guard !arguments.isEmpty, arguments.allSatisfy({ !$0.utf8.contains(0) }) else { return 125 }
        let box = Unmanaged.passRetained(Callbacks(onEvent))
        defer { box.release() }
        var pointers = arguments.map { strdup($0) }
        defer { for pointer in pointers { free(pointer) } }
        guard pointers.allSatisfy({ $0 != nil }) else { return 125 }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { arguments in
            wakelease_run(arguments.baseAddress!, box.toOpaque()) { event, pid, context in
                guard let context, let event = Event(rawValue: event) else { return }
                Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue().notify(event, pid)
            }
        }
    }
}
