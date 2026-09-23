---
name: Product Composite
description: Cut a product into a new background in Compositor with clean edges, a contact shadow, and matched color. Use when the user asks to place a product on a different background, make a hero shot, or build a packshot composite.
---
## Workflow

1. Import both images as base64 with `import_image` (`filename` keeps the extension; JPEG, PNG, HEIC or TIFF). Background first, product second, so the product layer lands on top.
2. Select the product: `sample_selection` with `kind: "object"` at a point inside it. For plain studio backdrops use `kind: "wand"` with `tolerance` 20–40 and `contiguous: true` instead.
3. Invert and refine: `selection_operation` `action: "invert"` if the selection grabbed the background; `action: "expand"` 1–2 px then `action: "feather"` 1–2 px for photographic edges.
4. Build the cutout as a mask: `mask_operation` `action: "add"` with `from_selection: true`, `revealing: true`. Never delete pixels — the mask stays editable.
5. Paint the mask edges by hand: `paint_stroke` with `target: "mask"` (white reveals, black hides), `diameter` 8–20, `hardness` 0.3. Halos come from mask values that are grey where they should be pure.
6. Scale and place with `transform_operation`. Match the background's perspective before matching color.
7. Add the contact shadow: `layer_operation` `action: "duplicate"` the product, `effect_operation` `action: "add"` `kind: "shadow"` with `distance` 2–8, `blur` 10–30, `opacity` 0.3–0.5, then `transform_operation` to flatten it under the product, or paint it on a blank layer with `paint_stroke` and low opacity.
8. Match color: `adjustment_operation` `action: "add"` `kind: "hue_saturation"` and `kind: "levels"` on the product, clipped above it, nudging until the product's whites match the scene's whites.
9. Verify at 100% with `render_document`; then zoom out mentally — edges and shadow scale tell the truth.

## Reference

| Step | Sign of doing it right |
| --- | --- |
| Mask edge | Grey only across 1–2 px of genuine transition |
| Shadow | Darkest where the product touches the surface, fading out |
| Color match | Product whites and the scene whites share one temperature |

## Notes

- Selections consume into masks in one undo step; reselect rather than trying to move a live selection by mask painting.
- If `sample_selection` `kind: "object"` traces too much, fall back to wand plus mask painting. Report which method you used.
- Keep the untouched product layer below the retouched stack and name layers by role ("Product cutout", "Contact shadow", "Grade").
- Mutations answer with a delta — patch your model from it instead of re-reading the document.
