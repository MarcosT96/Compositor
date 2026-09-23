import AppKit
import Foundation
import ImageIO
import Observation
import Security

/// BYOK image generation behind two fire-and-forget tools: `generate_image` places a placeholder
/// layer, works through the user's own provider key, and swaps in the result as one undo step while
/// `manage_generations` keeps the job pollable. Provider calls are the only outbound network the
/// agent surface makes, and keys live in the Keychain where tools can set but never read them back.
nonisolated enum GenerationError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self { case .rejected(let message): return message }
    }
}

// MARK: - Catalog

struct GenerationModel: Sendable {
    let id: String
    let provider: String
    let label: String
    let note: String
    let aspectRatios: [String]
    let upstreamModel: String

    var summary: [String: Any] {
        ["id": id, "provider": provider, "label": label, "description": note,
         "aspect_ratios": aspectRatios, "upstream_model": upstreamModel]
    }
}

enum GenerationCatalog {
    static let providers = ["openai", "gemini"]
    static let aspectRatios = ["1:1", "3:2", "2:3", "4:3", "3:4", "16:9", "9:16"]

    static let models: [GenerationModel] = [
        GenerationModel(id: "openai/gpt-image-1", provider: "openai", label: "GPT Image 1",
            note: "OpenAI's image model. Aspect maps to its three supported sizes.",
            aspectRatios: ["1:1", "3:2", "2:3"], upstreamModel: "gpt-image-1"),
        GenerationModel(id: "gemini/nano-banana", provider: "gemini", label: "Nano Banana",
            note: "Gemini 2.5 Flash Image: fast, faithful to references, good for iteration.",
            aspectRatios: ["1:1", "3:4", "4:3", "9:16", "16:9"], upstreamModel: "gemini-2.5-flash-image"),
        GenerationModel(id: "gemini/nano-banana-pro", provider: "gemini", label: "Nano Banana Pro",
            note: "Gemini 3 Pro Image: highest fidelity and text rendering, slower and pricier.",
            aspectRatios: ["1:1", "2:3", "3:2", "4:3", "3:4", "9:16", "16:9", "9:21", "21:9"],
            upstreamModel: "gemini-3-pro-image-preview")
    ]

    /// Accepts catalog ids and `provider/upstream-model` passthroughs, so a model released after
    /// this catalog still works with the right provider backend.
    static func parsed(_ model: String, registered providers: Set<String>) throws -> (provider: String, upstream: String) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        if let known = models.first(where: { $0.id == trimmed }) { return (known.provider, known.upstreamModel) }
        guard let slash = trimmed.firstIndex(of: "/") else {
            throw GenerationError.rejected("Unknown model \(model). Use list_models ids or provider/model passthrough.")
        }
        let provider = String(trimmed[..<slash]).lowercased()
        let upstream = String(trimmed[trimmed.index(after: slash)...])
        guard providers.contains(provider), !upstream.isEmpty, !upstream.contains("/") else {
            throw GenerationError.rejected("Unknown model \(model). Use list_models ids or provider/model passthrough.")
        }
        return (provider, upstream)
    }
}

// MARK: - Credentials

protocol GenerationCredentialStore: AnyObject {
    func key(for provider: String) -> String?
    func set(_ key: String, for provider: String) throws
    func remove(_ provider: String)
}

/// Provider keys are stored as generic passwords; tools can set and remove them but never read
/// them, so no agent can exfiltrate a key it was not given.
final class KeychainCredentialStore: GenerationCredentialStore {
    private static let service = "com.compositor.agent.generation"

    func key(for provider: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: provider,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ key: String, for provider: String) throws {
        remove(provider)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: provider,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw GenerationError.rejected("The Keychain would not store the \(provider) key.")
        }
    }

    func remove(_ provider: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: provider]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Provider backends

protocol ImageGenerationBackend: Sendable {
    func image(model: String, prompt: String, aspectRatio: String, apiKey: String) async throws -> Data
}

