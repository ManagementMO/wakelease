import AdrafinilShared
import Darwin
import Foundation

struct LeaseMCPServer {
    private struct HoldArguments: Decodable {
        let reason: String
        let minutes: Double?
        let pid: Int32?
        let parentLeaseID: UUID?
    }
    private let client: LeaseSocketClient
    private let source: String
    private var initialized = false
    private var negotiated = false
    private let versions: Set<String> = ["2024-11-05", "2025-03-26"]

    init(plan: LeaseCLIPlan) {
        client = LeaseSocketClient(directory: plan.directory)
        source = plan.values["--source"] ?? "mcp"
    }

    mutating func run() -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var line = Data()
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return count == 0 ? 0 : 1 }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    if !line.isEmpty {
                        if !handle(line) { return 1 }
                        line.removeAll(keepingCapacity: true)
                    }
                } else {
                    guard line.count < 65536 else {
                        _ = sendError(id: nil, code: -32600, message: "MCP message exceeds 64 KiB.")
                        return 1
                    }
                    line.append(byte)
                }
            }
        }
    }

    private mutating func handle(_ data: Data) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return sendError(id: nil, code: -32700, message: "Parse error") }
        guard let message = parsed as? [String: Any], message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return sendError(id: nil, code: -32600, message: "Invalid JSON-RPC request")
        }
        let id = message["id"]
        if method == "notifications/initialized", id == nil { initialized = negotiated; return true }
        if id == nil { return true }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            let requested = params["protocolVersion"] as? String ?? ""
            negotiated = true
            initialized = false
            return send(id: id, result: [
                "protocolVersion": versions.contains(requested) ? requested : "2025-03-26",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": WakeLeaseIdentity.name, "version": WakeLeaseIdentity.marketingVersion],
            ])
        }
        if method == "ping" { return send(id: id, result: [:]) }
        guard initialized else { return sendError(id: id, code: -32002, message: "Initialize this stdio server using MCP 2025-03-26 before calling tools.") }
        switch method {
        case "tools/list": return send(id: id, result: ["tools": tools])
        case "tools/call": return call(id: id, params: params)
        default: return sendError(id: id, code: -32601, message: "Method not found")
        }
    }

    private func call(id: Any?, params: [String: Any]) -> Bool {
        guard let name = params["name"] as? String,
              params["arguments"] == nil || params["arguments"] is [String: Any] else {
            return sendError(id: id, code: -32602, message: "A tool name and object arguments are required.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let request: LeaseRequest
            switch name {
            case "keep_system_awake", "keep_display_awake":
                let decoded = try JSONDecoder().decode(HoldArguments.self, from: JSONSerialization.data(withJSONObject: arguments))
                guard !decoded.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LeaseCLIUsageError("A nonempty reason is required.") }
                let minutes = decoded.minutes ?? 60
                guard minutes.isFinite, minutes > 0, minutes <= 1440 else { throw LeaseCLIUsageError("minutes must be positive and no greater than 1440.") }
                var owner: ProcessIdentity?
                if let pid = decoded.pid {
                    guard let identity = SystemProcessIdentity.read(pid) else { throw LeaseFailure.ownerUnavailable }
                    owner = identity
                }
                request = LeaseRequest(operation: "hold", key: "mcp:" + UUID().uuidString.lowercased(), source: source, sourceKind: .mcp, wakeClass: name == "keep_display_awake" ? .display : .system, ttlSeconds: minutes * 60, reason: decoded.reason, owner: owner, parentLeaseID: decoded.parentLeaseID)
            case "release_wake_lease":
                guard let key = arguments["key"] as? String, !key.isEmpty else { throw LeaseCLIUsageError("A lease key is required.") }
                request = LeaseRequest(operation: "release", key: key)
            case "get_wake_status": request = LeaseRequest(operation: "status")
            default: return sendError(id: id, code: -32602, message: "Unknown tool")
            }
            let reply = try client.send(request)
            let text = String(decoding: try LeaseJSON.encode(reply), as: UTF8.self)
            return send(id: id, result: ["content": [["type": "text", "text": text]], "isError": !reply.ok])
        } catch {
            return send(id: id, result: ["content": [["type": "text", "text": "The lease request could not be completed. Check arguments and wakelease doctor. A transport timeout has an unknown outcome; inspect status before retrying."]], "isError": true])
        }
    }

    private var tools: [[String: Any]] {
        let holdProperties: [String: Any] = [
            "reason": ["type": "string", "minLength": 1, "maxLength": 512],
            "minutes": ["type": "number", "exclusiveMinimum": 0, "maximum": 1440],
            "pid": ["type": "integer", "minimum": 1],
            "parentLeaseID": ["type": "string", "format": "uuid"],
        ]
        return [
            ["name": "keep_system_awake", "description": "Acquire a finite system wake lease for work continuing beyond this turn. Supply the background process PID for exit-based release. Inspect the returned power report: simulation does not prevent sleep.", "inputSchema": ["type": "object", "properties": holdProperties, "required": ["reason"], "additionalProperties": false]],
            ["name": "keep_display_awake", "description": "Acquire a finite display and system lease for screen-dependent work. Do not request display protection for headless jobs. Safety cutouts override all leases.", "inputSchema": ["type": "object", "properties": holdProperties, "required": ["reason"], "additionalProperties": false]],
            ["name": "release_wake_lease", "description": "Release only the returned lease key when its work finishes. Other work remains protected.", "inputSchema": ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"], "additionalProperties": false]],
            ["name": "get_wake_status", "description": "Read current leases, effective demand, safety status and reported power protection.", "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false]],
        ]
    }

    private func send(id: Any?, result: [String: Any]) -> Bool {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) -> Bool {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func write(_ value: [String: Any]) -> Bool {
        do {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
            return true
        } catch { return false }
    }
}
