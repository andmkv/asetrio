> **Internal design notes and development history.** Version numbers below (1.x, 2.x) belong to private development builds that came before the public 0.3 release. The technical renders mentioned here are generated into `build/` by `tests/render_preview.lua` and are not committed.

# Palette Trio — UX audit and design spec (v2.0)

Audit of v1.1.0 (`main.lua`, `src/*.lua`, `tests/run.lua`, README, package) against
Aseprite 1.3.17 on macOS. Findings are ordered by impact on the painting workflow.

## Prioritized findings

| # | Severity | Area | Finding (v1.1) |
|---|----------|------|----------------|
| 1 | Critical | Discovery | The panel opens on an empty "No rows" canvas. The artist must find **Import sprite palette** (or **Add row from FG**) before anything is useful. The primary user story ("I open it and see my colors as shade families") never happens. |
| 2 | Critical | Discovery | **Import sprite palette** blindly converts *every* entry of palette 0 into a row. On Aseprite's default 32-color palette that is 32 families / 96–160 shades; on a 256-entry palette it is 256 rows. Duplicates, transparent entries and the indexed transparent index are imported too. |
| 3 | Critical | Data safety | Import calls `replaceRows`, which deletes every existing family, manual override, lock and name with no confirmation. The only safety net is undo. |
| 4 | High | Layout | The canvas requests 520×420 logical px (≈1040×840 physical at 2× screen scale), plus `hexpand/vexpand` and a row of nine form widgets. The dialog covers most of the editor even with zero rows. |
| 5 | High | Hierarchy | Painting (swatches), editing (picker + HEX + name), row management (5 buttons), palette I/O (import/apply/export) and generation settings all sit at the same visual level. Configuration dominates the colors. |
| 6 | High | Interaction | Click both *selects for editing* and *sets the FG color*, and the always-visible picker/HEX field then edits that swatch. A stray picker change silently rewrites a palette color. Selecting vs. editing is not separated. |
| 7 | High | Integration | No relationship with the native palette after import: no link per row, no way to notice the palette changed, no non-destructive refresh. |
| 8 | High | Reliability | `persist()` wraps the save in `pcall` and discards the result. If the property write fails (no sprite, read-only, API error) the artist believes it was saved. It also writes to `app.sprite`, which is not necessarily the sprite the model was loaded from. |
| 9 | Medium | Semantics | Editing a generated shade sets `override` but not `locked`, so the next base change or settings change silently throws the manual color away. "Manual" and "locked" are two flags with an unclear difference. |
| 10 | Medium | Feedback | No indication of which swatch is the current FG/BG. Lock/override markers are text suffixes ("[L]", "*") drawn under each swatch, eating 25 px per row. No hover info. |
| 11 | Medium | Apply | **Apply to sprite** on RGB replaces the whole palette (only option). There is no non-destructive "append missing colors" choice for RGB even though the indexed path already implements one. |
| 12 | Medium | Persistence | PNG/GIF/JPG files cannot store extension properties. Nothing tells the artist that their families will be lost when saving to PNG. |
| 13 | Medium | Light | Light is a separate 440×280 preview + ~16 full-width controls; advanced options (outlines, components, excluded colors) are always visible; the layer list shows UUID fragments. With no families it says "Add at least one base row…" without a one-click recovery. |
| 14 | Low | Scaling | `show{autoscrollbars=true}` plus a large minimum canvas causes scrollbars at UI scale 2; the swatch grid uses a fixed 78 px label gutter that rarely carries information. |
| 15 | Low | Tests | Tests cover the model and Light engine well but nothing that touches the real Aseprite API (palettes, properties round-trip through a file, indexed apply, undo). No Lua interpreter was configured; Aseprite's own `--batch --script` runtime works. |

## Design principles (v2)