private enum ProviderHTTP {
    static func validate(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.rejected("\(provider) did not answer with HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? ((object?["error"] as? [String: Any])?["status"] as? String)
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw GenerationError.rejected("\(provider) rejected the request (HTTP \(http.statusCode)): \(message)")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw GenerationError.rejected("\(provider) returned more than 64 MB.")
        }
    }

    static func post(_ url: URL, headers: [String: String], body: [String: Any], provider: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data, provider: provider)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

struct OpenAIGenerationBackend: ImageGenerationBackend {
    func image(model: String, prompt: String, aspectRatio: String, apiKey: String) async throws -> Data {
        let size = ["1:1": "1024x1024", "3:2": "1536x1024", "2:3": "1024x1536"][aspectRatio] ?? "1024x1024"
        let object = try await ProviderHTTP.post(URL(string: "https://api.openai.com/v1/images/generations")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: ["model": model, "prompt": prompt, "n": 1, "size": size], provider: "OpenAI")
        guard let first = (object["data"] as? [[String: Any]])?.first else {
            throw GenerationError.rejected("OpenAI returned no image data.")
        }
        if let base64 = first["b64_json"] as? String, let bytes = Data(base64Encoded: base64) { return bytes }
        if let url = first["url"] as? String, let remote = URL(string: url) {
            let (data, response) = try await URLSession.shared.data(from: remote)
            try ProviderHTTP.validate(response, data: data, provider: "OpenAI")
            return data
        }
        throw GenerationError.rejected("OpenAI returned no image data.")
    }
}

struct GeminiGenerationBackend: ImageGenerationBackend {
    func image(model: String, prompt: String, aspectRatio: String, apiKey: String) async throws -> Data {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let headers = ["x-goog-api-key": apiKey]
        let contents: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        var body = contents
        body["generationConfig"] = ["responseModalities": ["TEXT", "IMAGE"], "imageConfig": ["aspectRatio": aspectRatio]]
        var object: [String: Any]
        do {
            object = try await ProviderHTTP.post(url, headers: headers, body: body, provider: "Gemini")
        } catch {
            // Older endpoints predate imageConfig; retry without it rather than fail the job.
            guard aspectRatio != "1:1" else { throw error }
            object = try await ProviderHTTP.post(url, headers: headers, body: contents, provider: "Gemini")
        }
        if let bytes = Self.firstImage(in: object) { return bytes }
        let text = Self.feedback(in: object)
        throw GenerationError.rejected("Gemini returned no image\(text.isEmpty ? "." : ": \(text)")")
    }

    private static func firstImage(in object: [String: Any]) -> Data? {
        let parts = ((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any], let base64 = inline["data"] as? String,
                  let bytes = Data(base64Encoded: base64) else { continue }
            return bytes
        }
        return nil
    }

    private static func feedback(in object: [String: Any]) -> String {
        if let block = (object["promptFeedback"] as? [String: Any])?["blockReason"] as? String { return block }
        let parts = ((object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: " ").prefix(200).description
    }
}

// MARK: - Jobs

nonisolated enum GenerationState: String, Sendable {
    case queued, running, succeeded, failed, cancelled
}

struct GenerationJob: Sendable {
    let number: Int
    let prompt: String
    let model: String
    let aspectRatio: String
    let layerName: String
    let point: CGPoint?
    let documentID: UUID?
    var placeholderLayerID: UUID?
    var state: GenerationState = .queued
    var layerID: UUID?
    var error: String?
    /// Generated bytes survive when the target document closed mid-flight; served once.
    var imageData: Data?
    let created = Date()
    var finished: Date?

