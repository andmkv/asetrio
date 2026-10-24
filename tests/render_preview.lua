-- Renders the real UI.paint() swatch grid into PNG files through a mock
-- GraphicsContext, so the grid layout can be inspected without the GUI.
-- Native Dialog widgets are NOT rendered; this checks only the custom canvas.
-- Usage: aseprite -b --script-param out=<dir> --script tests/render_preview.lua
--   (default output: build/, which is git-ignored)
--   --script-param readme=1 --script-param scale=6 renders only the README
--   panel images (docs/images) from a sample palette.
local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = sourcePath:match("^(.*)/tests/[^/]+$") or "."
local function load(path) return dofile(root .. "/" .. path) end
local outDir = app.params.out or app.fs.joinPath(root, "build")
app.fs.makeAllDirectories(outDir)
local SCALE = tonumber(app.params.scale) or 2

local mockGc = dofile(root .. "/tests/mock_gc.lua").new(SCALE)

local ctx = {
  color = load("src/color.lua"), modelModule = load("src/model.lua"),
  persistence = load("src/persistence.lua"), aseprite = load("src/aseprite.lua"),
  source = load("src/source.lua"), session = load("src/session.lua"),
  grid = load("src/grid.lua"), ui = load("src/ui.lua"), menu = load("src/menu.lua"),
  namespace = "palette-trio/palette-trio", selectedRow = 0, selectedSlot = "base", scroll = 0,
}

local function render(name, width, height)
  if not width then
    local box, line = ctx.ui.boxMetrics()
    width = ctx.grid.naturalWidth(ctx.model.shadeCount, box, line)
  end
  height = height or ctx.grid.initialHeight(#ctx.model.rows, ctx.model.shadeCount)
  local gc, image = mockGc(width or ctx.grid.WIDTH, height)
  ctx.ui.paint(ctx, gc)
  local file = app.fs.joinPath(outDir, name .. ".png")
  image:saveAs(file)
  print(string.format("%s  %dx%d logical  rows=%d", file, gc.width, gc.height, #ctx.model.rows))
end

local function spriteWith(colors)
  local sprite = Sprite(16, 16)
  local palette = Palette(#colors)
  for i, c in ipairs(colors) do palette:setColor(i - 1, Color { r = c[1], g = c[2], b = c[3] }) end
  sprite:setPalette(palette)
  return sprite
end

if app.params.readme then
  -- README panels: a sample 16-color palette, 3 and 5 shades, with a paint
  -- color, a background color, one manual shade and one pinned shade.
  local sample = {
    { 24, 20, 37 }, { 68, 36, 52 }, { 122, 54, 60 }, { 190, 74, 47 }, { 224, 122, 54 }, { 232, 178, 84 },
    { 244, 224, 142 }, { 120, 176, 70 }, { 52, 128, 96 }, { 52, 100, 124 }, { 70, 112, 200 }, { 120, 144, 236 },
    { 98, 68, 150 }, { 176, 90, 160 }, { 232, 140, 150 }, { 236, 232, 230 },
  }
  ctx.session.load(ctx, spriteWith(sample))
  ctx.provisional = false
  ctx.model.editShade(ctx.model, 5, "highlight", { r = 255, g = 214, b = 120 })
  ctx.model.setLocked(ctx.model, 9, "shadow", true)
  ctx.selectedRow, ctx.selectedSlot = 5, "base"
  app.fgColor = Color { r = sample[5][1], g = sample[5][2], b = sample[5][3] }
  local sh = ctx.model.rows[11].shades.shadow.color
  app.bgColor = Color { r = sh.r, g = sh.g, b = sh.b }
  render("panel-3-shades")
  ctx.model.setShadeCount(ctx.model, 5)
  render("panel-5-shades")
  return
end

local function palette(n)
  local list = {}
  for i = 1, n do list[i] = { (i * 53) % 256, (i * 97) % 256, (i * 29 + 40) % 256 } end
  return list
end

-- 1. Empty sprite with a 32-color native palette -> 32 families (scrolls).
ctx.session.load(ctx, spriteWith(palette(32)))
render("preview-32-families")

-- 2. Small palette, 3 shades: paint/background markers, pins, a custom color,
--    a family whose color left the palette (stored), and a selection.
local small = { { 34, 32, 52 }, { 69, 40, 60 }, { 102, 57, 49 }, { 143, 86, 59 },
  { 223, 113, 38 }, { 217, 160, 102 }, { 238, 195, 154 }, { 251, 242, 54 } }
ctx.session.load(ctx, spriteWith(small))
ctx.provisional = false
ctx.model.editShade(ctx.model, 2, "highlight", { r = 200, g = 90, b = 120 })
ctx.model.setLocked(ctx.model, 3, "shadow", true)
ctx.model.addCustom(ctx.model, { r = 40, g = 160, b = 90 })
ctx.model.rows[6].missing = true
ctx.selectedRow, ctx.selectedSlot = 4, "shadow"
local fg = ctx.model.rows[4].shades.shadow.color
app.fgColor = Color { r = fg.r, g = fg.g, b = fg.b }
app.bgColor = Color { r = small[7][1], g = small[7][2], b = small[7][3] }
render("preview-3-shades")

-- 3. Same document, 5 shades.
ctx.model.setShadeCount(ctx.model, 5)
render("preview-5-shades")

-- 4. Very narrow window (user resized), 5 shades.
render("preview-5-shades-narrow", 30, 200)

-- 5. 64 families in a wider, taller window, scrolled.
ctx.session.load(ctx, spriteWith(palette(64)))
ctx.scroll = 30 * ctx.grid.layout(90, 3).rowH
ctx.selectedRow = 1
render("preview-64-families-wide-scrolled", 90, 300)

-- 6. Overflow menu (painted list).
do
  ctx.session.load(ctx, spriteWith(small))
  ctx.menuHover = 6
  local items = ctx.menu.items(ctx)
  ctx.menuItems = items
  local _, h = ctx.menu.layout(items)
  local gc, image = mockGc(ctx.menu.WIDTH, h)
  ctx.menu.paint(ctx, gc)
  local file = app.fs.joinPath(outDir, "preview-menu.png")
  image:saveAs(file)
  print(file)
end

-- 7. No sprite.
ctx.session.load(ctx, nil)
render("preview-no-sprite")
