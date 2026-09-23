import AppKit
import Observation

/// Lifecycle, configuration and client setup for the opt-in MCP endpoint. The HTTP transport is
/// started and stopped from the app menu; **Copy MCP Configuration** puts the endpoint URL (which
/// carries the access token) on the pasteboard for the client's MCP settings.
///
/// The token lives in an owner-only rendezvous file so a client can be configured once and keep
/// working across relaunches. Explicitly turning the connection off removes the file and rotates
/// the token, revoking every configured client at once.
@MainActor @Observable
final class AutomationService {
    private(set) var isEnabled = false
    private(set) var status = "Disabled"
    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private let router: MCPRouter
    @ObservationIgnored private let preferredPort: UInt16
    @ObservationIgnored private let maximumBytes: Int
    @ObservationIgnored private(set) var clientURL: URL?
    @ObservationIgnored private var token = ""

    /// Well-known default so the copied client configuration stays valid across launches. The
    /// server falls back to an ephemeral port when another process owns this one.
    static let defaultPort: UInt16 = 27_892

    static var endpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compositor/automation.json")
    }

    /// Passing `preferredPort: 0` binds an ephemeral port; tests use that to avoid conflicts.
    init(workspace: ProjectWorkspace, preferredPort: UInt16? = nil,
         maximumBytes: Int = MCPHTTPServer.defaultMaximumBytes) {
        router = MCPRouter(workspace: workspace)
        if let preferredPort {
            self.preferredPort = preferredPort
        } else {
            let stored = UInt16(clamping: UserDefaults.standard.integer(forKey: "CompositorAutomationPort"))
            self.preferredPort = stored == 0 ? Self.defaultPort : stored
        }
        self.maximumBytes = maximumBytes
    }

    func restore() {
        guard !Self.isTestHost else { return }
        if UserDefaults.standard.bool(forKey: "CompositorAutomationEnabled") || ProcessInfo.processInfo.arguments.contains("--enable-automation") {
            Task { await start() }
        }
    }

    func start() async {
        guard server == nil else { return }
        if token.isEmpty { token = loadOrCreateToken() }
        let server = MCPHTTPServer(token: token, maximumBytes: maximumBytes) { [router] request in
            await router.handle(request)
        }
        self.server = server
        status = "Starting…"
        do {
            try await server.start(preferredPort: preferredPort)
            let url = URL(string: "http://127.0.0.1:\(server.port)/mcp/\(token)")!
            clientURL = url
            isEnabled = true
            setEnabled(true)
            if !Self.isTestHost { try writeEndpoint(url: url, port: server.port) }
            status = "Listening · port \(server.port)"
        } catch {
            stop(revoke: false)
            status = "Connection error: \(error.localizedDescription)"
        }
    }

    /// `revoke: true` (the menu toggle) rotates the token so no previously configured client can
    /// reconnect. Lifecycle shutdowns keep it, which is what makes client configuration durable.
    func stop(revoke: Bool = false) {
        server?.stop()
        server = nil
        clientURL = nil
        isEnabled = false
        status = "Disabled"
        setEnabled(false)
        if revoke {
            token = ""
            if !Self.isTestHost { try? FileManager.default.removeItem(at: Self.endpointURL) }
        }
    }

    func shutdown() {
        let restoreOnLaunch = isEnabled
        server?.stop()
        server = nil
        clientURL = nil
        isEnabled = false
        setEnabled(restoreOnLaunch)
    }

    func copyConfiguration() {
        guard let url = clientURL else { return }
        let config: [String: Any] = ["mcpServers": ["compositor": ["url": url.absoluteString]]]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !Self.isTestHost else { return }
        UserDefaults.standard.set(enabled, forKey: "CompositorAutomationEnabled")
    }

    private func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: Self.endpointURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = object["token"] as? String, stored.utf8.count >= 32 {
            return stored
        }
        return UUID().uuidString + UUID().uuidString
    }

    private func writeEndpoint(url: URL, port: UInt16) throws {
        let file = Self.endpointURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString, "port": Int(port), "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier, "protocol": 2
        ])
        // Restrictive permissions apply before credentials are written.
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".endpoint-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: temporary)
        if rename(temporary.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Unit tests run inside the app; persistence would clobber the user's real endpoint file.
    private static var isTestHost: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