1. **Colors first.** The swatch grid is the panel. Everything else is one row of small buttons.
2. **Reading is free, writing is explicit.** Opening, switching documents and auto-initializing never write palette entries, pixels, or even document properties. Families are stored only after the artist changes something. Writing to the native palette is a separate, confirmed command with an append-only default.
3. **Select ≠ edit.** Click paints. Editing is a deliberate action (double-click or **Edit**) in a small editor that follows the selection.
4. **One pin concept.** A shade is either *auto* (follows its base) or *pinned* (manual edit or lock). Pinned shades survive base/setting changes until **Restore auto**.
5. **Never lose work silently.** Sync and color selection merge by row identity and source color; rows that would be removed are listed and confirmed; save failures are shown.

## Interaction flow

### Before (v1.1)
Open → empty "No rows" canvas → find **Import sprite palette** → 32–256 rows replace any existing work → click a swatch (sets FG *and* arms the picker) → picker/HEX edits whatever is selected → settings under a tab → **Apply to sprite** replaces RGB palette.

### After (v2.0)
1. Open Palette Trio on a sprite.
2. The source is discovered automatically:
   - document palette with ≤16 distinct opaque colors → those colors;
   - otherwise artwork using ≤16 base colors → those colors (generated shades already in the art are recognized and not turned into extra families);
   - otherwise (default 32-color palette on an empty canvas, anti-aliased art, 256-color palettes) → a compact empty state: *"32 palette colors · Choose base colors…"*.
3. The grid shows `SHADOW | BASE | LIGHT` (or `DEEP … BRIGHT`) for each family, sized to the row count.
4. Left click = FG, right click = BG. Small corner markers show the current FG/BG swatches; hover shows `Row · slot · #HEX · state` in the status line.
5. Double-click (or **Edit**) opens a small editor: color picker + HEX, Pin/Unpin, Restore auto, name, move, remove, "Use FG".
6. When the native palette changes, the source line shows **changed**; **Sync** updates linked families in place (by color, then by palette index), keeps pins/names/order, adds new colors, and keeps (and reports) families whose source color disappeared.
7. **⋯ More** holds generation settings, Choose colors, palette files, and **Write to sprite palette** (append-missing by default; RGB replace only after confirmation).
8. **Light…** opens the compact lighting panel; it reads the same families (provisional or saved).

## Layout spec (logical px, `autoscaling` canvas)

- Main dialog ≈ 300–340 px wide: source line, radio `3 | 5`, canvas, status line, one button row `+ Add · Edit · Sync · Light… · ⋯`.
- Canvas: 12 px column header + 26 px per row (22 px swatch + gap). Height fits 1–10 rows (min ≈ 64 px for the empty state); longer palettes scroll with the wheel. Not stretched horizontally; columns share the canvas width.
- Height is refit after rows are added/removed (dialog bounds adjusted by `delta × app.uiScale`).
- Light: ≈ 240×170 preview, essential controls visible; outlines/components/excluded colors/curvature behind an **Advanced** check.

## Data model changes (schema v2, v1 migrated in place)

- `source = { kind = "palette" | "artwork" | "manual" | "file" | "legacy", label }`.
- Per row: `link = { color, index }` for families created from a source; `baseEdited` when the base was changed inside Palette Trio (sync then never overwrites it).
- `editShade` pins (`override = true, locked = true`). v1 rows with `override` but no lock keep their v1 behavior until edited.
- Unknown future versions are not overwritten on open; the panel says so.

## Implementation notes (deviations from v1 behavior)

- **Pin semantics:** editing a shade now pins it (`locked = true`). In v1 an unlocked manual color was silently discarded by the next base/settings change. v1 data with that state keeps its old behavior until edited (covered by a test).
- **Write to palette:** RGB now defaults to *Append missing*; *Replace* is the explicit alternative. Indexed remains append-only.
- **Light defect fixed:** `light_aseprite.effectivelyVisible()` indexed `parent.isGroup` on the Sprite (the parent of top-level layers), which raises "Field isGroup does not exist". In v1.1 this broke Light's source-layer list. It was found by the headless smoke test.
- Light layer labels drop the UUID suffix unless two layers share a name.

## QA results (2026-10-23)

