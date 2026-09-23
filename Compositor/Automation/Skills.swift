import Foundation

/// A markdown agent skill: `name` and `description` frontmatter followed by workflow prose.
/// Skills are editing recipes the agent loads before a multi-step edit; they suggest tool calls
/// but never execute anything themselves, so a bad skill can at worst suggest a bad workflow.
struct AgentSkill: Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let body: String
    /// The exact file contents, so `read_skill` round-trips what `manage_skills` stored.
    let markdown: String

    var summary: [String: Any] { ["id": id, "name": name, "description": description] }
    var detail: [String: Any] { ["id": id, "name": name, "description": description, "markdown": markdown] }
}

enum SkillError: Error, LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self { case .rejected(let message): return message }
    }
}

enum SkillParser {
    static let maximumMarkdownBytes = 256 * 1024
    static let maximumNameLength = 80
    static let maximumDescriptionLength = 1_024

    /// Skill ids double as directory names, so they stay conservative: lowercase letters, digits
    /// and inner hyphens.
    static func valid(id: String) -> Bool {
        guard (1...64).contains(id.count), let first = id.first, first.isLowercase || first.isNumber else { return false }
        return id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    static func parse(id: String, markdown: String) throws -> AgentSkill {
        guard valid(id: id) else {
            throw SkillError.rejected("id must be 1-64 lowercase letters, digits, or inner hyphens.")
        }
        guard markdown.utf8.count <= maximumMarkdownBytes else {
            throw SkillError.rejected("Skill markdown exceeds \(maximumMarkdownBytes) bytes.")
        }
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---" else { throw SkillError.rejected("Skill markdown must open with --- frontmatter.") }
        var fields: [String: String] = [:]
        var closing: Int?
        for (index, line) in lines.enumerated().dropFirst() {
            if line == "---" { closing = index; break }
            guard let colon = line.firstIndex(of: ":") else { throw SkillError.rejected("Frontmatter lines must be key: value pairs.") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { throw SkillError.rejected("Frontmatter keys and values cannot be empty.") }
            fields[key] = value
        }
        guard let closing else { throw SkillError.rejected("Frontmatter is missing its closing ---.") }
        let name = fields["name"] ?? ""
        let description = fields["description"] ?? ""
        guard !name.isEmpty, name.count <= maximumNameLength else {
            throw SkillError.rejected("name must be 1-\(maximumNameLength) characters.")
        }
        guard !description.isEmpty, description.count <= maximumDescriptionLength else {
            throw SkillError.rejected("description must be 1-\(maximumDescriptionLength) characters.")
        }
        let body = lines[(closing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SkillError.rejected("The skill body is empty; describe the workflow.") }
        return AgentSkill(id: id, name: name, description: description, body: body, markdown: markdown)
    }
}

/// Skills live on disk as `<directory>/<id>/SKILL.md` so agents can manage them with normal file
/// tools too. Writes are atomic and refuse to create nested paths.
@MainActor
final class SkillStore {
    let directory: URL

    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".compositor/skills", isDirectory: true)
    }

    init(directory: URL = SkillStore.defaultDirectory) {
        self.directory = directory
    }

    func index() throws -> [AgentSkill] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return try files
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .map { try skill(id: $0.lastPathComponent) }
            .sorted { $0.id < $1.id }
    }

    func skill(id: String) throws -> AgentSkill {
        guard SkillParser.valid(id: id) else { throw SkillError.rejected("Invalid skill id \(id).") }
        let url = directory.appendingPathComponent(id).appendingPathComponent("SKILL.md")
        guard let data = FileManager.default.contents(atPath: url.path),
              data.count <= SkillParser.maximumMarkdownBytes else {
            throw SkillError.rejected("No skill named \(id) is installed.")
        }
        return try SkillParser.parse(id: id, markdown: String(decoding: data, as: UTF8.self))
    }

    func save(_ skill: AgentSkill) throws {
        let folder = directory.appendingPathComponent(skill.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".SKILL-\(UUID().uuidString).md")
        try Data(skill.markdown.utf8).write(to: temporary, options: .atomic)
        _ = try? FileManager.default.removeItem(at: folder.appendingPathComponent("SKILL.md"))
        try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent("SKILL.md"))
    }

    func remove(id: String) throws {
        guard SkillParser.valid(id: id) else { throw SkillError.rejected("Invalid skill id \(id).") }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else {
            throw SkillError.rejected("No skill named \(id) is installed.")
        }
        try FileManager.default.removeItem(at: folder)
    }
}
