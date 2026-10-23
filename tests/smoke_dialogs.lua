-- Headless smoke test: builds every Palette Trio dialog with the real Dialog
-- API in batch mode and drives the main actions. Catches Lua errors in GUI-only
-- code paths. It cannot verify layout or appearance.
-- Usage: aseprite -b --script tests/smoke_dialogs.lua
local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = sourcePath:match("^(.*)/tests/[^/]+$") or "."
local function load(path) return dofile(root .. "/" .. path) end

local ctx = {
  color = load("src/color.lua"), modelModule = load("src/model.lua"),
  persistence = load("src/persistence.lua"), aseprite = load("src/aseprite.lua"),
  source = load("src/source.lua"), session = load("src/session.lua"),
  grid = load("src/grid.lua"), ui = load("src/ui.lua"), dialogs = load("src/dialogs.lua"),
  menu = load("src/menu.lua"), about = load("src/about.lua"),
  lightEngine = load("src/light_engine.lua"), lightAseprite = load("src/light_aseprite.lua"),
  lightUI = load("src/light_ui.lua"),
  namespace = "palette-trio/palette-trio", preferences = {},
  selectedRow = 0, selectedSlot = "base", scroll = 0,
}
-- Modal alerts would block/abort in batch; answer the first button.
ctx.alert = function(t)
  print("  # alert: " .. (type(t.text) == "table" and table.concat(t.text, " | ") or tostring(t.text)))
  return 1
end

-- Dialog() returns nil in batch mode, so substitute a strict fake that
-- validates ids, modify() targets and data keys the way the code uses them.
local VALUE_KEY = { label = "text", entry = "text", number = "text", button = "selected",
  check = "selected", radio = "selected", slider = "value", combobox = "option",
  color = "color", file = "filename", canvas = nil, separator = nil }
