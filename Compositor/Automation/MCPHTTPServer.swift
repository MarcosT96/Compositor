import Foundation
import CoreFoundation
@preconcurrency import Network

/// Streamable-HTTP transport for `MCPRouter`: a loopback-only HTTP/1.1 endpoint that standard MCP
/// clients (Claude Code, Codex, Cursor) reach directly at `http://127.0.0.1:<port>/mcp/<token>`.
/// No external runtime bridges the protocol; the router keeps reading and editing the same sessions
/// as the person using the app.
///
/// Countermeasures against a web page probing loopback (DNS rebinding): the listener binds IPv4
/// loopback only, `Origin` and `Host` are validated on every request, and the URL path carries an
/// access token kept in an owner-only file. Bodies are bounded and parsed strictly, so malformed
/// input never reaches the router. Each request is answered on its own connection and closed, which
/// keeps framing simple and lets `notifications/cancelled` arrive while a tool call is still running.
@MainActor
final class MCPHTTPServer {
    typealias Handler = @MainActor ([String: Any]) async -> [String: Any]?

    struct HTTPRequest: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    enum ParseResult: Equatable {
        case incomplete
        case request(HTTPRequest, consumed: Int)
        case malformed
        case tooLarge
    }

    nonisolated static let defaultMaximumBytes = 40 * 1024 * 1024
    /// Head start line plus headers stay small even for generous clients.
    private static let maximumHeadBytes = 64 * 1024
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let maximumConnections = 8
    private static let maximumSessions = 32
    static let sessionLifetime: TimeInterval = 3_600

    private let handle: Handler
    private let token: String
    private let maximumBytes: Int
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var requestTasks: [String: Task<[String: Any]?, Never>] = [:]
    private var sessions: [String: Date] = [:]
    private var generation = UUID()
    private(set) var port: UInt16 = 0

    init(token: String, maximumBytes: Int = MCPHTTPServer.defaultMaximumBytes, handler: @escaping Handler) {
        self.token = token
        self.maximumBytes = maximumBytes
        self.handle = handler
    }

    // MARK: - Lifecycle

    /// Binds `preferredPort`, or an ephemeral port when that one is taken (or zero is passed).
    func start(preferredPort: UInt16) async throws {
        guard listener == nil else { return }
        if let port = try? await listen(on: preferredPort) {
            self.port = port
            return
        }
        guard preferredPort != 0, let fallback = try? await listen(on: 0) else {
            throw RPCError.internalError("Could not bind a local port for the MCP endpoint.")
        }
        port = fallback
    }