    /// A placeholder for the person using the app and a receipt for the agent are the same thing.
    func summary(includeImage: Bool) -> [String: Any] {
        var value: [String: Any] = ["job_id": number, "prompt": String(prompt.prefix(120)), "model": model,
            "aspect_ratio": aspectRatio, "state": state.rawValue, "created": created.timeIntervalSince1970]
        if let documentID { value["document_id"] = documentID.uuidString }
        if let placeholderLayerID, state == .queued || state == .running { value["placeholder_layer_id"] = placeholderLayerID.uuidString }
        if let layerID { value["layer_id"] = layerID.uuidString }
        if let error { value["error"] = error }
        if let finished { value["finished"] = finished.timeIntervalSince1970 }
        if includeImage, let imageData { value["image_data"] = imageData.base64EncodedString() }
        return value
    }
}

/// Runs generation jobs and lands their results in live tabs. One job is one eventual undo step
/// ("Generate Image (Agent)") that swaps the placeholder for the generated layer.
@MainActor @Observable
final class GenerationService {
    private(set) var jobs: [GenerationJob] = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextNumber = 1
    let workspace: ProjectWorkspace
    private let credentials: GenerationCredentialStore
    private let backends: [String: ImageGenerationBackend]

    init(workspace: ProjectWorkspace,
         credentials: GenerationCredentialStore = KeychainCredentialStore(),
         backends: [String: ImageGenerationBackend] = ["openai": OpenAIGenerationBackend(), "gemini": GeminiGenerationBackend()]) {
        self.workspace = workspace
        self.credentials = credentials
        self.backends = backends
    }

    // MARK: Credentials

    func configured(_ provider: String) -> Bool { (credentials.key(for: provider) ?? "").utf8.count >= 8 }
    func setKey(_ key: String, provider: String) throws { try credentials.set(key, for: provider) }
    func removeKey(_ provider: String) { credentials.remove(provider) }

    // MARK: Lifecycle

    /// Creates the placeholder layer the person using the app will see, then generates in the
    /// background. Missing keys fail here with an actionable message instead of a dead job.
    @discardableResult
    func submit(prompt: String, model: String, aspectRatio: String, layerName: String?,
                documentID: UUID?, at point: CGPoint?) throws -> GenerationJob {
        let (provider, upstream) = try GenerationCatalog.parsed(model, registered: Set(backends.keys))
        guard let backend = backends[provider] else { throw GenerationError.rejected("No generation backend for \(provider).") }
        guard let key = credentials.key(for: provider), key.utf8.count >= 8 else {
            throw GenerationError.rejected("No API key for \(provider). Tell the user to store one with manage_credentials action set, then retry.")
        }
        guard let tab = workspace.tabs.first(where: { $0.id == documentID }) ?? (documentID == nil ? workspace.current : nil),
              tab.session.document != nil else { throw GenerationError.rejected("The target document is not open.") }
        guard tab.session.canEditLayers else { throw GenerationError.rejected("The target document has an unfinished edit; finish it first.") }

        let name = String((layerName ?? "Generating: \(prompt)").prefix(64))
        let session = tab.session
        session.beginEdit("Generate Image (Agent)")
        let before = Set(session.document?.layers.map(\.id) ?? [])
        session.addBlankLayer()
        // addBlankLayer can decline silently; only a layer that really appeared may be renamed.
        let placeholder = session.document?.layers.first { !before.contains($0.id) }?.id
        if let placeholder { session.renameLayer(placeholder, to: name) }
        session.endEdit()
        guard placeholder != nil else { throw GenerationError.rejected("Could not create the placeholder layer.") }

        var job = GenerationJob(number: nextNumber, prompt: prompt, model: model, aspectRatio: aspectRatio,
            layerName: name, point: point, documentID: tab.id, placeholderLayerID: placeholder)
        job.state = .running
        nextNumber += 1
        jobs.insert(job, at: 0)
        let number = job.number
        tasks[number] = Task { [weak self] in
            do {
                let data = try await backend.image(model: upstream, prompt: prompt, aspectRatio: aspectRatio, apiKey: key)
                try Task.checkCancellation()
                self?.place(number, data: data)
            } catch {
                self?.settleFailure(number, error: error)
            }
        }
        return job
    }

