import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Compositor

/// Generation is BYOK and fire-and-forget; these tests pin the job lifecycle against a stub
/// backend: placeholder while running, one undo step on placement, actionable failures, and
/// receipts that serve unplaced bytes exactly once.
@MainActor
struct GenerationTests {
    final class MemoryCredentials: GenerationCredentialStore {
        var keys: [String: String] = [:]
        func key(for provider: String) -> String? { keys[provider] }
        func set(_ key: String, for provider: String) throws { keys[provider] = key }
        func remove(_ provider: String) { keys[provider] = nil }
    }

    /// Holds the provider call open so tests can close documents or cancel mid-flight.
    final class Gate: @unchecked Sendable {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func openGate() {
            open = true
            continuations.forEach { $0.resume() }
            continuations = []
        }
    }

    struct StubBackend: ImageGenerationBackend {
        var bytes: Data?
        var failure: String?
        var hangs = false
        var gate: Gate?

        func image(model: String, prompt: String, aspectRatio: String, apiKey: String) async throws -> Data {
            if let gate { await gate.wait() }
            if hangs {
                try await Task.sleep(for: .seconds(120))
                try Task.checkCancellation()
            }
            if let failure { throw GenerationError.rejected(failure) }
            return bytes ?? Data()
        }
    }

    private struct Fixture {
        let workspace: ProjectWorkspace
        let router: MCPRouter
        let generation: GenerationService
        let credentials: MemoryCredentials
    }

    private func tinyPNG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fixture(_ backend: StubBackend, key: String? = "test-key-1234") async throws -> Fixture {
        let workspace = ProjectWorkspace()
        let credentials = MemoryCredentials()
        if let key { credentials.keys["openai"] = key }
        let generation = GenerationService(workspace: workspace, credentials: credentials, backends: ["openai": backend])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = MCPRouter(workspace: workspace, skills: SkillStore(directory: directory), generation: generation)
        _ = try await call(router, "new_document", ["width": 40, "height": 40, "new_tab": false])
        return Fixture(workspace: workspace, router: router, generation: generation, credentials: credentials)
    }

