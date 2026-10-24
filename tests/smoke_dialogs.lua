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
  lightUI = load("src/light_ui.lua"), lightView = load("src/light_view.lua"),
  lightWidgets = load("src/light_widgets.lua"), lightJob = load("src/light_job.lua"),
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
    "combobox", "color", "canvas", "file", "separator", "tab", "endtabs" }) do
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
    rawset(self, "_showOptions", opts or {})
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
  ctx.version = ctx.about.VERSION
  local manifest = assert(io.open(root .. "/package.json")):read("a"):match('"version"%s*:%s*"([^"]+)"')
  assert(ctx.version == manifest, "About.VERSION " .. ctx.version .. " == package.json " .. tostring(manifest))
  menuRun("about")
  local about = ctx.aboutDialog
  assert(about, "About opens from the menu")
  assert(about:widget("version").props.text:match((ctx.version:gsub("%.", "%%."))))
  assert(about:widget("author").props.text:match("Andrey Makeev"))
  assert(about:widget("website").props.text == "Smallhall.net - More apps and games")
  local opened = {}
  ctx.launch = function(url) opened[#opened + 1] = url; return true end
  fire(about, "website", "onclick")
  fire(about, "github", "onclick")
  assert(opened[1] == "https://smallhall.net", tostring(opened[1]))
  assert(opened[2] == "https://github.com/andmkv/asetrio", tostring(opened[2]))
  local alerted = false
  local savedAlert = ctx.alert
  ctx.alert = function(t) alerted = table.concat(t.text, " "):match("smallhall") ~= nil; return 1 end
  ctx.launch = function() error("no browser") end
  fire(about, "website", "onclick")
  assert(alerted, "if the browser cannot open, the address is shown")
  ctx.alert, ctx.launch = savedAlert, nil
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
  assert(ctx.light.status:match("^Auto family"), ctx.light.status)
  assert(ctx.light.activeFamily and #ctx.light.activeFamily.colors == ctx.light.shared.levels)
end)
step("Light layout: compact rows, Family label on Pick/Auto, scrollbars when it does not fit", function()
  local light = ctx.lightDialog
  assert(light:widget("family") == nil and light:widget("familyStrip") == nil, "no HEX list, no separate strip row")
  assert(light:widget("pick").props.label == "Family", "Family label sits on the Pick/Auto row")
  assert(light:widget("autoFamily").props.enabled ~= false, "Auto is never greyed out")
  assert(light:widget("excludedColors") == nil, "no HEX entry for kept colors")
  assert(light:widget("keepAdd").props.label == "Keep" and light:widget("keepClear").props.enabled == false)
  assert(light:widget("openPalette").props.text == "Families...", "the Colors button is named for what it does")
  for _, gone in ipairs({ "cylinderAxis", "bevel", "curvature", "closeLight" }) do
    assert(light:widget(gone) == nil, gone .. " removed")
  end
  assert(light:widget("material").props.label == nil, "Material shares the Shape row")
  assert(light:widget("dither").props.label == nil, "Dither shares the Shades row")
  assert(light:widget("separateComponents").props.label == nil, "both checkboxes share a row")
  assert(light._showOptions.autoscrollbars == true, "scrollbars appear when the window does not fit")
  -- The family strip and the auto/picked word are drawn in the preview.
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
end)
step("Light Shape list: cylinder orientation and one Form slider", function()
  local light = ctx.lightDialog
  local layer = ctx.light.layer
  local function choose(label)
    local data = light.data
    data.shape = label
    light.data = data
    fire(light, "shape", "onchange")
  end
  choose("Cylinder (vertical)")
  assert(layer.shape == "Cylinder" and layer.cylinderAxis == "Vertical")
  local form = light:widget("form").props
  assert(form.enabled == true and form.min == 25 and form.max == 300, "Form = curvature for cylinders")
  local data = light.data
  data.form = 150
  light.data = data
  fire(light, "form", "onrelease")
  assert(math.abs(layer.curvature - 1.5) < 1e-9)
  local bevel = layer.bevel
  choose("Box (bevel)")
  assert(layer.shape == "Box / Beveled rectangle")
  assert(layer.bevel == bevel, "switching shape does not reinterpret the old slider value")
  form = light:widget("form").props
  assert(form.min == 1 and form.max == 24 and form.value == math.floor(bevel + 0.5), "Form = bevel for boxes")
  choose("Cylinder (horizontal)")
  assert(layer.cylinderAxis == "Horizontal")
  choose("Sphere")
  assert(layer.shape == "Round / Sphere" and light:widget("form").props.enabled == false, "no Form for spheres")
  data = light.data
  data.dither = "No dither"
  light.data = data
  fire(light, "dither", "onchange")
  assert(ctx.light.shared.dither == "Off", "No dither is stored as Off")
end)
step("Light eyedropper picks a family from a shade color; Auto resets it", function()
  local light = ctx.lightDialog
  fire(light, "pick", "onclick")
  assert(ctx.light.picking and light:widget("pick").props.text:match("Picking"))
  -- The source cel holds the red square at (2..9, 2..9); paint one shade pixel.
  local shade = ctx.model.rows[2].shades.highlight.color
  local cel = sprite.layers[1]:cel(1)
  cel.image:drawPixel(5, 5, app.pixelColor.rgba(shade.r, shade.g, shade.b, 255))
  ctx.lightUI.invalidate(ctx)  -- the sprite "change" event does this in Aseprite
  assert(ctx.lightUI.regeneratePreview(ctx))
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local t = ctx.light.viewT
  local function at(px, py) return ctx.lightView.toScreen(t, px + 0.5, py + 0.5) end
  local x, y = at(5, 5)
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(not ctx.light.picking, "pick mode ends after one click")
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id, "picked family 2 from its highlight")
  assert(ctx.light.status:match("Picked"), ctx.light.status)
  assert(light:widget("autoFamily").props.enabled ~= false)
  -- Clicking transparent space explains instead of changing the family.
  x, y = at(0, 0)
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.RIGHT })
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id)
  -- A non-family color explains and keeps the family.
  cel.image:drawPixel(6, 6, app.pixelColor.rgba(10, 250, 10, 255))
  ctx.lightUI.invalidate(ctx)
  ctx.lightUI.regeneratePreview(ctx)
  x, y = at(6, 6)
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.RIGHT })
  assert(ctx.light.status:match("not in any family"), ctx.light.status)
  assert(ctx.light.layer.familyRowId == ctx.model.rows[2].id)
  fire(light, "autoFamily", "onclick")
  assert(ctx.light.layer.familyRowId == nil, "Auto returns to detection")
