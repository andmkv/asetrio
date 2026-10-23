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

local GLYPH_W, GLYPH_H = 5, 8

local function mockGc(width, height)
  local image = Image(width * SCALE, height * SCALE, ColorMode.RGB)
  image:clear(app.pixelColor.rgba(48, 48, 52, 255))
  local gc = { width = width, height = height, color = Color { r = 255, g = 255, b = 255 }, strokeWidth = 1 }
  local clip = nil
  local stack = {}
  local path = {}
  local function plot(x, y, c)
    if clip and (x < clip.x or y < clip.y or x >= clip.x + clip.width or y >= clip.y + clip.height) then return end
    if x < 0 or y < 0 or x >= width or y >= height then return end
    local a = c.alpha / 255
    for dy = 0, SCALE - 1 do
      for dx = 0, SCALE - 1 do
        local px, py = x * SCALE + dx, y * SCALE + dy
        local old = image:getPixel(px, py)
        local pc = app.pixelColor
        local r = math.floor(pc.rgbaR(old) * (1 - a) + c.red * a + 0.5)
        local g = math.floor(pc.rgbaG(old) * (1 - a) + c.green * a + 0.5)
        local b = math.floor(pc.rgbaB(old) * (1 - a) + c.blue * a + 0.5)
        image:drawPixel(px, py, pc.rgba(r, g, b, 255))
      end
    end
  end
  function gc:fillRect(r)
    for y = math.floor(r.y), math.floor(r.y + r.height) - 1 do
      for x = math.floor(r.x), math.floor(r.x + r.width) - 1 do plot(x, y, self.color) end
    end
  end
  function gc:strokeRect(r)
    local x0, y0 = math.floor(r.x), math.floor(r.y)
    local x1, y1 = math.floor(r.x + r.width) - 1, math.floor(r.y + r.height) - 1
    for x = x0, x1 do plot(x, y0, self.color); plot(x, y1, self.color) end
    for y = y0, y1 do plot(x0, y, self.color); plot(x1, y, self.color) end
  end
  function gc:measureText(text) return { width = #text * GLYPH_W, height = GLYPH_H } end
  function gc:fillText(text, x, y)
    -- Text is approximated by a dotted baseline block per glyph.
    for i = 1, #text do
      if text:sub(i, i) ~= " " then
        for gy = 1, GLYPH_H - 2, 2 do plot(x + (i - 1) * GLYPH_W + 1, y + gy, self.color); plot(x + (i - 1) * GLYPH_W + 3, y + gy, self.color) end
      end
    end
  end
  function gc:beginPath() path = {} end
  function gc:moveTo(x, y) path[#path + 1] = { x, y } end
  function gc:lineTo(x, y) path[#path + 1] = { x, y } end
  function gc:closePath() end
  function gc:rect(r) path = { rect = r } end
  function gc:clip() if path.rect then clip = path.rect end end
  function gc:save() stack[#stack + 1] = clip end
  function gc:restore() clip = table.remove(stack) end
  function gc:fill()
    if #path < 3 then return end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(path) do
      minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
      minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
    end
    local function sign(p1, p2, x, y) return (x - p2[1]) * (p1[2] - p2[2]) - (p1[1] - p2[1]) * (y - p2[2]) end
    for y = math.floor(minY), math.ceil(maxY) - 1 do
      for x = math.floor(minX), math.ceil(maxX) - 1 do
        local px, py = x + 0.5, y + 0.5
        local d1, d2, d3 = sign(path[1], path[2], px, py), sign(path[2], path[3], px, py), sign(path[3], path[1], px, py)
        local neg = d1 < 0 or d2 < 0 or d3 < 0
        local pos = d1 > 0 or d2 > 0 or d3 > 0
        if not (neg and pos) then plot(x, y, self.color) end
      end
    end
  end
  function gc:stroke() end
  return gc, image
end

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