    private func call(_ router: MCPRouter, _ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let response = await router.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]])!
        return try #require(response["result"] as? [String: Any])
    }

    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try #require(result["structuredContent"] as? [String: Any])
    }

    @Test func generateImageLandsLayerAndReportsLifecycle() async throws {
        let fixture = try await fixture(StubBackend(bytes: try tinyPNG()))
        let started = try await call(fixture.router, "generate_image", [
            "prompt": "a paper boat on calm water", "model": "openai/gpt-image-1", "name": "Boat"])
        #expect(started["isError"] as? Bool != true)
        let job = try structured(started)
        #expect(job["job_id"] as? Int == 1)
        #expect(job["state"] as? String == "running")
        // The placeholder marks the landing spot while the provider works.
        #expect(fixture.workspace.current.session.document?.layers.count == 2)
        let undoBefore = fixture.workspace.current.session.history.undoCount

        await fixture.generation.settle(1)
        let status = try structured(try await call(fixture.router, "manage_generations", ["action": "status", "job_id": 1]))
        #expect(status["state"] as? String == "succeeded")
        #expect(status["layer_id"] as? String != nil)
        #expect(status["image_data"] == nil)
        let layers = fixture.workspace.current.session.document?.layers ?? []
        #expect(layers.count == 2) // the empty canvas layer plus the generated one; placeholder swapped out
        #expect(layers.last?.asset != nil)
        #expect(layers.last?.name == "Boat")
        // Swapping the placeholder in is one undo step however many native calls it took.
        #expect(fixture.workspace.current.session.history.undoCount == undoBefore + 1)
    }

    @Test func generateWithoutKeyFailsActionably() async throws {
        let fixture = try await fixture(StubBackend(bytes: try tinyPNG()), key: nil)
        let result = try await call(fixture.router, "generate_image", ["prompt": "x", "model": "openai/gpt-image-1"])
        #expect(result["isError"] as? Bool == true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("manage_credentials"))
        #expect(fixture.workspace.current.session.document?.layers.count == 1)
        #expect(fixture.generation.summaries().isEmpty)
    }

    @Test func failedGenerationLeavesNoPlaceholder() async throws {
        let fixture = try await fixture(StubBackend(failure: "Content policy rejected the prompt."))
        _ = try await call(fixture.router, "generate_image", ["prompt": "x", "model": "openai/gpt-image-1"])
        await fixture.generation.settle(1)
        let status = try structured(try await call(fixture.router, "manage_generations", ["action": "status", "job_id": 1]))
        #expect(status["state"] as? String == "failed")
        #expect((status["error"] as? String)?.contains("policy") == true)
        #expect(fixture.workspace.current.session.document?.layers.count == 1)
    }

    @Test func cancelledJobStopsAndCleansUp() async throws {
        let fixture = try await fixture(StubBackend(hangs: true))
        _ = try await call(fixture.router, "generate_image", ["prompt": "x", "model": "openai/gpt-image-1"])
        let cancelled = try structured(try await call(fixture.router, "manage_generations", ["action": "cancel", "job_id": 1]))
        #expect(cancelled["state"] as? String == "cancelled")
        #expect(fixture.workspace.current.session.document?.layers.count == 1)
        await fixture.generation.settle(1)
        // Cancelling twice fails instead of touching anything else.
        let again = try await call(fixture.router, "manage_generations", ["action": "cancel", "job_id": 1])
        #expect(again["isError"] as? Bool == true)
        #expect(fixture.workspace.current.session.document?.layers.count == 1)
    }

    @Test func documentClosedMidFlightServesBytesOnce() async throws {
        let gate = Gate()
        let fixture = try await fixture(StubBackend(bytes: try tinyPNG(), gate: gate))
        _ = try await call(fixture.router, "generate_image", ["prompt": "x", "model": "openai/gpt-image-1"])
        // The target closes while the provider is still working.
        _ = try await call(fixture.router, "close_document", ["discard_changes": true])
        gate.openGate()
        await fixture.generation.settle(1)
        let status = try structured(try await call(fixture.router, "manage_generations", ["action": "status", "job_id": 1]))
        #expect(status["state"] as? String == "succeeded")
        #expect(status["layer_id"] == nil)
        #expect(status["image_data"] as? String != nil)
        // The bytes are served exactly once.
        let again = try structured(try await call(fixture.router, "manage_generations", ["action": "status", "job_id": 1]))
        #expect(again["image_data"] == nil)
    }

    @Test func credentialsAreSetButNeverEchoed() async throws {
        let fixture = try await fixture(StubBackend(bytes: try tinyPNG()), key: nil)
        let set = try await call(fixture.router, "manage_credentials",
            ["action": "set", "provider": "openai", "api_key": "sk-super-secret-1234"])
        #expect(set["isError"] as? Bool != true)
        let echoed = String(decoding: try JSONSerialization.data(withJSONObject: set), as: UTF8.self)
        #expect(!echoed.contains("sk-super-secret-1234"))
        #expect(try structured(try await call(fixture.router, "manage_credentials",
            ["action": "status", "provider": "openai"]))["configured"] as? Bool == true)
        _ = try await call(fixture.router, "manage_credentials", ["action": "remove", "provider": "openai"])
        #expect(try structured(try await call(fixture.router, "manage_credentials",
            ["action": "status", "provider": "openai"]))["configured"] as? Bool == false)
    }

    @Test func listModelsReportsCatalogAndAcceptsPassthroughIDs() async throws {
        let fixture = try await fixture(StubBackend(bytes: try tinyPNG()))
        let models = try structured(try await call(fixture.router, "list_models", [:]))
        let catalog = try #require(models["models"] as? [[String: Any]])
        #expect(catalog.contains { $0["id"] as? String == "gemini/nano-banana" })
        #expect((models["configured"] as? [String: Any])?["openai"] as? Bool == true)
        #expect((models["configured"] as? [String: Any])?["gemini"] as? Bool == false)

        // Newer upstream models ride the provider backend without a catalog release.
        let passthrough = try GenerationCatalog.parsed("gemini/gemini-3.1-flash-image-preview", registered: ["openai", "gemini"])
        #expect(passthrough.provider == "gemini")
        #expect(passthrough.upstream == "gemini-3.1-flash-image-preview")
        #expect(throws: GenerationError.self) {
            try GenerationCatalog.parsed("mystery/model", registered: ["openai", "gemini"])
        }
    }
}
