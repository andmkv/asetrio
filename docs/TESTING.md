# Testing

All suites run inside Aseprite (batch mode, Aseprite's embedded Lua 5.4), so they exercise the real scripting API:

```sh
./tests/run.sh                       # all suites
ASEPRITE=/path/to/aseprite ./tests/run.sh
```

| Suite | What it covers |
|---|---|
| `tests/run.lua` (76 tests) | Shade model, OKLCH color math, native-palette sync rules, subset exclusions, ordering, grid and toolbar geometry at narrow/default/wide widths, persistence errors, and the Light engine (family detection, eyedropper resolution, shade matching, Matte vs Glossy materials, point light direction/distance/falloff, preview zoom and pan). |
| `tests/integration.lua` (28 tests) | Real Aseprite API: 5/32/64/256-color palettes, palette edits and deletions, exclusions, save/reopen `.aseprite` vs PNG, indexed-palette safety, writing to the palette with undo, menu registration (one command, checked against `gui.xml`), Light on real cels, replace-source with undo, document switching. |
| `tests/smoke_dialogs.lua` (30 steps) | Every dialog against a strict fake `Dialog` (the real one is `nil` in batch mode): panel input, the `...` menu, About, editor, settings, choosers, Light, the family list and the preview eyedropper. Also checks that nothing writes window bounds after opening and that no widget visibility is toggled. |

## What the automated tests cannot prove

Native widget appearance, real mouse behavior, window placement, UI scaling and Aseprite's redraw behavior need a real Aseprite window. Use the checklist below.

Batch-mode quirks the tests work around: `Dialog()` returns `nil`, `Sprite:close()` crashes Aseprite 1.3.17, theme colors are transparent.

## Regenerating the README images

```sh
aseprite -b --script-param out=docs/images --script scripts/make_demo.lua
aseprite -b --script-param out=docs/images --script-param readme=1 --script-param scale=6 --script tests/render_preview.lua
```

The first command shades sample objects with the real Light engine and writes `light-flat-vs-shaded.png`, `light-materials.png`, `light-distance.png` and `light-demo.gif`. The second renders the panel's swatch grid with the same drawing code the extension uses. `tests/render_preview.lua` without `readme=1` writes technical renders to `build/` (git-ignored).

## Manual checklist

1. **View > Palette Trio** is the only menu entry. The panel is a narrow column of square swatches with two icons.
2. Click a swatch to paint, right-click for the background color, double-click to edit. Markers are readable on light and dark colors.
3. Resize the panel narrow and wide. Icons stay usable and nothing jumps back.
4. **... > 5 shades** and back: the window size does not change.
5. The menu opens beside the panel. Clicking **...** again or pressing Esc closes it. Unavailable items are greyed out.
6. Edit, add and delete palette colors in Aseprite. Families follow. An edited family that loses its color shows the orange edge and a dot on **...**.
7. **Choose palette colors...** keeps 4; edit the palette; **Use full document palette** brings the rest back.
8. **About Palette Trio...** shows the version and author. Both links open.
9. Light **Material: Glossy** on a sphere, a cylinder and a bevelled box: each shows a small crisp highlight (spot, band, lit edge); Matte looks as before.
10. Light: drag the light far outside the object, zoom out with the wheel, Alt+drag to pan, double-click to fit. Moving the light closer gives a stronger gradient; farther is dimmer. Height and Falloff change the result as described.
11. Light on an object painted only with shadow/highlight colors: the Family strip shows that family and the status reads "Auto family".
12. Light **Pick**, then click a highlight: that family is selected (strip shows it, **Auto** becomes available). Click a non-family color: a message appears and nothing changes.
13. Light **Output: Replace source**: the warning explains that the original is not saved in the file. Apply twice gives the same result. Undo restores the original. After restarting Aseprite, applying again shades the current pixels.
14. Save as `.aseprite` and reopen: same families, pins, exclusions and Light family pick. Save as PNG: a one-time warning appears.
15. **Write to sprite palette... > Append**, reopen the panel: the written shades did not become extra families. Undo reverts it.
16. Opening Palette Trio on a document does not mark it as modified.