| Check | Result |
|---|---|
| `tests/run.lua` (unit) | 56 passed, 0 failed |
| `tests/integration.lua` (real Aseprite 1.3.17 API, batch) | 18 passed, 0 failed |
| `tests/smoke_dialogs.lua` (every dialog vs. strict fake Dialog) | 18 passed, 0 failed |
| Package build + `init()`/`exit()` of the packaged archive | OK, both commands register |
| Swatch-grid render (`build/preview-*.png`, real `UI.paint`, mock GC, 2×) | Inspected: empty state 252×60, 8 families 252×208, 30 families capped at 252×256 with scroll thumb; markers render as designed |
| Live GUI (native widget layout, UI scale, real clicks) | **Not performed.** No GUI-automation access in this session, and the user's Aseprite instance was running. Use the README's manual UAT checklist. |

Batch-mode caveats found while testing: `Dialog()` returns `nil`, `Sprite:close()` crashes Aseprite 1.3.17, theme colors are transparent, and assigning `app.alert` has no effect. The tests work around each of these.

---

# 2.1.0 revision (after GUI testing of 2.0 in Aseprite 1.3.17)

## Findings from the artist's GUI test → decisions

| # | 2.0 problem (observed) | Root cause | 2.1 decision |
|---|---|---|---|
| 1 | A 32-color palette on an empty sprite produced zero families; art with one color narrowed the families | `Source.decide()` used a 16-color auto limit and fell back to artwork colors | The native palette is the default source, with every eligible entry in palette order. `decide()`/`AUTO_LIMIT` were removed. |
| 2 | Authored colors could disappear | `Source.removeDerived()` guessed that colors resembling generated shades were shades | No guessing. Only recorded provenance (`model.generated`, written in the same transaction as **Write to palette**) excludes colors. |
| 3 | Two menu entries under File > Scripts | Two `newCommand` calls with `group = "file_scripts"` | One command, `PaletteTrio`, in `view_new` (View menu, verified in 1.3.17's `gui.xml`). Light opens from the panel's sun icon. |
| 4 | Control-heavy window (Sync, Add FG, Edit, More, status rows) | Native button minimum widths and a status label | The window is one canvas: a painted toolbar (3/5, Light, +, ...) and the swatch grid, about 120 logical px wide. Everything else is in secondary dialogs. "FG" wording removed. |
| 5 | Manual resize snapped back | `UI.fitHeight()` reassigned `Dialog.bounds` from the row count on every structural refresh | Bounds are never written after `show`. They are saved on close and restored once through `show{bounds=}`. |
| 6 | Ghost images in main, secondary and Light windows | Bounds written after `show`, Light closed and rebuilt on refresh/undo/sprite change, and visibility toggles forced relayouts; plus an upstream 1.3.17 invalidation issue | No post-show bounds writes, no rebuilds (Light reloads in place via `modify{options=}`), and no `visible` toggles (`enabled` only). The upstream part is documented, not claimed fixed. |
| 7 | Excluded colors could come back | Exclusions only existed for the old chooser | `ignored` = deliberate exclusions, which persist and are honored by every sync. **Use full document palette** clears them. |
| 8 | Light re-apply compounded when writing over the source | No replace mode existed; a naive one would shade the shaded pixels | **Output: Replace source** asks first, writes one cel, and keeps a session snapshot. It is used only while the cel still holds Palette Trio's exact output bytes. |

## State ownership (2.1)

- **Native palette:** the artist's base colors. Families link to their palette slot and color. Palette changes are merged **in memory** (deterministic, non-destructive, no undo noise); the document is written only on artist actions.
- **Palette Trio:** derived shades, manual/pinned shades, names, order (palette order unless reordered), exclusions, custom colors, and write provenance.
- **Artwork:** image data only, and an optional import source.

## QA results (2.1.0, 2026-10-23, Aseprite 1.3.17 batch)

| Suite | Result |
|---|---|
| Unit (`tests/run.lua`) | 56 passed, 0 failed |
| Integration, real API (`tests/integration.lua`) | 26 passed, 0 failed |
| Dialog smoke with bounds/duplicate/relayout guards (`tests/smoke_dialogs.lua`) | 19 passed, 0 failed |
| Swatch-grid render (`build/preview-*.png`) | 32 families, 3/5 shades with every marker, 64 families scrolled in an enlarged window, and the no-sprite state, all inspected |
| Live GUI (menu placement, mouse, resize, ghosts, UI scale) | **Not performed in this session.** The README UAT checklist covers it. |

---

# 2.2.0 refinement (after GUI testing of 2.1)

| # | 2.1 issue (observed) | 2.2 decision |
|---|---|---|
| 1 | Panel still wide (120 px) and padded; swatches looked like large cards | Dense, native-palette-like grid: square cells sized from the width (6–22 px), 1 px gaps, a 2 px accent gap around BASE, default canvas 64 logical px wide. |
| 2 | Toolbar too busy (3/5, Light, +, ...) | Two icons only: **Light** (sun) and **...**. 3/5 shades, colors, settings, write and export all moved into the menu. |
| 3 | Toolbar controls clipped when the window was made narrower | Toolbar geometry is right-aligned when there is room and pinned to the left edge otherwise, so it never goes negative. Cells clamp to a minimum, and the BASE gap collapses at extreme widths. The layout is tested at widths 20–1000. |
| 4 | No overflow menu exists in the 1.3.17 script API | The menu is a small window with one painted canvas: hover highlight, check marks, greyed-out items, and a notice line. It is placed once beside the panel and closes after an action, on Esc, or when ... is clicked again. Notices became a badge on ... instead of text in the panel. |
| 5 | Light depended on the right color being selected / only exact BASE pixels were shaded | Any family color (all 5 shades) identifies the family. **Auto (detect)** reports the dominant family (`Engine.detectFamily`). An explicit family, saved per layer, also shades unknown-colored pixels. The panel's paint color is never used. |
| 6 | No way to point at the object | **Pick** (or right-click) on the Light preview resolves the clicked source pixel: an exact match on any shade, or a nearest match only when clearly unambiguous. Otherwise it explains and keeps the current family. A family strip in the preview shows the active family. |
| 7 | Prototype look | Two-tone selection frame drawn in the gaps, proportional paint/background triangles, 1–2 px state marks, and a hover state on the icons. |

Light engine algorithms (geometry, quantization, dithering, outlines, components) are unchanged. `Engine.render` gained two opt-in options, `matchShades` and `fallbackFamily`, and both default to the 2.1 behavior.

## QA results (2.2.0, 2026-10-23, Aseprite 1.3.17 batch)

| Suite | Result |
|---|---|
| Unit (`tests/run.lua`) | 63 passed, 0 failed |
| Integration, real API (`tests/integration.lua`) | 28 passed, 0 failed |
| Dialog smoke (`tests/smoke_dialogs.lua`) | 23 passed, 0 failed |
| Renders (`build/preview-*.png`) | 3/5 shades at the default width, 5 shades at 40 px, 32 families, 64 families wide and scrolled, menu, no sprite: all inspected |
| Live GUI | **Not performed in this session.** Use the README UAT checklist. |

### 2.2.1: native swatch size

GUI feedback: Palette Trio's cells were larger than the native palette's, and the beige gaps made the window wider than necessary. Now cells use `app.preferences.color_bar.box_size` (default 11) and `entries_separator` (1px dark lines), sit edge to edge on a dark block, never grow past the native size (centered in wider windows), and shrink only when the window is narrower. The default canvas is 40 logical px wide with 3 shades. The window title bar now sets the window's minimum width. The toolbar icons align with the block's right edge. Suites: 63 / 28 / 23 passed.

### 2.2.2: short window title
The main window title is now "Trio" (the menu command is still View > Palette Trio). In Aseprite the title bar sets the minimum window width, and "Palette Trio" was wider than the 40px swatch grid.
