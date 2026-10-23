# Changelog

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
