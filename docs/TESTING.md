# Testing

All suites run inside Aseprite (batch mode, Aseprite's embedded Lua 5.4), so they exercise the real scripting API:

```sh
./tests/run.sh                       # all suites
ASEPRITE=/path/to/aseprite ./tests/run.sh
```

| Suite | What it covers |
|---|---|
| `tests/run.lua` (63 tests) | Shade model, OKLCH color math, native-palette sync rules, subset exclusions, ordering, grid and toolbar geometry at narrow/default/wide widths, persistence errors, and the Light engine (family detection, eyedropper resolution, shade matching). |
| `tests/integration.lua` (28 tests) | Real Aseprite API: 5/32/64/256-color palettes, palette edits and deletions, exclusions, save/reopen `.aseprite` vs PNG, indexed-palette safety, writing to the palette with undo, menu registration (one command, checked against `gui.xml`), Light on real cels, replace-source with undo, document switching. |
| `tests/smoke_dialogs.lua` (24 steps) | Every dialog against a strict fake `Dialog` (the real one is `nil` in batch mode): panel input, the `...` menu, About, editor, settings, choosers, Light, the family list and the preview eyedropper. Also checks that nothing writes window bounds after opening and that no widget visibility is toggled. |

## What the automated tests cannot prove

Native widget appearance, real mouse behavior, window placement, UI scaling and Aseprite's redraw behavior need a real Aseprite window. Use the checklist below.

Batch-mode quirks the tests work around: `Dialog()` returns `nil`, `Sprite:close()` crashes Aseprite 1.3.17, theme colors are transparent.

## Regenerating the README images

```sh
aseprite -b --script-param out=docs/images --script scripts/make_demo.lua
aseprite -b --script-param out=docs/images --script-param readme=1 --script-param scale=6 --script tests/render_preview.lua
```

The first command shades sample objects with the real Light engine and writes `light-flat-vs-shaded.png` and `light-demo.gif`. The second renders the panel's swatch grid with the same drawing code the extension uses. `tests/render_preview.lua` without `readme=1` writes technical renders to `build/` (git-ignored).

## Manual checklist

1. **View > Palette Trio** is the only menu entry. The panel is a narrow column of square swatches with two icons.
2. Click a swatch to paint, right-click for the background color, double-click to edit. Markers are readable on light and dark colors.
3. Resize the panel narrow and wide. Icons stay usable and nothing jumps back.
4. **... > 5 shades** and back: the window size does not change.
5. The menu opens beside the panel. Clicking **...** again or pressing Esc closes it. Unavailable items are greyed out.
6. Edit, add and delete palette colors in Aseprite. Families follow. An edited family that loses its color shows the orange edge and a dot on **...**.
7. **Choose palette colors...** keeps 4; edit the palette; **Use full document palette** brings the rest back.
8. **About Palette Trio...** shows the version and author. Both links open.
9. Light on an object painted only with shadow/highlight colors: the status reads "Auto: family N".
10. Light **Pick**, then click a highlight: that family is selected. Click a non-family color: a message appears and nothing changes.
11. Light **Output: Replace source**: the warning explains that the original is not saved in the file. Apply twice gives the same result. Undo restores the original. After restarting Aseprite, applying again shades the current pixels.
12. Save as `.aseprite` and reopen: same families, pins, exclusions and Light family pick. Save as PNG: a one-time warning appears.
13. **Write to sprite palette... > Append**, reopen the panel: the written shades did not become extra families. Undo reverts it.
14. Opening Palette Trio on a document does not mark it as modified.
