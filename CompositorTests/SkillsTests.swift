import Testing
import Foundation
@testable import Compositor

@MainActor
struct SkillsTests {
    private let sample = """
    ---
    name: Skin Retouch
    description: Clean up skin while keeping natural texture.
    ---
    ## Workflow
    1. Heal blemishes with `paint_stroke` in heal mode.
    """

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func parsesFrontmatterAndPreservesMarkdown() throws {
        let skill = try SkillParser.parse(id: "skin-retouch", markdown: sample)
        #expect(skill.name == "Skin Retouch")
        #expect(skill.description == "Clean up skin while keeping natural texture.")
        #expect(skill.body.hasPrefix("## Workflow"))
        #expect(skill.markdown == sample)
    }

    @Test func rejectsMalformedSkills() {
        #expect(throws: SkillError.self) { try SkillParser.parse(id: "Bad_Id", markdown: sample) }
        #expect(throws: SkillError.self) { try SkillParser.parse(id: "-leading", markdown: sample) }
        #expect(throws: SkillError.self) { try SkillParser.parse(id: "ok", markdown: "no frontmatter") }
        #expect(throws: SkillError.self) { try SkillParser.parse(id: "ok", markdown: "---\nname: Only name\n---\nbody") }
        #expect(throws: SkillError.self) { try SkillParser.parse(id: "ok", markdown: "---\nname: x\ndescription: y\n---") }
    }

    @Test func storeRoundTripsInTemporaryDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SkillStore(directory: directory)
        let skill = try SkillParser.parse(id: "skin-retouch", markdown: sample)
        try store.save(skill)
        #expect(try store.index().map(\.id) == ["skin-retouch"])
        #expect(try store.skill(id: "skin-retouch") == skill)
        try store.remove(id: "skin-retouch")
        #expect(try store.index().isEmpty)
        #expect(throws: SkillError.self) { try store.skill(id: "skin-retouch") }
    }

    @Test func defaultDirectoryLandsInApplicationSupport() {
        // A sandboxed app resolves its home to the container; skills must live where it can
        // actually read them, beside automation.json — not in the user's real ~/.compositor.
        #expect(SkillStore.defaultDirectory.path.hasSuffix("Application Support/Compositor/skills"))
    }

    @Test func routerExposesSkillToolsAndInstructions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = MCPRouter(workspace: ProjectWorkspace(), skills: SkillStore(directory: directory))

        let created = await router.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "manage_skills", "arguments": ["action": "create", "id": "skin-retouch", "markdown": sample]
        ]])!
        #expect((created["result"] as? [String: Any])?["isError"] as? Bool != true)

        // A duplicate create fails as a tool error and leaves the stored skill intact.
        let duplicate = await router.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "manage_skills", "arguments": ["action": "create", "id": "skin-retouch", "markdown": sample]
        ]])!
        #expect((duplicate["result"] as? [String: Any])?["isError"] as? Bool == true)

        let read = await router.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "read_skill", "arguments": ["id": "skin-retouch"]
        ]])!
        let detail = try #require((read["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        #expect(detail["markdown"] as? String == sample)

        let initialized = await router.handle(["jsonrpc": "2.0", "id": 4, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])!
        let instructions = try #require((initialized["result"] as? [String: Any])?["instructions"] as? String)
        #expect(instructions.contains("skin-retouch"))

        let removed = await router.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": [
            "name": "manage_skills", "arguments": ["action": "remove", "id": "skin-retouch"]
        ]])!
        #expect((removed["result"] as? [String: Any])?["isError"] as? Bool != true)
        let missing = await router.handle(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": [
            "name": "read_skill", "arguments": ["id": "skin-retouch"]
        ]])!
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
    }
}