    func stop() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        port = 0
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        sessions.removeAll()
    }

    private func listen(on preferred: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to IPv4 loopback only so the endpoint is never reachable from the LAN.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
            port: preferred == 0 ? .any : NWEndpoint.Port(rawValue: preferred) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let epoch = UUID()
        generation = epoch
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection, epoch: epoch) }
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let ready = ReadySignal(continuation)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor [weak self, weak listener] in
                        guard let self, self.generation == epoch else { return }
                        switch state {
                        case .ready: ready.succeed(listener?.port?.rawValue ?? 0)
                        case .failed(let error):
                            ready.fail(error)
                            self.tearDown(listener)
                        case .cancelled: ready.fail(CancellationError())
                        default: break
                        }
                    }
                }
                listener.start(queue: .main)
            }
        } catch {
            tearDown(listener)
            throw error
        }
    }

    /// A failed bind must release only its own listener; `stop()` may already own a new one.
    private func tearDown(_ listener: NWListener?) {
        listener?.cancel()
        if let listener, self.listener === listener { self.listener = nil }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection, epoch: UUID) {
        guard generation == epoch, connections.count < Self.maximumConnections else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        buffers[id] = Data()
        connection.start(queue: .main)
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, let connection = self.connections[id] else { return }
                if let chunk { self.buffers[id, default: Data()].append(chunk) }
                let buffer = self.buffers[id] ?? Data()
                switch Self.parse(buffer, maximumBytes: self.maximumBytes) {
                case .incomplete:
                    if complete || error != nil { self.finish(id) }
                    else { self.receive(connection, id: id) }
                case .malformed:
                    self.finish(id, sending: Self.respond(400, body: Self.jsonRPCError(id: NSNull(), code: -32700, message: "Parse error")))
                case .tooLarge:
                    self.finish(id, sending: Self.respond(413, body: Self.jsonRPCError(id: NSNull(), code: -32600, message: "Request body exceeds \(self.maximumBytes) bytes")))
                case .request(let request, _):
                    Task { @MainActor in
                        self.finish(id, sending: await self.response(for: request))
                    }
                }
            }
        }
    }

    private func finish(_ id: UUID, sending data: Data? = nil) {
        buffers.removeValue(forKey: id)
        guard let connection = connections.removeValue(forKey: id) else { return }
        if let data {
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.cancel()
        }
    }

    // MARK: - Request handling

    private func response(for request: HTTPRequest) async -> Data {
        // Authorization runs before any body interpretation, exactly like the old bridge did.
        let path = "/mcp/\(token)"
        if request.path != path { return Self.respond(404) }
        if let failure = Self.authorizationFailure(for: request, port: port) { return Self.respond(failure) }
        pruneSessions()
        switch request.method {
        case "POST": return await post(request)
        case "DELETE":
            if let session = request.headers["mcp-session-id"] { sessions.removeValue(forKey: session) }
            return Self.respond(204)
        // Streamable HTTP lets a server refuse server-initiated streams with 405.
        default: return Self.respond(405, headers: ["Allow": "POST, DELETE"])
        }
    }

    private func post(_ request: HTTPRequest) async -> Data {
        if let session = request.headers["mcp-session-id"], sessions[session] == nil { return Self.respond(404) }
        guard let object = try? JSONSerialization.jsonObject(with: request.body),
              !(object is [String: Any] && (object as? [String: Any])?.isEmpty == true),
              !(object is [Any] && (object as? [Any])?.isEmpty == true) else {
            return Self.respond(400, body: Self.jsonRPCError(id: NSNull(), code: -32700, message: "Parse error"))
        }
        // An initialize creates the session whose id rides on the HTTP response headers.
        var sessionHeader: [String: String] = [:]
        let items = object is [Any] ? (object as? [Any])! : [object]
        if items.contains(where: { ($0 as? [String: Any])?["method"] as? String == "initialize" }) {
            let session = UUID().uuidString
            sessions[session] = Date()
            sessionHeader = ["Mcp-Session-Id": session]
        }
        var responses: [[String: Any]] = []
        for item in items {
            if let response = await dispatch(item) { responses.append(response) }
        }
        if responses.isEmpty { return Self.respond(202, headers: sessionHeader) }
        return Self.respond(200, headers: sessionHeader, body: Self.jsonBody(responses.count == 1 ? responses[0] : responses))
    }

    private func dispatch(_ item: Any) async -> [String: Any]? {
        guard let request = item as? [String: Any] else {
            return ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid JSON-RPC request"]]
        }
        // Cancellation arrives as its own notification while the target call is in flight.
        if request["method"] as? String == "notifications/cancelled" {
            let params = request["params"] as? [String: Any]
            if let target = params?["requestId"] { requestTasks[Self.idKey(target)]?.cancel() }
            return nil
        }
        guard request["id"] != nil else { return await handle(request) }
        let key = Self.idKey(request["id"]!)
        let task = Task<[String: Any]?, Never> { await self.handle(request) }
        requestTasks[key] = task
        let response = await task.value
        requestTasks.removeValue(forKey: key)
        return response ?? ["jsonrpc": "2.0", "id": request["id"]!, "error": ["code": -32800, "message": "Request cancelled"]]
    }

    private func pruneSessions() {
        sessions = sessions.filter { Date().timeIntervalSince($0.value) < Self.sessionLifetime }
        while sessions.count > Self.maximumSessions, let oldest = sessions.min(by: { $0.value < $1.value }) {
            sessions.removeValue(forKey: oldest.key)
        }
    }

    /// DNS-rebinding protection: only the loopback names a legitimate client can type are accepted.
    static func authorizationFailure(for request: HTTPRequest, port: UInt16) -> Int? {
        let hosts = ["127.0.0.1", "localhost"]
        let host = request.headers["host"] ?? ""
        guard hosts.contains(where: { host == $0 || host == "\($0):\(port)" }) else { return 403 }
        if let origin = request.headers["origin"] {
            let allowed = hosts.map { "http://\($0):\(port)" }
            guard allowed.contains(origin.lowercased()) else { return 403 }
        }
        return nil
    }

    // MARK: - HTTP parsing

    static func parse(_ buffer: Data, maximumBytes: Int = defaultMaximumBytes) -> ParseResult {
        guard let headEnd = buffer.range(of: headerTerminator) else {
            return buffer.count > maximumHeadBytes ? .malformed : .incomplete
        }
        guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return .malformed }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.components(separatedBy: " ") ?? []
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        // Chunked uploads never occur on this endpoint; a bounded Content-Length keeps framing
        // trivial, and bodiless verbs (GET, DELETE) simply omit the header.
        guard headers["transfer-encoding"] == nil else { return .malformed }
        let count = headers["content-length"].flatMap(Int.init) ?? 0
        guard count >= 0 else { return .malformed }
        guard count <= maximumBytes else { return .tooLarge }
        let bodyStart = headEnd.upperBound
        let total = bodyStart + count
        guard buffer.count >= total else { return .incomplete }
        return .request(HTTPRequest(method: start[0], path: start[1], headers: headers, body: Data(buffer[bodyStart..<total])), consumed: total)
    }

    // MARK: - Responses

    private static func respond(_ status: Int, headers: [String: String] = [:], body: Data? = nil) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 500: "Internal Server Error"]
        var fields = headers
        fields["Content-Length"] = "\(body?.count ?? 0)"
        fields["Connection"] = "close"
        if body != nil, fields["Content-Type"] == nil { fields["Content-Type"] = "application/json" }
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }

    private static func jsonBody(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func jsonRPCError(id: Any, code: Int, message: String) -> Data {
        jsonBody(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// JSON ids are matched with their canonical form so cancellation finds the running call
    /// regardless of the number or string type a client round-trips.
    private static func idKey(_ id: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [id], options: [.sortedKeys]), data.count > 2 {
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        }
        return "\(id)"
    }
}

/// Resumes a checked continuation exactly once from network state callbacks.
private final class ReadySignal: @unchecked Sendable {
    private let continuation: CheckedContinuation<UInt16, Error>
    private var resumed = false
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func succeed(_ port: UInt16) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: port)
    }
    func fail(_ error: Error) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}