    func cancel(_ number: Int) throws {
        guard let index = jobs.firstIndex(where: { $0.number == number }) else {
            throw GenerationError.rejected("No job \(number).")
        }
        guard jobs[index].state == .queued || jobs[index].state == .running else {
            throw GenerationError.rejected("Job \(number) already finished.")
        }
        tasks[number]?.cancel()
        tasks[number] = nil
        jobs[index].state = .cancelled
        jobs[index].finished = Date()
        removePlaceholder(of: jobs[index])
    }

    func job(_ number: Int) throws -> GenerationJob {
        guard let job = jobs.first(where: { $0.number == number }) else { throw GenerationError.rejected("No job \(number).") }
        return job
    }

    func summaries() -> [[String: Any]] {
        prune()
        return jobs.map { $0.summary(includeImage: false) }
    }

    /// Serves unplaced bytes exactly once so a polling agent can still place the image itself.
    func receipt(_ number: Int) -> [String: Any] {
        let summary = (try? job(number))?.summary(includeImage: true) ?? ["job_id": number, "state": "failed", "error": "No job \(number)."]
        if let index = jobs.firstIndex(where: { $0.number == number }) { jobs[index].imageData = nil }
        return summary
    }

    /// Test and shutdown seam: waits until the job's provider call and placement are done.
    func settle(_ number: Int) async {
        await tasks[number]?.value
    }

    private func place(_ number: Int, data: Data) {
        tasks[number] = nil
        guard let index = jobs.firstIndex(where: { $0.number == number }) else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            settleFailure(number, error: GenerationError.rejected("The provider returned data Compositor could not decode as an image."))
            return
        }
        let job = jobs[index]
        guard let tab = workspace.tabs.first(where: { $0.id == job.documentID }), tab.session.document != nil, tab.session.canEditLayers else {
            // The target went away while the provider worked; the bytes stay retrievable once.
            jobs[index].state = .succeeded
            jobs[index].imageData = data
            jobs[index].finished = Date()
            return
        }
        let session = tab.session
        session.beginEdit("Generate Image (Agent)")
        let before = Set(session.document?.layers.map(\.id) ?? [])
        session.insert(ImportedImage(image: image, thumbnail: image, name: job.layerName), centeredAt: job.point)
        let placed = session.document?.layers.first { !before.contains($0.id) }?.id
        if let placeholder = job.placeholderLayerID, session.document?.layers.contains(where: { $0.id == placeholder }) == true {
            session.selectLayer(placeholder)
            session.deleteActiveLayer()
        }
        session.endEdit()
        jobs[index].state = .succeeded
        jobs[index].layerID = placed
        jobs[index].finished = Date()
    }

    private func settleFailure(_ number: Int, error: Error) {
        tasks[number] = nil
        guard let index = jobs.firstIndex(where: { $0.number == number }),
              jobs[index].state == .queued || jobs[index].state == .running else { return }
        let cancelled = error is CancellationError || Task.isCancelled
        jobs[index].state = cancelled ? .cancelled : .failed
        if !cancelled { jobs[index].error = error.localizedDescription }
        jobs[index].finished = Date()
        removePlaceholder(of: jobs[index])
    }

    private func removePlaceholder(of job: GenerationJob) {
        guard let placeholder = job.placeholderLayerID,
              let tab = workspace.tabs.first(where: { $0.id == job.documentID }),
              tab.session.document?.layers.contains(where: { $0.id == placeholder }) == true else { return }
        let session = tab.session
        session.beginEdit("Generate Image (Agent)")
        session.selectLayer(placeholder)
        session.deleteActiveLayer()
        session.endEdit()
    }

    /// Finished jobs stay visible for a while so polling agents always find their receipt.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-1_800)
        jobs.removeAll { job in
            guard let finished = job.finished else { return false }
            return finished < cutoff
        }
        while jobs.count > 64 { jobs.removeLast() }
    }
}
