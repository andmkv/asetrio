# Changelog

## 0.5.3

- Light: the frame strip is much more compact, like Aseprite's own timeline: each cell is only as wide as the longest frame number needs (about 12 px for up to 9 frames, a little more for 10+ and 100+), the two rows are half as tall, and the dots are smaller.

## 0.5.2

- Light: the frame strip is now a simple one-row timeline like Aseprite's own: numbered cells, the chosen frame highlighted, and a dot under each frame that is filled when a checked layer has a cel there (hollow otherwise). No more thumbnails.

## 0.5.1

- Light: **Keep colors** no longer asks for HEX codes. Click **Add color** and then click colors in the preview; they show as chips in the preview, click again to remove, **Clear** removes all. (Colors stored by earlier versions are kept.)
- Light: the **auto / picked** label in the preview is now a real button (with the family's colors): click it to pick a family, click again to return to Auto. The **Auto** button is no longer greyed out.
- Light: the **Colors...** button is now **Families...**, which says what it does: choose which palette colors are families.

## 0.5.0

- Light: **several layers at once.** A layer list left of the preview with a checkbox per layer (and *all* / *none*); clicking a name selects just that layer. The preview shows all checked layers together on the chosen frame, and Apply shades them one after another with the same settings and one shared light. Each layer detects its own family.
- Light: **frames.** A one-row frame strip with thumbnails under the preview selects the frame to preview (the editor follows both ways). New **This frame / All frames** option next to Output; the whole job is one undo step.
- Light: the light position, height and falloff are the same for all layers. The preview now shows the whole sprite, so the light can be placed relative to everything.
- Fixed: the **Separate objects** checkbox never reached the lighting engine, so disconnected objects were always shaded separately. It now works.

## 0.4.1

- Fixed: the **Colors...** button in Light did nothing when Palette Trio's panel was already open and families existed. It now always opens **Choose palette colors**, and the preview refreshes when you apply the choice.

## 0.4.0

- Light: the light is now a **point light**. Click or drag in the preview to place it anywhere, including outside the object; its position sets both direction and distance. **Height** (px) replaces Elevation, and a new **Falloff** slider controls how much the light weakens with distance. The preview can be zoomed (wheel), panned (Alt/Shift/middle-drag) and fitted (double-click). Existing settings are converted to an equivalent light position on first use.
- Light: compact dialog. Shape and Material share a row, cylinder orientation is part of the Shape list, Bevel/Curvature are one **Form** slider, the two options share a row, Refresh moved to the button row, and scrollbars appear if the dialog does not fit.
- Light: the **Family** list with HEX codes is gone. The preview shows the active family as a strip of its colors (marked auto or picked), and the Family row has **Pick** and **Auto**.
- Light: new **Material** option, **Matte** (the original look) or **Glossy**. Glossy adds more body contrast and a crisp specular highlight that is the only part using the brightest shade; it is never dithered, and appears where the light glances off each shape (spot, band or bevel edge). The material is saved per layer. Matte output is unchanged.

## 0.3.2

- Fixed: choosing **About Palette Trio...** raised "Field link does not exist" in 0.3.1, because Aseprite's script dialogs have no link widget. The two links are now buttons that open the address in your browser (and show the address if the browser cannot be opened).

## 0.3.1

- Fixed: the About dialog read `package.json` from disk, which made Aseprite show a "Security" prompt asking for file access. The extension no longer reads any files of its own; the version is built into the code and checked against `package.json` at build time.

## 0.3.0 - first public beta

First public release. Earlier internal development builds were numbered 1.x and 2.x; public versions start at 0.3 and follow the beta. Sprite data written by those builds still loads.

- Panel with the families of your native Aseprite palette (3 or 5 shades), native-palette-sized swatches, and two icons: Light and a `...` menu.
- Native palette first: every eligible palette color is a family, in palette order. Palette edits are followed without losing names, order or hand-edited shades.
- Choose a subset of palette colors (saved), add custom colors, import colors from artwork or a palette file, remove families that are no longer in the palette.
- Hand-edited and pinned shades, editable bases, shade generation settings (OKLCH).
- Write generated colors to the sprite palette (append, or replace on RGB), export palette.
- Palette Trio Light: Sphere / Box / Cylinder / Contour, 3 or 5 shades, dithering, automatic family detection from any shade, a Pick eyedropper in the preview, new-layer output, and a replace-source option with a session-only original (see the README warning).
- One menu command: **View > Palette Trio**. About dialog in the `...` menu.
- MIT license.
