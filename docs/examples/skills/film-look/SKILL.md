---
name: Film Look
description: Cinematic film grade in Compositor — teal-and-orange contrast, gentle halation and grain on a nondestructive adjustment stack. Use when the user asks for a cinematic look, film look, teal and orange, or "make it feel like a movie still".
---
## Workflow

1. `describe_document` first; keep the grade on adjustment layers so every step stays editable.
2. Set contrast with `adjustment_operation` `action: "add"` `kind: "levels"`: lift the black output slightly (5–15) and keep highlights off 255 for a filmic roll-off.
3. Push the classic split tone with `kind: "gradient_map"`: warm hue (20–35°) into shadows, cool hue (190–215°) into highlights, then drop the layer opacity to 0.15–0.3 so it whispers rather than shouts.
4. Fine-tune skin separately with `kind: "hue_saturation"`: `colorize` false, `saturation` −5 to −15, `hue` within ±5 of neutral.
5. Add halation: `filter_operation` `kind: "gaussian"` is destructive, so instead duplicate the composite target, blur it with `filter_operation` on that duplicate, and blend it back at low opacity in `screen` mode via `layer_operation` `action: "blend"`.
6. Finish with `kind: "grain"` `amount` 5–15, `monochromatic: true`. Grain is the tell that sells the look.
7. Verify with `render_document` at preview size and compare against the user's reference description.

## Reference

| Element | Range | Fails when |
| --- | --- | --- |
| Shadow lift | 5–15 | blacks turn grey and the image looks washed out |
| Gradient map layer opacity | 0.15–0.3 | skin turns uniformly orange |
| Grain amount | 5–15, monochrome | colour noise reads as digital, not film |

## Notes

- Build the grade bottom-up in one named group ("Film look") with `layer_operation` `action: "add_group"` so one visibility toggle compares before/after.
- Never flatten the grade into pixels while the user may still want tweaks; adjustments are nondestructive and cost nothing.
- If the source is already high-contrast, halve every value above — film looks compress, they do not add more contrast.
- Mutations answer with a delta — patch your model from it instead of re-reading the document.