local dialogs = {}
local function FakeDialog(options)
  local d = { _widgets = {}, _values = {}, _options = options or {}, _open = false }
  dialogs[#dialogs + 1] = d
  local function add(kind)
    return function(self, t)
      t = t or {}
      if t.id then
        assert(not self._widgets[t.id], "duplicate widget id " .. t.id)
        self._widgets[t.id] = { kind = kind, props = t }
        local key = VALUE_KEY[kind]
        if key then self._values[t.id] = t[key] end
        if kind == "button" then self._values[t.id] = false end
      end
      return self
    end
  end
  for _, kind in ipairs({ "label", "button", "check", "radio", "entry", "number", "slider",
    "combobox", "color", "canvas", "file", "separator", "tab", "endtabs", "link" }) do
    d[kind] = add(kind)
  end
  function d:newrow() return self end
  function d:modify(t)
    assert(t.id and self._widgets[t.id], "modify() of unknown widget id " .. tostring(t.id))
    if t.visible ~= nil then VisibilityToggles = (VisibilityToggles or 0) + 1 end
    for k, v in pairs(t) do self._widgets[t.id].props[k] = v end
    local key = VALUE_KEY[self._widgets[t.id].kind]
    if key and t[key] ~= nil then self._values[t.id] = t[key] end
  end
  function d:show(opts)
    if opts and opts.bounds then rawset(self, "_bounds", opts.bounds) end
    rawset(self, "_shows", (rawget(self, "_shows") or 0) + 1)
    self._open = true
    if FakeShowHook then FakeShowHook(self) end
    return self
  end
  function d:close()
    if self._open and self._options.onclose then self._open = false; self._options.onclose() end
    self._open = false
  end
  function d:repaint() end
  function d:widget(id) return self._widgets[id] end
  return setmetatable(d, {
    __index = function(self, key)
      if key == "data" then
        local copy = {}
        for k, v in pairs(rawget(self, "_values")) do copy[k] = v end
        return copy
      elseif key == "bounds" then
        return rawget(self, "_bounds") or Rectangle(100, 100, 300, 320)
      end
    end,
    __newindex = function(self, key, value)
      if key == "data" then
        for k, v in pairs(value) do
          assert(rawget(self, "_widgets")[k], "data key without widget: " .. tostring(k))
          rawget(self, "_values")[k] = v
        end
      elseif key == "bounds" then
        BoundsWrites = (BoundsWrites or 0) + 1
        rawset(self, "_bounds", value)
      else
        rawset(self, key, value)
      end
    end,
  })
end
Dialog = FakeDialog

-- Minimal GraphicsContext for invoking canvas callbacks.
local function stubGc(width, height)
  local gc = { width = width, height = height }
  local noop = function() end
  for _, name in ipairs({ "fillRect", "strokeRect", "fillText", "beginPath", "moveTo", "lineTo",
    "closePath", "fill", "stroke", "rect", "clip", "save", "restore", "drawImage", "roundedRect" }) do
    gc[name] = noop
  end
  function gc:measureText(text) return { width = #text * 5, height = 8 } end
  return gc
end
local function fire(dlg, id, event, ev)
  local widget = dlg:widget(id)
  assert(widget, "no widget " .. id)
  local handler = widget.props[event]
  assert(handler, id .. " has no " .. event)
  return handler(ev)
end

local passed, failed = 0, 0
local function step(name, fn)
  local ok, reason = pcall(fn)
  if ok then passed = passed + 1; print("ok - " .. name)
  else failed = failed + 1; print("not ok - " .. name .. "\n  " .. tostring(reason)) end
end

local sprite = Sprite(12, 12)
local palette = Palette(4)
local colors = { { 30, 30, 40 }, { 180, 60, 50 }, { 60, 140, 200 }, { 230, 200, 90 } }
for i, c in ipairs(colors) do palette:setColor(i - 1, Color { r = c[1], g = c[2], b = c[3] }) end
sprite:setPalette(palette)
local image = sprite.cels[1].image
for y = 2, 9 do for x = 2, 9 do image:drawPixel(x, y, app.pixelColor.rgba(180, 60, 50, 255)) end end

local function noBoundsWrites(label, fn)
  local before = BoundsWrites or 0
  fn()
  assert((BoundsWrites or 0) == before, label .. " changed window bounds")
end

step("load session: every native palette color is a family", function()
  ctx.session.load(ctx, sprite); assert(#ctx.model.rows == 4)
end)
step("open main panel: a single canvas, no permanent buttons", function()
  ctx.ui.open(ctx)
  assert(ctx.dialog)
  local count = 0
  for id, w in pairs(ctx.dialog._widgets) do
    count = count + 1
    assert(w.kind == "canvas", "unexpected permanent widget " .. id)
  end
  assert(count == 1)
  assert(ctx.dialog._options.title == "Trio", "short title keeps the window narrow")
end)
step("opening again does not create a second window", function()
  local first = ctx.dialog
  local before = #dialogs
  ctx.ui.open(ctx)
  assert(ctx.dialog == first and #dialogs == before)
end)
local function toolbarItem(id, width)
  for _, item in ipairs(ctx.ui.toolbarItems(ctx, width)) do
    if item.id == id then return item end
  end
end
local function menuRun(id)
  fire(ctx.dialog, "grid", "onmousedown", { x = toolbarItem("menu").x + 2, y = 4, button = MouseButton.LEFT })
  local menu = ctx.menuDialog
  assert(menu, "... opens the menu")
  fire(menu, "menu", "onpaint", { context = stubGc(ctx.menu.WIDTH, 300) })
  local positions = ctx.menu.layout(ctx.menuItems)
  for i, item in ipairs(ctx.menuItems) do
    if item.id == id then
      assert(item.enabled, id .. " is disabled")
      fire(menu, "menu", "onmousemove", { x = 20, y = positions[i].y + 2 })
      fire(menu, "menu", "onmousedown", { x = 20, y = positions[i].y + 2, button = MouseButton.LEFT })
      assert(ctx.menuDialog == nil, "menu closes after an action")
      return
    end
  end
  error("menu item not found: " .. id)
end

step("paint at 3 and 5 shades, default, very narrow and wide widths", function()
  for _, width in ipairs({ 24, 40, ctx.grid.WIDTH, 220 }) do
    for _, count in ipairs({ 3, 5 }) do
      ctx.model.setShadeCount(ctx.model, count)
      fire(ctx.dialog, "grid", "onpaint", { context = stubGc(width, 200) })
      assert(ctx.canvasWidth == width)
      local light, menu = toolbarItem("light", width), toolbarItem("menu", width)
      assert(light.x >= 1 and menu.x > light.x, "toolbar coherent at width " .. width)
    end
  end
  ctx.model.setShadeCount(ctx.model, 3)
  fire(ctx.dialog, "grid", "onpaint", { context = stubGc(ctx.grid.WIDTH, 200) })
end)
step("toolbar has only Light and More; menu toggles open/closed and positions beside the panel", function()
  assert(#ctx.grid.toolbar(ctx.grid.WIDTH) == 2)
  rawset(ctx.dialog, "_bounds", Rectangle(500, 100, 90, 300))
  fire(ctx.dialog, "grid", "onmousedown", { x = toolbarItem("menu").x + 2, y = 4, button = MouseButton.LEFT })
  local menu = ctx.menuDialog
  assert(menu)
  local b = menu.bounds
  assert(b.x == 592 and b.y == 100, "menu placed right of the panel: " .. b.x .. "," .. b.y)
  fire(ctx.dialog, "grid", "onmousedown", { x = toolbarItem("menu").x + 2, y = 4, button = MouseButton.LEFT })
  assert(ctx.menuDialog == nil, "clicking ... again closes the menu")
  ctx.menu.open(ctx)
  fire(ctx.menuDialog, "menu", "onkeydown", { code = "Escape" })
  assert(ctx.menuDialog == nil, "Esc closes the menu")
end)
step("menu: 3/5 shades toggle persists without touching bounds", function()
  noBoundsWrites("shade toggle", function()
    menuRun("shades5")
    assert(ctx.model.shadeCount == 5)
    menuRun("shades3")
    assert(ctx.model.shadeCount == 3)
  end)
  assert(sprite.properties(ctx.namespace).paletteTrio, "shade toggle stores the families")
end)
step("menu: About shows the author, version and both links", function()
  ctx.version = ctx.about.readVersion(root)
  assert(ctx.version and ctx.version:match("^0%.3"), "version read from package.json: " .. tostring(ctx.version))
  menuRun("about")
  local about = ctx.aboutDialog
  assert(about, "About opens from the menu")
  assert(about:widget("version").props.text:match((ctx.version:gsub("%.", "%%."))))
  assert(about:widget("author").props.text:match("Andrey Makeev"))
  local site, repo = about:widget("website").props, about:widget("github").props
  assert(site.url == "https://smallhall.net" and site.text == "Smallhall.net - More apps and games")
  assert(repo.url:match("^https://github%.com/andmkv/asetrio$"))
  ctx.about.open(ctx)
  assert(#dialogs > 0)
  fire(about, "close", "onclick")
  assert(ctx.aboutDialog == nil)
end)
step("menu: disabled items do nothing", function()
  ctx.menu.open(ctx)
  local positions = ctx.menu.layout(ctx.menuItems)
  for i, item in ipairs(ctx.menuItems) do
    if item.id == "missing" then
      assert(not item.enabled, "nothing missing yet")
      fire(ctx.menuDialog, "menu", "onmousedown", { x = 20, y = positions[i].y + 2, button = MouseButton.LEFT })
      assert(ctx.menuDialog ~= nil, "a disabled item keeps the menu open")
    end
  end
  ctx.menu.close(ctx)
end)
step("grid: click paint color, right-click background, double-click edits; no bounds change", function()
  noBoundsWrites("selection", function()
    local dlg = ctx.dialog
    local layout = ctx.ui.layout(ctx)
    local columns = layout.columns
    local y = ctx.ui.gridTop(ctx) + 2
    fire(dlg, "grid", "onmousedown", { x = columns[3].x + 1, y = y, button = MouseButton.LEFT })
    local light = ctx.model.rows[1].shades.highlight.color
    assert(app.fgColor.red == light.r and app.fgColor.green == light.g, "left click sets paint color")
    assert(ctx.selectedRow == 1 and ctx.selectedSlot == "highlight")
    fire(dlg, "grid", "onmousedown", { x = columns[2].x + 1, y = y, button = MouseButton.RIGHT })
    assert(app.bgColor.red == ctx.model.rows[1].base.r, "right click sets background")
    assert(ctx.selectedSlot == "highlight", "right click does not move the edit selection")
    fire(dlg, "grid", "ondblclick", { x = columns[2].x + 1, y = y, button = MouseButton.LEFT })
    assert(ctx.editorDialog, "double-click opens the editor")
    fire(dlg, "grid", "onwheel", { deltaY = 3 })
    fire(dlg, "grid", "onmousemove", { x = toolbarItem("light").x + 1, y = 3 })
    assert(ctx.hoverTool == "light")
  end)
end)
step("editor: HEX/picker edits, pin, restore auto, revert base", function()
  local editor = ctx.editorDialog
  ctx.ui.select(ctx, 1, "shadow")
  local data = editor.data
  data.hex = "#0A0B0C"
  editor.data = data
  fire(editor, "hex", "onchange")
  ctx.dialogs.flushPending(ctx)
  local shade = ctx.model.rows[1].shades.shadow
  assert(shade.color.r == 10 and shade.locked and shade.override, "HEX edit pins the shade")
  fire(editor, "auto", "onclick")
  assert(not shade.locked and not shade.override, "Restore auto")
  fire(editor, "pin", "onclick")
  assert(shade.locked, "Pin")
  ctx.ui.select(ctx, 1, "base")
  data = editor.data
  data.color = Color { r = 200, g = 100, b = 50 }
  editor.data = data
  fire(editor, "color", "onchange")
  ctx.dialogs.flushPending(ctx)
  assert(ctx.model.rows[1].base.r == 200)
  fire(editor, "revert", "onclick")
  assert(ctx.model.rows[1].base.r == 30, "reverted to palette color")
  fire(editor, "done", "onclick")
  assert(ctx.editorDialog == nil)
end)
step("palette change while open: sync repaints, never resizes", function()
  noBoundsWrites("palette sync", function()
    local p = Palette(sprite.palettes[1])
    p:resize(5)
    p:setColor(4, Color { r = 9, g = 99, b = 199 })
    sprite:setPalette(p)
    assert(ctx.session.onSpriteChanged(ctx))
    ctx.ui.refresh(ctx)
    assert(#ctx.model.rows == 5)
  end)
end)
step("menu: add current color, choose subset, use full palette, import from artwork", function()
  app.fgColor = Color { r = 1, g = 120, b = 3 }
  menuRun("addCurrent")
  assert(#ctx.model.rows == 6 and ctx.model.rows[6].link == nil, "custom family added")
  FakeShowHook = function(dlg)
    if dlg._options.title ~= "Choose Palette Colors" then return end
    FakeShowHook = nil
    fire(dlg, "colors", "onpaint", { context = stubGc(224, 28) })
    fire(dlg, "none", "onclick")
    fire(dlg, "colors", "onmousedown", { x = 1, y = 1, button = MouseButton.LEFT })
    fire(dlg, "colors", "onmousedown", { x = 15, y = 1, button = MouseButton.LEFT })
    assert(dlg.data.count:match("^2 of 5"), dlg.data.count)
    local d = dlg.data
    d.ok = true
    dlg.data = d
  end
  menuRun("choose")
  assert(#ctx.model.rows == 3, "2 palette families + 1 custom, got " .. #ctx.model.rows)
  menuRun("full")
  assert(#ctx.model.rows == 6, "full palette restored, custom kept")
  FakeShowHook = function(dlg)
    if dlg._options.title ~= "Add Colors From Artwork" then return end
    FakeShowHook = nil
    fire(dlg, "all", "onclick")
    local d = dlg.data
    d.ok = true
    dlg.data = d
  end
  menuRun("artwork")
  assert(#ctx.model.rows == 6, "artwork only contains existing bases, nothing added")
end)
step("menu: shade settings sliders regenerate and persist", function()
  menuRun("settings")
  local options = ctx.optionsDialog
  assert(options)
  local data = options.data
  data.shadowStrength = 60
  options.data = data
  fire(options, "shadowStrength", "onchange")
  fire(options, "shadowStrength", "onrelease")
  assert(math.abs(ctx.model.settings.shadowStrength - 0.6) < 1e-9)
  fire(options, "defaults", "onclick")
end)
step("menu: write to palette (append) records provenance in the same step", function()
  local before = #sprite.palettes[1]
  menuRun("write")
  assert(#sprite.palettes[1] > before, "palette grew")
  assert(#ctx.model.rows == 6, "written shades did not become families: " .. #ctx.model.rows)
  assert(next(ctx.model.generated) ~= nil)
end)
step("empty-state paint (no sprite / no colors)", function()
  local saved = ctx.model
  ctx.model = ctx.modelModule.new(ctx.color)
  fire(ctx.dialog, "grid", "onpaint", { context = stubGc(ctx.grid.WIDTH, 80) })
  ctx.model = saved
end)
step("Light opens only from the panel toolbar and refreshes in place", function()
  fire(ctx.dialog, "grid", "onmousedown", { x = toolbarItem("light").x + 2, y = 4, button = MouseButton.LEFT })
  assert(ctx.lightDialog, "sun icon opens Light")
  local light = ctx.lightDialog
  assert(ctx.lightUI.regeneratePreview(ctx), tostring(ctx.light.status) .. " / " .. tostring(ctx.light.message))
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local count = #dialogs
  noBoundsWrites("Light refresh", function()
    fire(light, "refreshLayers", "onclick")
    ctx.lightUI.onSpriteChange(ctx)
    ctx.lightUI.onUndo(ctx)
  end)
  assert(ctx.lightDialog == light and #dialogs == count, "no rebuild / duplicate Light window")
end)
step("Light auto-detects the family without relying on the paint color", function()
  app.fgColor = Color { r = 3, g = 3, b = 3 }
  ctx.selectedRow = 0
  assert(ctx.lightUI.regeneratePreview(ctx))
  assert(ctx.light.detection.index == 2, "the red square is family 2, got " .. tostring(ctx.light.detection.index))
  assert(ctx.light.status:match("^Auto: family 2"), ctx.light.status)
  assert(ctx.lightDialog.data.family == ctx.lightUI.AUTO_FAMILY)
end)
step("Light eyedropper picks a family from a shade color in the preview", function()
  local light = ctx.lightDialog
  fire(light, "pick", "onclick")
  assert(ctx.light.picking and light:widget("pick").props.text:match("Picking"))
  local info = ctx.light.previewBounds
  -- The source cel holds the red square at (2..9, 2..9); paint one shade pixel.
  local shade = ctx.model.rows[2].shades.highlight.color
  local cel = sprite.layers[1]:cel(1)
  cel.image:drawPixel(5, 5, app.pixelColor.rgba(shade.r, shade.g, shade.b, 255))
  assert(ctx.lightUI.regeneratePreview(ctx))
  info = ctx.light.previewBounds
  local x = info.x + (5 + 0.5) * info.scale
  local y = info.y + (5 + 0.5) * info.scale
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(not ctx.light.picking, "pick mode ends after one click")
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id, "picked family 2 from its highlight")
  assert(light.data.family:match("^2 #"), light.data.family)
  assert(ctx.light.status:match("Family 2") or ctx.light.status:match("Picked family 2"), ctx.light.status)
  -- Clicking transparent space explains instead of changing the family.
  fire(light, "lightPreview", "onmousedown", { x = info.x + 0.5 * info.scale, y = info.y + 0.5 * info.scale, button = MouseButton.RIGHT })
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id)
  -- A non-family color explains and keeps the family.
  cel.image:drawPixel(6, 6, app.pixelColor.rgba(10, 250, 10, 255))
  ctx.lightUI.regeneratePreview(ctx)
  info = ctx.light.previewBounds
  fire(light, "lightPreview", "onmousedown", { x = info.x + 6.5 * info.scale, y = info.y + 6.5 * info.scale, button = MouseButton.RIGHT })
  assert(ctx.light.status:match("not a Palette Trio color"), ctx.light.status)
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id)
  -- Back to automatic via the Family list.
  local data = light.data
  data.family = ctx.lightUI.AUTO_FAMILY
  light.data = data
  fire(light, "family", "onchange")
  assert(ctx.light.layer.familyRowId == nil)
end)
step("Light new-layer output", function()
  fire(ctx.lightDialog, "applyLight", "onclick")
  assert(#sprite.layers == 2, "output layer created")
end)
step("Light replace-source output asks first and changes only the source cel", function()
  local light = ctx.lightDialog
  local data = light.data
  data.output = "Replace source"
  light.data = data
  fire(light, "output", "onchange")
  assert(light:widget("applyLight").props.text:match("Replace"))
  local layer = sprite.layers[1]
  local before = layer:cel(1).image.bytes
  local asked = false
  local saved = ctx.alert
  ctx.alert = function(t)
    asked = true
    local text = table.concat(t.text, " ")
    assert(text:match("NOT saved in the file") and text:match("Keep a copy"), "session-only warning shown")
    return 2
  end
  fire(light, "applyLight", "onclick")
  assert(asked and layer:cel(1).image.bytes == before, "Cancel keeps pixels")
  ctx.alert = saved
  fire(light, "applyLight", "onclick")
  assert(layer:cel(1).image.bytes ~= before, "Replace changed the source cel")
  assert(#sprite.layers == 2, "no extra layer")
  local after = layer:cel(1).image.bytes
  fire(light, "applyLight", "onclick")
  assert(layer:cel(1).image.bytes == after, "repeat Apply does not compound")
end)
step("Light with no families shows recovery", function()
  local saved = ctx.model
  ctx.model = ctx.modelModule.new(ctx.color)
  ctx.lightUI.regeneratePreview(ctx)
  assert(ctx.light.status == "No shade families", tostring(ctx.light.status))
  ctx.model = saved
end)
step("bounds: saved on close, restored once on reopen", function()
  rawset(ctx.dialog, "_bounds", Rectangle(40, 50, 180, 300))
  ctx.dialog:close()
  assert(ctx.dialog == nil and ctx.colorsDialog == nil and ctx.optionsDialog == nil, "secondary windows closed")
  local b = ctx.preferences.bounds
  assert(b and b.width == 180 and b.height == 300, "bounds saved")
  local writes = BoundsWrites or 0
  ctx.ui.open(ctx)
  local restored = ctx.dialog.bounds
  assert(restored.x == 40 and restored.width == 180 and restored.height == 300, "bounds restored via show{bounds}")
  assert((BoundsWrites or 0) == writes, "restoring does not assign bounds after show")
  ctx.ui.refresh(ctx)
  assert((BoundsWrites or 0) == writes)
  ctx.preferences.bounds = { x = 1, y = 1, width = 10, height = 10 }
  assert(ctx.ui.savedBounds(ctx) == nil, "degenerate bounds are ignored")
end)
step("no widget visibility toggles (relayouts) anywhere in the session", function()
  assert((VisibilityToggles or 0) == 0, "visibility toggled " .. tostring(VisibilityToggles) .. " times")
end)
step("close all", function()
  ctx.dialogs.closeAll(ctx)
  if ctx.lightDialog then ctx.lightDialog:close() end
  if ctx.dialog then ctx.dialog:close() end
end)
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error(failed .. " smoke step(s) failed") end