end)
step("Light family tag in the preview is a button: click to pick, click again for Auto", function()
  local light = ctx.lightDialog
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local tag = ctx.light.familyTag
  assert(tag and tag.width > 40 and tag.height > 8, "the tag has a clickable area")
  -- It is clickable from the preview whether the family is automatic or picked.
  ctx.light.layer.familyRowId = nil
  ctx.lightUI.regeneratePreview(ctx)
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  tag = ctx.light.familyTag
  local cx, cy = tag.x + 3, tag.y + 3
  fire(light, "lightPreview", "onmousemove", { x = cx, y = cy })
  assert(ctx.light.hoverTag == true, "hover is shown")
  fire(light, "lightPreview", "onmousedown", { x = cx, y = cy, button = MouseButton.LEFT })
  assert(ctx.light.picking == true and not ctx.light.dragging, "Auto tag starts picking, it does not move the light")
  assert(light:widget("pick").props.text == "Picking...")
  -- Pick a family by clicking an object pixel, then the tag says Picked and goes back to Auto.
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local t = ctx.light.viewT
  local x, y = ctx.lightView.toScreen(t, 5.5, 5.5)
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(ctx.light.layer.familyRowId ~= nil and not ctx.light.picking, "picked")
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  tag = ctx.light.familyTag
  fire(light, "lightPreview", "onmousedown", { x = tag.x + 3, y = tag.y + 3, button = MouseButton.LEFT })
  assert(ctx.light.layer.familyRowId == nil and not ctx.light.picking, "clicking the Picked tag returns to Auto")
  assert(ctx.light.status:match("automatically"), ctx.light.status)
  -- The Auto button works too, also while picking.
  fire(light, "pick", "onclick")
  fire(light, "autoFamily", "onclick")
  assert(not ctx.light.picking and ctx.light.layer.familyRowId == nil)
end)
step("Light point light: drag anywhere (also outside the object), stored in sprite coordinates", function()
  local light = ctx.lightDialog
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local t = ctx.light.viewT
  -- Drag to a point far outside the 12x12 sprite (x = -10, y = 20).
  local sx, sy = ctx.lightView.toScreen(t, -9.5, 20.5)
  fire(light, "lightPreview", "onmousedown", { x = sx, y = sy, button = MouseButton.LEFT })
  assert(ctx.light.dragging)
  fire(light, "lightPreview", "onmousemove", { x = sx, y = sy })
  fire(light, "lightPreview", "onmouseup", { x = sx, y = sy, button = MouseButton.LEFT })
  assert(ctx.light.shared.lightX == -10 and ctx.light.shared.lightY == 20,
    "light at " .. tostring(ctx.light.shared.lightX) .. "," .. tostring(ctx.light.shared.lightY))
  local saved = ctx.lightAseprite.loadShared(sprite, ctx.namespace)
  assert(saved.lightX == ctx.light.shared.lightX and saved.lightY == ctx.light.shared.lightY, "saved on the sprite")
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
end)
step("Light preview: wheel zoom keeps the point under the cursor, Alt-drag pans, double-click fits", function()
  local light = ctx.lightDialog
  local View = ctx.lightView
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local before = ctx.light.viewT
  local cx, cy = View.toCel(before, 60, 40)
  local lightBefore = { ctx.light.shared.lightX, ctx.light.shared.lightY }
  fire(light, "lightPreview", "onwheel", { x = 60, y = 40, deltaY = -1 })
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local after = ctx.light.viewT
  assert(after.scale > before.scale, "wheel up zooms in")
  local ax, ay = View.toCel(after, 60, 40)
  assert(math.abs(ax - cx) < 1e-6 and math.abs(ay - cy) < 1e-6, "zoom keeps the point under the cursor")
  fire(light, "lightPreview", "onmousedown", { x = 100, y = 100, button = MouseButton.LEFT, altKey = true })
  fire(light, "lightPreview", "onmousemove", { x = 130, y = 90 })
  fire(light, "lightPreview", "onmouseup", { x = 130, y = 90 })
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  assert(math.abs(ctx.light.viewT.originX - (after.originX + 30)) < 1e-6, "Alt-drag pans")
  assert(ctx.light.shared.lightX == lightBefore[1] and ctx.light.shared.lightY == lightBefore[2], "panning does not move the light")
  fire(light, "lightPreview", "onmousedown", { x = 20, y = 20, button = MouseButton.MIDDLE })
  fire(light, "lightPreview", "onmousemove", { x = 25, y = 20 })
  fire(light, "lightPreview", "onmouseup", { x = 25, y = 20 })
  assert(ctx.light.view.panX ~= 0)
  -- Double-click: the first click moved the light; dblclick restores it and fits.
  fire(light, "lightPreview", "onmousedown", { x = 50, y = 50, button = MouseButton.LEFT })
  fire(light, "lightPreview", "onmouseup", { x = 50, y = 50, button = MouseButton.LEFT })
  fire(light, "lightPreview", "ondblclick", { x = 50, y = 50, button = MouseButton.LEFT })
  assert(ctx.light.view.zoom == 1 and ctx.light.view.panX == 0 and ctx.light.view.panY == 0, "fit")
  assert(ctx.light.shared.lightX == lightBefore[1] and ctx.light.shared.lightY == lightBefore[2], "double-click does not move the light")
end)
step("Light Height and Falloff sliders change the preview and are saved", function()
  local light = ctx.lightDialog
  assert(light:widget("lightElevation") == nil, "Elevation replaced by Height")
  local data = light.data
  data.lightHeight = 7
  data.falloff = 80
  light.data = data
  fire(light, "lightHeight", "onchange")
  fire(light, "lightHeight", "onrelease")
  assert(ctx.light.shared.lightHeight == 7 and ctx.light.shared.falloff == 80)
  local saved = ctx.lightAseprite.loadShared(sprite, ctx.namespace)
  assert(saved.lightHeight == 7 and saved.falloff == 80)
end)
step("Light Colors... always opens the palette color chooser and refreshes the preview", function()
  local light = ctx.lightDialog
  local before = #ctx.model.rows
  local opened = 0
  FakeShowHook = function(dlg)
    if dlg._options.title ~= "Choose Palette Colors" then return end
    opened = opened + 1
    FakeShowHook = nil
    fire(dlg, "none", "onclick")
    fire(dlg, "colors", "onmousedown", { x = 1, y = 1, button = MouseButton.LEFT })
    local d = dlg.data
    d.ok = true
    dlg.data = d
  end
  fire(light, "openPalette", "onclick")
  assert(opened == 1, "the chooser opens even though families already exist")
  assert(#ctx.model.rows < before, "applying the choice changed the families: " .. #ctx.model.rows)
  assert(ctx.lightDialog == light and ctx.light.previewImage ~= nil or ctx.light.status ~= nil, "Light stays open")
  -- Restore all palette colors for the following steps.
  ctx.session.useFullPalette(ctx)
  assert(#ctx.model.rows >= before)
  ctx.lightUI.regeneratePreview(ctx)
end)
step("Light Material: Glossy regenerates and is saved on the layer", function()
  local light = ctx.lightDialog
  assert(light:widget("material"), "Material control exists")
  local data = light.data
  data.material = "Glossy"
  light.data = data
  fire(light, "material", "onchange")
  assert(ctx.light.layer.material == "Glossy")
  assert(ctx.lightAseprite.loadLayerSettings(sprite.layers[1], ctx.namespace).material == "Glossy", "saved on the layer")
  data = light.data
  data.material = "Matte"
  light.data = data
  fire(light, "material", "onchange")
  assert(ctx.light.layer.material == "Matte")
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
-- A second document: 3 frames, two object layers ("Back", "Front"; Front has
-- no cel on frame 3), used by the multi-layer / multi-frame steps below.
local multi, multiBack, multiFront
local function square(size, color)
  local image = Image(size, size, ColorMode.RGB)
  for y = 0, size - 1 do for x = 0, size - 1 do
    image:drawPixel(x, y, app.pixelColor.rgba(color[1], color[2], color[3], 255))
  end end
  return image
end
local function layerRow(name)
  local W = ctx.lightWidgets.Layers
  for display = 1, #ctx.light.records do
    local record = ctx.light.records[#ctx.light.records - display + 1]
    if record.name == name then return display, record end
  end
end
local function clickLayer(name, kind)
  local W = ctx.lightWidgets.Layers
  local display = layerRow(name)
  local x = kind == "box" and (W.PAD + 2) or 50
  fire(ctx.lightDialog, "layerList", "onmousedown",
    { x = x, y = W.rowTop(display, ctx.light.layerScroll or 0) + 3, button = MouseButton.LEFT })
end
local function checked()
  local names = {}
  for _, record in ipairs(ctx.lightUI.selectedRecords(ctx)) do names[#names + 1] = record.name end
  return table.concat(names, ",")
end

step("multi-layer sprite: Light lists every layer and starts with one checked", function()
  multi = Sprite(16, 16)
  local palette = Palette(#colors)
  for i, c in ipairs(colors) do palette:setColor(i - 1, Color { r = c[1], g = c[2], b = c[3] }) end
  multi:setPalette(palette)
  multiBack = multi.layers[1]
  multiBack.name = "Back"
  multi:deleteCel(multiBack:cel(1))
  multi:newCel(multiBack, 1, square(6, colors[2]), Point(2, 2))
  multi:newEmptyFrame(); multi:newEmptyFrame()
  multi:newCel(multiBack, 2, square(6, colors[2]), Point(2, 2))
  multi:newCel(multiBack, 3, square(6, colors[2]), Point(2, 2))
  multiFront = multi:newLayer()
  multiFront.name = "Front"
  multi:newCel(multiFront, 1, square(5, colors[3]), Point(8, 8))
  multi:newCel(multiFront, 2, square(5, colors[3]), Point(8, 8))
  app.sprite = multi
  app.frame = multi.frames[1]
  ctx.session.load(ctx, multi)
  ctx.lightUI.reload(ctx)
  assert(#ctx.light.records == 2 and ctx.light.records[1].name == "Back" and ctx.light.records[2].name == "Front")
  assert(#ctx.lightUI.selectedRecords(ctx) == 1, "one layer checked at first: " .. checked())
  assert(ctx.light.frame == 1)
  fire(ctx.lightDialog, "layerList", "onpaint", { context = stubGc(ctx.lightWidgets.Layers.WIDTH, 150) })
  fire(ctx.lightDialog, "frameStrip", "onpaint", { context = stubGc(120, ctx.lightWidgets.Frames.HEIGHT) })
end)
step("layer list: checkbox toggles, name selects only that layer, all / none", function()
  local light = ctx.lightDialog
  local W = ctx.lightWidgets.Layers
  ctx.lightUI.soloLayer(ctx, ctx.light.records[1].uuid)
  assert(checked() == "Back")
  clickLayer("Front", "box")
  assert(checked() == "Back,Front", "the checkbox adds a layer: " .. checked())
  assert(#ctx.light.results == 2, "the preview shows both layers")
  clickLayer("Back", "box")
  assert(checked() == "Front" and #ctx.light.results == 1, "unchecking hides the layer from the preview")
  clickLayer("Back", "name")
  assert(checked() == "Back", "clicking a name selects only that layer")
  fire(light, "layerList", "onmousedown", { x = 5, y = 3, button = MouseButton.LEFT })
  assert(checked() == "Back,Front", "all")
  fire(light, "layerList", "onmousedown", { x = W.WIDTH - 5, y = 3, button = MouseButton.LEFT })
  assert(checked() == "" and ctx.light.results == nil, "none: nothing to preview")
  assert(ctx.light.status == "No layer checked", ctx.light.status)
  fire(light, "layerList", "onwheel", { deltaY = 1 })
  fire(light, "layerList", "onmousedown", { x = 5, y = 3, button = MouseButton.LEFT })
  fire(light, "layerList", "onpaint", { context = stubGc(W.WIDTH, 150) })
end)
step("multi-layer preview: composite in sprite coordinates, one light for all layers", function()
  local light = ctx.lightDialog
  assert(#ctx.light.results == 2)
  local scene = ctx.light.scene
  assert(scene.x == 2 and scene.y == 2 and scene.width == 11, "scene is the union of both objects")
  assert(ctx.light.shared.lightX and ctx.light.shared.lightHeight, "the light was placed from the scene")
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  -- The eyedropper finds the topmost layer's pixel under the cursor.
  local t = ctx.light.viewT
  local x, y = ctx.lightView.toScreen(t, 9.5, 9.5)   -- inside Front (8..12), on top of nothing else
  local pixel, result = ctx.lightUI.previewPixel(ctx, x, y)
  assert(pixel and result.record.name == "Front", "picks Front")
  x, y = ctx.lightView.toScreen(t, 3.5, 3.5)
  pixel, result = ctx.lightUI.previewPixel(ctx, x, y)
  assert(pixel and result.record.name == "Back", "picks Back")
  x, y = ctx.lightView.toScreen(t, 14.5, 1.5)
  assert(ctx.lightUI.previewPixel(ctx, x, y) == nil, "empty space")
end)
step("Keep: click colors in the preview to leave them unshaded; click again, Clear", function()
  local light = ctx.lightDialog
  ctx.lightUI.selectAllLayers(ctx, true)
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })
  local t = ctx.light.viewT
  local function frontResult()
    for _, r in ipairs(ctx.light.results) do if r.record.name == "Front" then return r end end
  end
  assert(frontResult().stats.shaded == 25, "Front is shaded before keeping its color")
  fire(light, "keepAdd", "onclick")
  assert(ctx.light.keeping and light:widget("keepAdd").props.text == "Done")
  local x, y = ctx.lightView.toScreen(t, 9.5, 9.5)       -- a Front pixel
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(#ctx.light.layer.excludedColors == 1, "the clicked color is kept")
  assert(ctx.light.keeping, "keep mode stays on for more clicks")
  assert(frontResult().stats.shaded == 0, "kept pixels are left exactly as they are")
  assert(light:widget("keepClear").props.enabled == true)
  assert(ctx.lightAseprite.loadLayerSettings(multiFront, ctx.namespace).excludedColors[1], "stored on the checked layers")
  assert(ctx.lightAseprite.loadLayerSettings(multiBack, ctx.namespace).excludedColors[1])
  fire(light, "lightPreview", "onpaint", { context = stubGc(224, 150) })   -- draws the chips
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(#ctx.light.layer.excludedColors == 0 and frontResult().stats.shaded == 25, "clicking again shades it again")
  x, y = ctx.lightView.toScreen(t, 15.5, 1.5)             -- empty space
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  assert(ctx.light.status:match("inside an object"), ctx.light.status)
  fire(light, "keepAdd", "onclick")
  assert(not ctx.light.keeping and light:widget("keepAdd").props.text == "Add color", "Done ends keep mode")
  fire(light, "keepAdd", "onclick")
  x, y = ctx.lightView.toScreen(t, 9.5, 9.5)
  fire(light, "lightPreview", "onmousedown", { x = x, y = y, button = MouseButton.LEFT })
  fire(light, "keepClear", "onclick")
  assert(#ctx.light.layer.excludedColors == 0 and frontResult().stats.shaded == 25, "Clear shades everything again")
  -- Picking a family and keeping colors are exclusive modes.
  fire(light, "pick", "onclick")
  assert(ctx.light.picking and not ctx.light.keeping)
  fire(light, "keepAdd", "onclick")
  assert(ctx.light.keeping and not ctx.light.picking)
  fire(light, "keepAdd", "onclick")
end)
step("frame strip: click selects a frame and the editor follows; wheel scrolls", function()
  local light = ctx.lightDialog
  local F = ctx.lightWidgets.Frames
  fire(light, "frameStrip", "onpaint", { context = stubGc(120, F.HEIGHT) })
  noBoundsWrites("frame strip", function()
    fire(light, "frameStrip", "onmousedown", { x = ctx.light.cellW + 3, y = 5, button = MouseButton.LEFT })
  end)
  assert(ctx.light.frame == 2, "frame 2 selected")
  assert(app.frame.frameNumber == 2, "the editor follows the strip")
  assert(#ctx.light.results == 2, "both layers have cels on frame 2")
  fire(light, "frameStrip", "onmousedown", { x = ctx.light.cellW * 2 + 3, y = 5, button = MouseButton.LEFT })
  assert(ctx.light.frame == 3 and #ctx.light.results == 1, "on frame 3 only Back has a cel")
  assert(ctx.light.skipped[multiFront.uuid and tostring(multiFront.uuid)], "Front is marked as having no cel here")
  assert(ctx.light.status:match("without a cel"), ctx.light.status)
  fire(light, "frameStrip", "onwheel", { deltaY = 1 })
  -- The editor changes frame (sitechange): the strip follows without a loop.
  app.frame = multi.frames[1]
  ctx.lightUI.syncFrame(ctx)
  assert(ctx.light.frame == 1 and #ctx.light.results == 2)
  fire(light, "frameStrip", "onpaint", { context = stubGc(120, F.HEIGHT) })
end)
step("frame strip dots: filled where a checked layer has a cel, per the checked set", function()
  local light = ctx.lightDialog
  local F = ctx.lightWidgets.Frames
  assert(F.HEIGHT == F.NUM_H * 2, "numbers on top, dots below")
  fire(light, "frameStrip", "onpaint", { context = stubGc(120, F.HEIGHT) })
  assert(ctx.light.cellW >= F.MIN_CELL_W and ctx.light.cellW <= 20, "compact cells: " .. tostring(ctx.light.cellW))
  ctx.lightUI.selectAllLayers(ctx, true)
  local map = ctx.lightUI.celFrames(ctx)
  assert(map[1] and map[2] and map[3], "Back has a cel on every frame")
  ctx.lightUI.soloLayer(ctx, tostring(multiFront.uuid))
  map = ctx.lightUI.celFrames(ctx)
  assert(map[1] and map[2] and not map[3], "Front has none on frame 3")
  fire(light, "frameStrip", "onpaint", { context = stubGc(120, F.HEIGHT) })
  ctx.lightUI.selectAllLayers(ctx, true)
  assert(ctx.lightUI.celFrames(ctx)[3], "all layers: frame 3 has a cel again")
  assert(ctx.lightUI.celFrames(ctx) == ctx.lightUI.celFrames(ctx), "cached while nothing changes")
end)
step("Frames: All frames + New layer writes one output layer per source, one undo step", function()
  local light = ctx.lightDialog
  local data = light.data
  data.output = "New layer"
  data.scope = "All frames"
  light.data = data
  fire(light, "output", "onchange")
  fire(light, "scope", "onchange")
  assert(ctx.light.scope == "All frames" and ctx.light.outputMode == "New layer")
  local before = #multi.layers
  fire(light, "applyLight", "onclick")
  assert(#multi.layers == before + 2, "two output layers: " .. #multi.layers)
  local out
  for _, layer in ipairs(multi.layers) do if layer.name == "Palette Trio Light - Back" then out = layer end end
  assert(out and out:cel(1) and out:cel(2) and out:cel(3), "Back output on all 3 frames")
  assert(ctx.light.status:match("2 layers, 3 frames"), ctx.light.status)
  app.command.Undo()
  assert(#multi.layers == before, "one undo removes both output layers")
  -- "This frame" writes just the current frame.
  data = light.data
  data.scope = "This frame"
  light.data = data
  fire(light, "scope", "onchange")
  fire(light, "applyLight", "onclick")
  for _, layer in ipairs(multi.layers) do
    if layer.name == "Palette Trio Light - Back" then
      assert(layer:cel(1) and not layer:cel(2) and not layer:cel(3), "only the current frame")
    end
  end
  app.command.Undo()
  assert(#multi.layers == before)
end)
step("Frames: Replace source on all frames asks, shades every checked cel, undo restores, re-apply is stable", function()
  local light = ctx.lightDialog
  local function dump()
    local out = {}
    for _, layer in ipairs({ multiBack, multiFront }) do
      for f = 1, 3 do
        local cel = layer:cel(f)
        out[#out + 1] = cel and cel.image.bytes or "-"
      end
    end
    return out
  end
  local original = dump()
  local data = light.data
  data.output = "Replace source"
  data.scope = "All frames"
  light.data = data
  fire(light, "output", "onchange")
  fire(light, "scope", "onchange")
  local question
  local saved = ctx.alert
  ctx.alert = function(t) question = table.concat(t.text, " "); return 1 end
  fire(light, "applyLight", "onclick")
  ctx.alert = saved
  assert(question and question:match("2 layers") and question:match("3 frames") and question:match("5 cels"), question)
  local first = dump()
  local changed = 0
  for i = 1, #first do if first[i] ~= original[i] then changed = changed + 1 end end
  assert(changed == 5, "every cel was shaded: " .. changed)
  fire(light, "applyLight", "onclick")
  local second = dump()
  for i = 1, #second do assert(second[i] == first[i], "re-applying shades the original, cel " .. i) end
  app.command.Undo(); app.command.Undo()
  local restored = dump()
  for i = 1, #restored do assert(restored[i] == original[i], "undo restores cel " .. i) end
  data = light.data
  data.output = "New layer"
  data.scope = "This frame"
  light.data = data
  fire(light, "output", "onchange")
  fire(light, "scope", "onchange")
end)
step("back to the first document", function()
  app.sprite = sprite
  app.frame = sprite.frames[1]
  ctx.session.load(ctx, sprite)
  ctx.lightUI.reload(ctx)
  assert(ctx.light.sprite == sprite and #ctx.lightUI.selectedRecords(ctx) >= 1)
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
