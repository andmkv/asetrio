-- Renders the Light dialog's three custom canvases (layer list, preview,
-- frame strip) with the real paint code, for layout review without the GUI.
-- Native widgets (combos, sliders, buttons) are NOT drawn; text is dots.
-- Usage: aseprite -b --script-param out=<dir> --script tests/render_light.lua
local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = sourcePath:match("^(.*)/tests/[^/]+$") or "."
local function load(path) return dofile(root .. "/" .. path) end
local outDir = app.params.out or app.fs.joinPath(root, "build")
app.fs.makeAllDirectories(outDir)
local SCALE = tonumber(app.params.scale) or 3
local mockGc = load("tests/mock_gc.lua").new(SCALE)

-- Minimal Dialog: records widgets so their onpaint handlers can be called.
local widgets = {}
local function FakeDialog(options)
  local d = { _values = {} }
  local function add(self, t) if t and t.id then widgets[t.id] = t; self._values[t.id] = t.text or t.option or t.value end; return self end
  for _, kind in ipairs({ "label", "button", "check", "radio", "entry", "number", "slider", "combobox", "color",
    "canvas", "file", "separator", "tab", "endtabs" }) do d[kind] = add end
  function d:newrow() return self end
  function d:modify(t) if t.id and widgets[t.id] then for k, v in pairs(t) do widgets[t.id][k] = v end end end
  function d:show() return self end
  function d:close() end
  function d:repaint() end
  return setmetatable(d, { __index = function(self, k)
    if k == "data" then local c = {}; for key, v in pairs(self._values) do c[key] = v end; return c end
    if k == "bounds" then return Rectangle(0, 0, 300, 300) end
  end, __newindex = function(self, k, v) if k == "data" then for key, value in pairs(v) do self._values[key] = value end else rawset(self, k, v) end end })
end
Dialog = FakeDialog

local ctx = {
  color = load("src/color.lua"), modelModule = load("src/model.lua"), persistence = load("src/persistence.lua"),
  aseprite = load("src/aseprite.lua"), source = load("src/source.lua"), session = load("src/session.lua"),
  grid = load("src/grid.lua"), ui = load("src/ui.lua"), dialogs = load("src/dialogs.lua"),
  lightEngine = load("src/light_engine.lua"), lightAseprite = load("src/light_aseprite.lua"),
  lightUI = load("src/light_ui.lua"), lightView = load("src/light_view.lua"),
  lightWidgets = load("src/light_widgets.lua"), lightJob = load("src/light_job.lua"),
  namespace = "palette-trio/palette-trio", preferences = {}, selectedRow = 0, selectedSlot = "base", scroll = 0,
}
ctx.alert = function() return 1 end

local palette = {
  { 24, 20, 37 }, { 122, 54, 60 }, { 224, 122, 54 }, { 232, 178, 84 }, { 120, 176, 70 },
  { 52, 100, 124 }, { 70, 112, 200 }, { 176, 90, 160 },
}
local sprite = Sprite(40, 32)
local pal = Palette(#palette)
for i, c in ipairs(palette) do pal:setColor(i - 1, Color { r = c[1], g = c[2], b = c[3] }) end
sprite:setPalette(pal)

local function disc(radius, color)
  local size = radius * 2 + 1
  local image = Image(size, size, ColorMode.RGB)
  for y = 0, size - 1 do for x = 0, size - 1 do
    if (x - radius) ^ 2 + (y - radius) ^ 2 <= radius ^ 2 then
      image:drawPixel(x, y, app.pixelColor.rgba(color[1], color[2], color[3], 255))
    end
  end end
  return image
end
local function box(w, h, color)
  local image = Image(w, h, ColorMode.RGB)
  for y = 0, h - 1 do for x = 0, w - 1 do image:drawPixel(x, y, app.pixelColor.rgba(color[1], color[2], color[3], 255)) end end
  return image
end

local ground = sprite.layers[1]
ground.name = "Ground"
sprite:deleteCel(ground:cel(1))
for _ = 2, 8 do sprite:newEmptyFrame() end
local ball = sprite:newLayer(); ball.name = "Ball"
local crate = sprite:newLayer(); crate.name = "Crate"
local shadowless = sprite:newLayer(); shadowless.name = "Sky detail"
for frame = 1, 8 do
  sprite:newCel(ground, frame, box(40, 6, palette[5]), Point(0, 26))
  sprite:newCel(ball, frame, disc(7, palette[3]), Point(3 + frame * 2, 6))
  if frame ~= 4 then sprite:newCel(crate, frame, box(10, 10, palette[7]), Point(24, 15)) end
  if frame >= 6 then sprite:newCel(shadowless, frame, box(3, 3, palette[8]), Point(1, 1)) end
end
app.sprite = sprite
app.frame = sprite.frames[3]
ctx.session.load(ctx, sprite)
ctx.ui.open(ctx)  -- closes nothing; just prepares the panel state
ctx.lightUI.open(ctx)
ctx.light.selected = {}
for _, record in ipairs(ctx.light.records) do
  if app.params.only == "crate" then
    if record.name == "Crate" then ctx.light.selected[record.uuid] = true end
  elseif record.name == "Ball" or record.name == "Crate" then ctx.light.selected[record.uuid] = true end
  if record.name == (app.params.only == "crate" and "Crate" or "Ball") then ctx.light.activeUuid = record.uuid end
end
ctx.lightUI.regeneratePreview(ctx)

local function draw(id, w, h)
  local gc, image = mockGc(w, h)
  widgets[id].onpaint({ context = gc })
  return image
end
local W = ctx.lightWidgets
local listW, previewW, previewH = W.Layers.WIDTH, 224, 150
local list = draw("layerList", listW, previewH)
local preview = draw("lightPreview", previewW, previewH)
local stripW = listW + previewW + 4
local strip = draw("frameStrip", stripW, W.Frames.HEIGHT)
local total = Image((listW + previewW + 4) * SCALE, (previewH + 4 + W.Frames.HEIGHT) * SCALE, ColorMode.RGB)
total:clear(app.pixelColor.rgba(212, 202, 188, 255))
total:drawImage(list, Point(0, 0))
total:drawImage(preview, Point((listW + 4) * SCALE, 0))
total:drawImage(strip, Point(0, (previewH + 4) * SCALE))
local out = Sprite(total.width, total.height, ColorMode.RGB)
out.cels[1].image = total
local file = app.fs.joinPath(outDir, "light-dialog-canvases.png")
out:saveAs(file)
print(file, "status: " .. tostring(ctx.light.status))
