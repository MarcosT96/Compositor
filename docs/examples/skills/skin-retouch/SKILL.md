---
name: Skin Retouch
description: Natural portrait skin cleanup in Compositor — remove blemishes and soft shine while keeping texture. Use when the user asks to retouch skin, clean up a portrait, remove blemishes, or "make it look natural, not plastic".
---
## Workflow

1. Read the document first: `list_documents`, then `describe_document`. Find the portrait layer and note its `id`.
2. Duplicate the layer with `layer_operation` `action: "duplicate"` so the retouch stays reversible on top of the original.
3. Heal obvious blemishes: `paint_stroke` with `mode: "heal"` along a `points` path over each spot. Keep `diameter` just larger than the blemish and `hardness` low (0.2–0.4).
4. Remove stray hairs and edges with `mode: "clone"` and a `clone_source` point sampled from clean skin near the target. Prefer aligned clone passes along the hair, not dabs.
5. Soften oily shine with `mode: "blur"`, `opacity` 0.15–0.3, a large `diameter`, and short strokes over the highlight only.
6. If any pass smeared texture, `history_operation` `action: "undo"` it and redo with a smaller brush — smudged pores read as fake immediately.
7. Verify with `render_document` and compare against the layer name; report which regions changed.

## Reference

| Setting | Typical value |
| --- | --- |
| Heal diameter | 1.5× the blemish, never wider than 1/8 of the face |
| Heal hardness | 0.2–0.4 |
| Clone opacity | 0.5–0.8 (layer passes slowly, keep strokes sparse) |
| Blur pass opacity | 0.15–0.3 |

## Notes

- Never retouch on the background layer: always duplicate first. The undo history is shared with the person using the app, so each `paint_stroke` is one undo step they can revert.
- Stop before the skin looks blurred. "Natural" means pores remain visible at 100% zoom.
- Eye whites, teeth and lips are not skin: use separate strokes with lower opacity, and never brighten lips.
- Mutations answer with a delta — patch your model from it instead of re-reading the document.
