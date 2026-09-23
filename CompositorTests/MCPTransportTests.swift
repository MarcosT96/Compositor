import Testing
import Foundation
import CoreGraphics
@testable import Compositor

/// Exercises the streamable-HTTP transport over real sockets: handshake, tool calls against the
/// shared workspace, and every rejection path. Mutations are verified by reading editor state back,
/// never by trusting the tool response alone.
@MainActor
struct MCPTransportTests {
    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data

        func json() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    @discardableResult
    private func send(_ method: String, to url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body, method != "GET" { request.httpBody = body }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var fields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            fields[(name as? String ?? "\(name)").lowercased()] = value as? String
        }
        return Reply(status: http.statusCode, headers: fields, body: data)
    }

    @discardableResult
    private func send(_ object: Any, to url: URL, headers: [String: String] = [:]) async throws -> Reply {
        try await send("POST", to: url, body: try JSONSerialization.data(withJSONObject: object),
            headers: headers.merging(["Content-Type": "application/json"]) { $1 })
    }

    private func running(maximumBytes: Int = MCPHTTPServer.defaultMaximumBytes,
                         workspace: ProjectWorkspace? = nil) async throws -> (AutomationService, URL) {
        let service = AutomationService(workspace: workspace ?? ProjectWorkspace(), preferredPort: 0, maximumBytes: maximumBytes)
        await service.start()
        let url = try #require(service.clientURL)
        return (service, url)
    }

    private func initialize(_ url: URL) async throws -> Reply {
        try await send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: String](), "clientInfo": ["name": "test", "version": "1"]
        ]], to: url)
    }

    // MARK: - Handshake and discovery

    @Test func initializeHandshakeCarriesSessionHeader() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        let reply = try await initialize(url)
        #expect(reply.status == 200)
        #expect(reply.headers["mcp-session-id"] != nil)
        let json = try reply.json()
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "compositor")
        let notified = try await send(["jsonrpc": "2.0", "method": "notifications/initialized"], to: url)
        #expect(notified.status == 202)
    }

    @Test func toolsListExposesNativeToolCatalog() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        let reply = try await send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], to: url)
        let json = try reply.json()
        let tools = try #require((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.count == 30)
        for expected in ["layer_operation", "paint_stroke", "render_document", "import_html", "history_operation", "read_skill", "manage_skills"] {
            #expect(names.contains(expected))
        }
    }

    // MARK: - Editing through the boundary

    @Test func toolCallMutatesSharedWorkspace() async throws {
        let workspace = ProjectWorkspace()
        let (service, url) = try await running(workspace: workspace)
        defer { service.stop() }
        let reply = try await send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": [
            "name": "new_document", "arguments": ["width": 320, "height": 200, "new_tab": false]
        ]], to: url)
        let json = try reply.json()
        #expect((json["result"] as? [String: Any])?["isError"] as? Bool != true)
        // Read back through the real editor state, not the tool response.
        #expect(workspace.current.session.document?.size == CGSize(width: 320, height: 200))
        let state = try await send(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [
            "name": "describe_document", "arguments": [String: String]()
        ]], to: url)
        let described = try #require((try state.json()["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        #expect((described["canvas"] as? [String: Any])?["width"] as? Int == 320)
    }

    @Test func invalidToolCallsFailClosed() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        let unknown = try await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "no_such_tool", "arguments": [String: String]()
        ]], to: url)
        let error = try #require(try unknown.json()["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        let extra = try await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [
            "name": "import_html", "arguments": ["html": "x", "width": 100, "height": 100, "extra": 1]
        ]], to: url)
        #expect((try extra.json()["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func batchRequestsReturnOneResponsePerCall() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        let reply = try await send([
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"]
        ], to: url)
        #expect(reply.status == 200)
        let batch = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [[String: Any]])
        #expect(batch.count == 2)
    }

    // MARK: - Rejections

    @Test func wrongTokenAndUnknownSessionAreNotFound() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = "/mcp/not-the-token"
        let wrong = try await send(["jsonrpc": "2.0", "id": 1, "method": "ping"], to: components.url!)
        #expect(wrong.status == 404)
        let expired = try await send(["jsonrpc": "2.0", "id": 2, "method": "ping"], to: url,
            headers: ["Mcp-Session-Id": "expired-session"])
        #expect(expired.status == 404)
    }

    @Test func foreignOriginsAndHostsAreForbidden() {
        let request = MCPHTTPServer.HTTPRequest(method: "POST", path: "/mcp/t", headers: ["host": "127.0.0.1:27892"], body: Data())
        #expect(MCPHTTPServer.authorizationFailure(for: request, port: 27_892) == nil)
        #expect(MCPHTTPServer.authorizationFailure(for: MCPHTTPServer.HTTPRequest(method: "POST", path: "/mcp/t",
            headers: ["host": "attacker.example"], body: Data()), port: 27_892) == 403)
        #expect(MCPHTTPServer.authorizationFailure(for: MCPHTTPServer.HTTPRequest(method: "POST", path: "/mcp/t",
            headers: ["host": "127.0.0.1:27892", "origin": "http://attacker.example"], body: Data()), port: 27_892) == 403)
        #expect(MCPHTTPServer.authorizationFailure(for: MCPHTTPServer.HTTPRequest(method: "POST", path: "/mcp/t",
            headers: ["host": "localhost:27892", "origin": "http://localhost:27892"], body: Data()), port: 27_892) == nil)
    }

    @Test func parserFramesPartialAndBoundedInput() {
        let request = Data("POST /mcp/t HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}extra".utf8)
        #expect(MCPHTTPServer.parse(Data(request.prefix(10))) == .incomplete)
        guard case .request(let parsed, let consumed) = MCPHTTPServer.parse(request) else {
            Issue.record("Expected a complete request")
            return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.body == Data("{}".utf8))
        #expect(consumed == request.count - 5)
        #expect(MCPHTTPServer.parse(Data("GET / HTTP/9.9\r\n\r\n".utf8)) == .malformed)
        let big = Data("POST /mcp/t HTTP/1.1\r\nContent-Length: 5000\r\n\r\n".utf8)
        #expect(MCPHTTPServer.parse(big, maximumBytes: 1_024) == .tooLarge)
    }

    @Test func methodsAndPayloadsAreBounded() async throws {
        let (service, url) = try await running(maximumBytes: 1_024)
        defer { service.stop() }
        let get = try await send("GET", to: url)
        #expect(get.status == 405)
        #expect(get.headers["allow"] == "POST, DELETE")
        let garbage = try await send("POST", to: url, body: Data("{".utf8), headers: ["Content-Type": "application/json"])
        #expect(garbage.status == 400)
        #expect((try garbage.json()["error"] as? [String: Any])?["code"] as? Int == -32700)
        let oversized = try await send("POST", to: url, body: Data(repeating: 0x20, count: 4_096))
        #expect(oversized.status == 413)
    }

    @Test func cancellationAndSessionTeardownAreAccepted() async throws {
        let (service, url) = try await running()
        defer { service.stop() }
        let handshake = try await initialize(url)
        let session = try #require(handshake.headers["mcp-session-id"])
        let cancelled = try await send(["jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": 41, "reason": "test"]], to: url, headers: ["Mcp-Session-Id": session])
        #expect(cancelled.status == 202)
        let closed = try await send("DELETE", to: url, headers: ["Mcp-Session-Id": session])
        #expect(closed.status == 204)
    }
}
