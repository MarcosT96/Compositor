import Testing
import Foundation
import CoreGraphics
@testable import Compositor

/// Mutation answers are deltas in `describe_document` vocabulary with short ids; these tests pin
/// both halves of that contract: what a delta contains and that short ids round-trip.
@MainActor
struct AutomationDeltaTests {
    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try #require(result["structuredContent"] as? [String: Any])
    }

    private func delta(_ result: [String: Any]) throws -> [String: Any] {
        try #require(try structured(result)["delta"] as? [String: Any])
    }

    private func changedLayers(_ delta: [String: Any]) throws -> [[String: Any]] {
        try #require(delta["layers"] as? [[String: Any]])
    }

    private func threeShapes() async throws -> (ProjectWorkspace, EditorAutomation, [ImageLayer]) {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 100, "height": 100, "new_tab": false])
        for index in 0..<3 {
            _ = try await automation.call("shape_operation", arguments: [
                "kind": "Rectangle", "x": 5 + 10 * index, "y": 5, "width": 6, "height": 6,
                "color": ["red": 0.1, "green": 0.2, "blue": 0.3]
            ])
        }
        let layers = try #require(workspace.current.session.document?.layers)
        // Native new canvases start with one empty layer; the shapes stack on top of it.
        #expect(layers.count == 4)
        return (workspace, automation, layers)
    }

    @Test func renameReportsOnlyTheChangedLayer() async throws {
        let (workspace, automation, layers) = try await threeShapes()
        let renamed = try await automation.call("layer_operation", arguments: [
            "action": "rename", "layer_id": layers[2].id.uuidString, "name": "Middle"
        ])
        let change = try delta(renamed)
        let changed = try changedLayers(change)
        #expect(changed.count == 1)
        #expect(changed[0]["name"] as? String == "Middle")
        #expect(try #require(change["removed_layer_ids"] as? [String]).isEmpty)
        // Layer changes travel in their own array; `changed` names the other sections that moved
        // (the undo entry name here — the document was already dirty from the shapes).
        let sections = try #require(change["changed"] as? [String])
        #expect(!sections.contains("layers"))
        #expect(sections.contains("undo_name"))
        #expect(workspace.current.session.document?.layers[2].name == "Middle")
    }

    @Test func deleteReportsRemovedShortID() async throws {
        let (_, automation, layers) = try await threeShapes()
        let victim = layers[1]
        let deleted = try await automation.call("layer_operation", arguments: [
            "action": "delete", "layer_id": victim.id.uuidString
        ])
        let change = try delta(deleted)
        let removed = try #require(change["removed_layer_ids"] as? [String])
        #expect(removed.count == 1)
        #expect(victim.id.uuidString.hasPrefix(removed[0]))
        #expect(removed[0].count < 36)
    }

    @Test func reorderChangesLayerIndices() async throws {
        let (_, automation, layers) = try await threeShapes()
        let top = layers[3]
        let moved = try await automation.call("layer_operation", arguments: [
            "action": "move", "layer_id": top.id.uuidString, "offset": -1
        ])
        // The swapped pair changes top-to-bottom index; nothing else moves.
        #expect(try changedLayers(try delta(moved)).count == 2)
    }

    @Test func shortIDsRoundTripAndRejectMistakes() async throws {
        let (workspace, automation, _) = try await threeShapes()
        let described = try await automation.call("describe_document", arguments: [String: String]())
        let state = try structured(described)
        let manifest = try #require(state["layers"] as? [[String: Any]])
        // The manifest lists top to bottom, so its first entry is the newest shape.
        let short = try #require(manifest.first?["id"] as? String)
        #expect(short.count >= 8 && short.count < 36)
        _ = try await automation.call("layer_operation", arguments: ["action": "rename", "layer_id": short, "name": "Round trip"])
        #expect(workspace.current.session.document?.layers.last?.name == "Round trip")

        let documents = try structured(try await automation.call("list_documents", arguments: [String: String]()))
        let documentID = try #require(documents["selected_document_id"] as? String)
        #expect(documentID.count < 36)
        let targeted = try await automation.call("describe_document", arguments: ["document_id": documentID])
        #expect(try structured(targeted)["document_id"] as? String == documentID)

        await #expect(throws: (any Error).self) {
            _ = try await automation.call("layer_operation", arguments: ["action": "rename", "layer_id": "zzzzzzzz", "name": "x"])
        }
        await #expect(throws: (any Error).self) {
            _ = try await automation.call("layer_operation", arguments: ["action": "rename", "layer_id": "ab", "name": "x"])
        }
    }

    @Test func documentLifecycleReportsOpenedAndClosedIDs() async throws {
        let workspace = ProjectWorkspace(), automation = EditorAutomation(workspace: workspace)
        _ = try await automation.call("new_document", arguments: ["width": 40, "height": 40, "new_tab": true])
        let opened = try await automation.call("new_document", arguments: ["width": 60, "height": 60, "new_tab": true])
        let created = try #require(try structured(opened)["new_document_ids"] as? [String])
        #expect(created.count == 1)
        #expect(workspace.current.id.uuidString.hasPrefix(created[0]))
        let closed = try await automation.call("close_document", arguments: ["document_id": created[0], "discard_changes": true])
        let gone = try #require(try structured(closed)["closed_document_ids"] as? [String])
        #expect(gone.count == 1)
        #expect(try #require(try delta(closed)["closed_document_ids"] as? [String]).count == 1)
    }

    @Test func settingsChangesReportSectionDelta() async throws {
        let (_, automation, _) = try await threeShapes()
        let result = try await automation.call("settings_operation", arguments: ["zoom": 2.0])
        let change = try delta(result)
        #expect(try #require(change["changed"] as? [String]).contains("viewport"))
        #expect(((change["viewport"] as? [String: Any])?["zoom"] as? NSNumber)?.doubleValue == 2.0)
        #expect(try changedLayers(change).isEmpty)
    }
}
