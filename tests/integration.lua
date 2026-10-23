-- Integration tests against the real Aseprite scripting API.
-- Run headless:  aseprite -b --script tests/integration.lua
-- They create temporary sprites/files and never touch open user documents.
if not app or not Sprite then
  print("integration tests require Aseprite (aseprite -b --script tests/integration.lua)")
  return
end

local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = sourcePath:match("^(.*)/tests/[^/]+$") or "."
local function load(path) return dofile(root .. "/" .. path) end

local NAMESPACE = "palette-trio/palette-trio"
local function newCtx()
  return {
    color = load("src/color.lua"),
    modelModule = load("src/model.lua"),
    persistence = load("src/persistence.lua"),
    aseprite = load("src/aseprite.lua"),
    source = load("src/source.lua"),
    session = load("src/session.lua"),
    lightEngine = load("src/light_engine.lua"),
    lightAseprite = load("src/light_aseprite.lua"),
    namespace = NAMESPACE,
    selectedRow = 0, selectedSlot = "base", scroll = 0,
  }
end

local tmp = os.getenv("TMPDIR") or "/tmp"
local tmpDir = app.fs.joinPath(tmp, "palette-trio-tests-" .. tostring(os.time()))
app.fs.makeAllDirectories(tmpDir)

local passed, failed = 0, 0
local function test(name, fn)
  local ok, reason = pcall(fn)
  if ok then passed = passed + 1; print("ok - " .. name)
  else failed = failed + 1; print("not ok - " .. name .. "\n  " .. tostring(reason)) end
  -- Sprites are left open: Sprite:close() crashes Aseprite 1.3.17 in batch mode.
end
local function equal(a, b, message)
  assert(a == b, (message and (message .. ": ") or "") .. tostring(a) .. " ~= " .. tostring(b))
end

local function spriteWithPalette(colors, mode, width, height)
  local sprite = Sprite(width or 8, height or 8, mode or ColorMode.RGB)
  local palette = Palette(#colors)
  for i, c in ipairs(colors) do palette:setColor(i - 1, Color { r = c[1], g = c[2], b = c[3], a = c[4] or 255 }) end
  sprite:setPalette(palette)
  return sprite
end

local function paletteDump(sprite)
  local p, out = sprite.palettes[1], {}
  for i = 0, #p - 1 do
    local c = p:getColor(i)
    out[#out + 1] = string.format("%d,%d,%d,%d", c.red, c.green, c.blue, c.alpha)
  end
  return table.concat(out, ";")
end

local function imageDump(image)
  local out = {}
  for it in image:pixels() do out[#out + 1] = it() end
  return table.concat(out, ",")
end

local function paint(sprite, points)
  local image = sprite.cels[1].image
  for _, p in ipairs(points) do
    image:drawPixel(p[1], p[2], app.pixelColor.rgba(p[3][1], p[3][2], p[3][3], 255))
  end
end

local SMALL = { { 34, 32, 52 }, { 69, 40, 60 }, { 102, 57, 49 }, { 143, 86, 59 },
  { 223, 113, 38 }, { 217, 160, 102 }, { 238, 195, 154 }, { 251, 242, 54 } }

local function db32ish()
  local list = {}
  for i = 1, 32 do list[i] = { (i * 53) % 256, (i * 97) % 256, (i * 29 + 40) % 256 } end
  return list
end

------------------------------------------------------------------------------

test("first open with a small document palette: families appear, nothing is written", function()
  local sprite = spriteWithPalette(SMALL)
  local before = paletteDump(sprite)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 8)
  equal(ctx.provisional, true)
  equal(ctx.model.source.kind, "palette")
  equal(ctx.model.rows[3].base.r, 102)
  equal(ctx.model.rows[3].link.index, 2)
  equal(sprite.properties(NAMESPACE).paletteTrio, nil, "opening must not store data")
  equal(paletteDump(sprite), before, "opening must not change the palette")
  assert(ctx.session.sourceText(ctx):match("Document palette · 8 families"), ctx.session.sourceText(ctx))
end)

test("empty sprite with a 32-color native palette -> 32 families, in palette order", function()
  local palette = db32ish()
  local sprite = spriteWithPalette(palette)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 32)
  equal(ctx.provisional, true)
  for i, row in ipairs(ctx.model.rows) do
    equal(row.base.r, palette[i][1], "row " .. i)
    equal(row.link.index, i - 1)
  end
  equal(sprite.properties(NAMESPACE).paletteTrio, nil)
end)

test("64-color native palette -> 64 families", function()
  local colors = {}
  for i = 1, 64 do colors[i] = { (i * 37) % 256, (i * 91) % 256, (i * 53 + 7) % 256 } end
  local sprite = spriteWithPalette(colors)
  local ctx = newCtx()
  local started = os.clock()
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 64)
  assert(os.clock() - started < 1, "64 families load quickly")
end)

test("5-color native palette -> 5 families", function()
  local ctx = newCtx()
  ctx.session.load(ctx, spriteWithPalette({ SMALL[1], SMALL[2], SMALL[3], SMALL[4], SMALL[5] }))
  equal(#ctx.model.rows, 5)
end)

test("artwork using only one color does not narrow the families: the palette provides all", function()
  local palette = db32ish()
  local sprite = spriteWithPalette(palette, ColorMode.RGB, 16, 16)
  paint(sprite, { { 1, 1, palette[20] }, { 2, 1, palette[20] } })
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 32)
  equal(ctx.model.source.kind, "palette")
end)

test("optional artwork import adds only new, non-shade colors as custom families", function()
  local sprite = spriteWithPalette({ SMALL[1] }, ColorMode.RGB, 16, 16)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local shade = ctx.model.rows[1].shades.highlight.color
  paint(sprite, { { 0, 0, SMALL[1] }, { 1, 0, { shade.r, shade.g, shade.b } }, { 2, 0, { 5, 200, 9 } } })
  local art = ctx.source.readArtwork(sprite, NAMESPACE, ctx.model)
  equal(#art.entries, 1, "base and its painted shade are not offered")
  equal(art.entries[1].color.g, 200)
  ctx.model.addCustom(ctx.model, art.entries[1].color)
  equal(#ctx.model.rows, 2)
  equal(ctx.model.rows[2].link, nil, "custom family has no palette link")
  ctx.session.commit(ctx, "add")
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 2, "custom family survives palette sync")
end)

test("Light output layers are ignored by the artwork import", function()
  local sprite = spriteWithPalette({ SMALL[1] }, ColorMode.RGB, 4, 4)
  paint(sprite, { { 0, 0, { 100, 50, 25 } } })
  local layer = sprite:newLayer()
  layer.properties(NAMESPACE).paletteTrioLightOutput = { generated = true, sourceLayerUuid = "x" }
  local image = Image(4, 4, ColorMode.RGB)
  for x = 0, 3 do image:drawPixel(x, 1, app.pixelColor.rgba(x * 60, 9, 9, 255)) end
  sprite:newCel(layer, 1, image, Point(0, 0))
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  equal(#ctx.source.readArtwork(sprite, NAMESPACE, ctx.model).entries, 1)
end)

test("empty batch-default palette (256 identical entries) yields one family, not 256", function()
  local sprite = Sprite(8, 8)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  assert(#ctx.model.rows <= 1, "got " .. #ctx.model.rows)
end)

test("save/reopen .aseprite preserves families, pins, settings and links", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.model.setShadeCount(ctx.model, 5)
  ctx.model.editShade(ctx.model, 2, "deepShadow", { r = 1, g = 2, b = 3 })
  ctx.model.setName(ctx.model, 2, "wine")
  local ok, warning = ctx.session.commit(ctx, "test commit")
  equal(ok, true); equal(warning, nil)
  equal(ctx.provisional, false)
  local file = app.fs.joinPath(tmpDir, "families.aseprite")
  sprite:saveCopyAs(file)
  local reopened = app.open(file)
  local ctx2 = newCtx()
  equal(ctx2.session.load(ctx2, reopened), "ok")
  equal(#ctx2.model.rows, 8)
  equal(ctx2.model.shadeCount, 5)
  equal(ctx2.model.rows[2].name, "wine")
  equal(ctx2.model.rows[2].shades.deepShadow.color.b, 3)
  equal(ctx2.model.rows[2].shades.deepShadow.locked, true)
  equal(ctx2.model.rows[2].link.index, 1)
end)

test("PNG files do not keep families and the commit warns about it", function()
  local sprite = spriteWithPalette(SMALL)
  local file = app.fs.joinPath(tmpDir, "flat.png")
  sprite.filename = file
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.model.setName(ctx.model, 1, "keep me")
  local ok, warning = ctx.session.commit(ctx, "test")
  equal(ok, true)
  assert(warning and warning:match("PNG") and warning:match("%.aseprite"), tostring(warning))
  sprite:saveCopyAs(file)
  local reopened = app.open(file)
  assert(reopened ~= sprite)
  local ctx2 = newCtx()
  equal(ctx2.session.load(ctx2, reopened), "none", "PNG cannot carry extension properties")
  for _, row in ipairs(ctx2.model.rows) do assert(row.name ~= "keep me") end
end)

test("multiple open documents keep separate families", function()
  local a = spriteWithPalette({ { 255, 0, 0 }, { 0, 255, 0 } })
  local b = spriteWithPalette({ { 0, 0, 255 } })
  local ctx = newCtx()
  ctx.session.load(ctx, a)
  ctx.model.setName(ctx.model, 1, "red")
  ctx.session.commit(ctx, "a")
  ctx.session.load(ctx, b)
  equal(#ctx.model.rows, 1)
  equal(ctx.model.rows[1].base.b, 255)
  ctx.session.commit(ctx, "b")
  ctx.session.load(ctx, a)
  equal(#ctx.model.rows, 2)
  equal(ctx.model.rows[1].name, "red")
end)

test("native palette edits sync automatically: pins, names, order kept; additions appear", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.model.editShade(ctx.model, 4, "shadow", { r = 7, g = 7, b = 7 })
  ctx.model.setName(ctx.model, 4, "skin")
  ctx.session.commit(ctx, "pin")
  local id = ctx.model.rows[4].id
  local palette = Palette(sprite.palettes[1])
  palette:setColor(3, Color { r = 150, g = 90, b = 200 })
  palette:resize(9)
  palette:setColor(8, Color { r = 1, g = 99, b = 1 })
  sprite:setPalette(palette)
  local storedBefore = sprite.properties(NAMESPACE).paletteTrio
  equal(ctx.session.onSpriteChanged(ctx), true)
  equal(#ctx.model.rows, 9)
  equal(ctx.model.rows[4].id, id)
  equal(ctx.model.rows[4].name, "skin")
  equal(ctx.model.rows[4].base.b, 200)
  equal(ctx.model.rows[4].shades.shadow.color.r, 7, "pin preserved")
  equal(ctx.model.rows[9].base.g, 99)
  equal(sprite.properties(NAMESPACE).paletteTrio.nextId, storedBefore.nextId, "auto-sync writes nothing")
end)

test("deleting a native color keeps a stored family flagged until the artist removes it", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.session.commit(ctx, "store")
  local palette = Palette(sprite.palettes[1])
  palette:resize(7)
  sprite:setPalette(palette)
  ctx.session.onSpriteChanged(ctx)
  equal(#ctx.model.rows, 8)
  equal(ctx.model.rows[8].missing, true)
  assert(ctx.session.notice(ctx):match("not in palette"))
  equal(ctx.session.removeMissing(ctx), 1)
  equal(#ctx.model.rows, 7)
end)

test("subset selection persists, survives palette changes, and full palette restores", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local included = {}
  for i = 1, 3 do included[string.format("%d,%d,%d", SMALL[i][1], SMALL[i][2], SMALL[i][3])] = true end
  ctx.session.applyPaletteSubset(ctx, included)
  equal(#ctx.model.rows, 3)
  ctx.session.commit(ctx, "subset")
  -- A palette change elsewhere must not re-include excluded colors.
  local palette = Palette(sprite.palettes[1])
  palette:setColor(0, Color { r = SMALL[1][1], g = SMALL[1][2], b = SMALL[1][3] + 1 })
  sprite:setPalette(palette)
  ctx.session.onSpriteChanged(ctx)
  equal(#ctx.model.rows, 3, "excluded colors stay excluded")
  local ctx2 = newCtx()
  ctx2.session.load(ctx2, sprite)
  equal(#ctx2.model.rows, 3, "subset persists after reload")
  assert(ctx2.session.sourceText(ctx2):match("5 hidden"), ctx2.session.sourceText(ctx2))
  ctx2.session.useFullPalette(ctx2)
  equal(#ctx2.model.rows, 8)
end)

test("a base edited inside Palette Trio survives native palette changes", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.model.setBase(ctx.model, 2, { r = 1, g = 2, b = 250 })
  ctx.session.commit(ctx, "edit base")
  local palette = Palette(sprite.palettes[1])
  palette:setColor(1, Color { r = 77, g = 77, b = 77 })
  sprite:setPalette(palette)
  ctx.session.onSpriteChanged(ctx)
  equal(ctx.model.rows[2].base.b, 250)
  equal(ctx.model.rows[2].link.color.r, 77, "link follows the palette slot")
  equal(#ctx.model.rows, 8)
end)

test("stored 2.0 data from another source is not replaced by the new default", function()
  local sprite = spriteWithPalette(db32ish())
  sprite.properties(NAMESPACE).paletteTrio = {
    version = 2, shadeCount = 3, nextId = 3, settings = {},
    source = { kind = "artwork", label = "Artwork colors" }, ignored = {},
    rows = { { id = 1, name = "a", base = { r = 10, g = 20, b = 30 }, shades = {} },
      { id = 2, name = "", base = { r = 40, g = 50, b = 60 }, shades = {} } },
  }
  local ctx = newCtx()
  equal(ctx.session.load(ctx, sprite), "ok")
  equal(#ctx.model.rows, 2)
  ctx.session.useFullPalette(ctx)
  equal(#ctx.model.rows, 34, "explicit 'Use full document palette' adds the palette and keeps both")
end)

test("provisional families follow palette edits automatically", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local palette = Palette(sprite.palettes[1])
  palette:resize(9)
  palette:setColor(8, Color { r = 1, g = 99, b = 1 })
  sprite:setPalette(palette)
  ctx.session.onSpriteChanged(ctx)
  equal(#ctx.model.rows, 9)
  equal(ctx.provisional, true)
  palette = Palette(sprite.palettes[1])
  palette:resize(4)
  sprite:setPalette(palette)
  ctx.session.onSpriteChanged(ctx)
  equal(#ctx.model.rows, 4, "nothing stored, so removed colors simply disappear")
end)

test("indexed: append keeps every entry, the transparent index and the pixels", function()
  local sprite = spriteWithPalette({ { 0, 0, 0, 0 }, { 200, 10, 10 }, { 10, 200, 10 } }, ColorMode.INDEXED)
  local image = sprite.cels[1].image
  image:drawPixel(1, 1, 1); image:drawPixel(2, 2, 2)
  local pixels = imageDump(image)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  equal(#ctx.model.rows, 2, "transparent index 0 is not a family")
  local before = { sprite.palettes[1]:getColor(0), sprite.palettes[1]:getColor(1), sprite.palettes[1]:getColor(2) }
  local ok, message = ctx.aseprite.apply(sprite, ctx.model.allColors(ctx.model), "append")
  equal(ok, true, message)
  equal(#sprite.palettes[1], 3 + 4, "two families x 3 shades minus 2 existing bases")
  for i = 0, 2 do
    local c = sprite.palettes[1]:getColor(i)
    equal(c.rgbaPixel, before[i + 1].rgbaPixel, "entry " .. i)
  end
  equal(sprite.transparentColor, 0)
  equal(imageDump(sprite.cels[1].image), pixels)
  local refused = ctx.aseprite.apply(sprite, ctx.model.allColors(ctx.model), "replace")
  equal(refused, false, "indexed palettes are never replaced")
end)

test("RGB replace keeps pixels and undo restores the palette", function()
  local sprite = spriteWithPalette(SMALL)
  paint(sprite, { { 0, 0, SMALL[1] }, { 1, 0, { 9, 8, 7 } } })
  local pixels = imageDump(sprite.cels[1].image)
  local before = paletteDump(sprite)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local ok = ctx.aseprite.apply(sprite, ctx.model.allColors(ctx.model), "replace")
  equal(ok, true)
  equal(#sprite.palettes[1], 24)
  equal(imageDump(sprite.cels[1].image), pixels)
  app.command.Undo()
  equal(paletteDump(sprite), before)
end)

test("shades written by Palette Trio are excluded by provenance; foreign palettes are not filtered", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local colors = ctx.model.allColors(ctx.model)
  local ok = ctx.aseprite.apply(sprite, colors, "replace", function()
    ctx.model.recordGenerated(ctx.model, colors)
    ctx.persistence.save(sprite, NAMESPACE, ctx.model)
  end)
  equal(ok, true)
  local ctx2 = newCtx()
  ctx2.session.load(ctx2, sprite)
  equal(#ctx2.model.rows, 8, "written shades are not new families")
  equal(ctx2.model.rows[1].base.r, SMALL[1][1])
  app.command.Undo()
  equal(sprite.properties(NAMESPACE).paletteTrio, nil, "palette write and provenance undo together")
  -- The same 24 colors authored by someone else are all base colors.
  local other = spriteWithPalette((function()
    local list = {}
    for i, c in ipairs(colors) do list[i] = { c.r, c.g, c.b } end
    return list
  end)())
  local ctx3 = newCtx()
  ctx3.session.load(ctx3, other)
  equal(#ctx3.model.rows, 24)
end)

test("undo of a stored change restores the previous families", function()
  local sprite = spriteWithPalette(SMALL)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  ctx.model.setName(ctx.model, 1, "first")
  ctx.session.commit(ctx, "name 1")
  ctx.model.setName(ctx.model, 1, "second")
  ctx.session.commit(ctx, "name 2")
  app.command.Undo()
  ctx.session.load(ctx, sprite)
  equal(ctx.model.rows[1].name, "first")
  app.command.Redo()
  ctx.session.load(ctx, sprite)
  equal(ctx.model.rows[1].name, "second")
end)

test("commit without a sprite reports failure", function()
  local ctx = newCtx()
  ctx.session.load(ctx, nil)
  local ok, reason = ctx.session.commit(ctx, "x")
  equal(ok, false)
  assert(reason)
  equal(ctx.session.sourceText(ctx), "No sprite open")
end)

test("Light renders an auto-initialized document with its families", function()
  local sprite = spriteWithPalette(SMALL, ColorMode.RGB, 9, 9)
  local base = SMALL[4]
  local image = sprite.cels[1].image
  for y = 0, 8 do for x = 0, 8 do image:drawPixel(x, y, app.pixelColor.rgba(base[1], base[2], base[3], 255)) end end
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local data = ctx.lightAseprite.readCel(sprite.cels[1])
  local mask, key = ctx.lightEngine.extractSilhouette(data.pixels, data.width, data.height)
  local geometry = ctx.lightEngine.buildGeometry(mask, data.width, data.height, { shape = "Round / Sphere" }, {}, key)
  local families = ctx.model.shadeFamilies(ctx.model, 3)
  local output, stats = ctx.lightEngine.render(data.pixels, data.width, data.height, families, geometry,
    { levels = 3, directionX = -0.7, directionY = 0.7, elevation = 30, strength = 1 })
  equal(stats.shaded, 81)
  local allowed = {}
  for _, c in ipairs(families[4].colors) do allowed[string.format("%d,%d,%d", c.r, c.g, c.b)] = true end
  local distinct = {}
  for _, p in ipairs(output) do
    local k = string.format("%d,%d,%d", p.r, p.g, p.b)
    assert(allowed[k], "Light used a color outside the family: " .. k)
    distinct[k] = true
  end
  assert(next(distinct) ~= nil)
  local ok, layer = ctx.lightAseprite.applyOutput(sprite, { layer = sprite.layers[1], uuid = tostring(sprite.layers[1].uuid) },
    1, ctx.lightAseprite.makeImage(data.width, data.height, output), sprite.cels[1], {}, NAMESPACE)
  equal(ok, true)
  equal(#sprite.layers, 2)
  equal(sprite.properties(NAMESPACE).paletteTrio, nil, "Light does not need stored families")
  local _ = layer
end)

test("large palette and noisy artwork stay fast; artwork import reports its limit", function()
  local colors = {}
  for i = 0, 255 do colors[#colors + 1] = { (i * 37) % 256, (i * 91) % 256, (i * 53) % 256 } end
  local sprite = spriteWithPalette(colors, ColorMode.RGB, 256, 256)
  local image = sprite.cels[1].image
  for y = 0, 255 do for x = 0, 255 do image:drawPixel(x, y, app.pixelColor.rgba(x, y, (x * y) % 256, 255)) end end
  local started = os.clock()
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local elapsed = os.clock() - started
  equal(#ctx.model.rows, 256, "every native color, regardless of artwork")
  assert(elapsed < 2, string.format("load took %.2fs", elapsed))
  local art = ctx.source.readArtwork(sprite, NAMESPACE, ctx.model)
  assert(art.tooMany, "the optional import reports that it stopped")
end)

test("menu: exactly one command, in View (view_new), and no Light command", function()
  local commands = {}
  local fakePlugin = { path = root, preferences = {}, newCommand = function(_, t) commands[#commands + 1] = t end }
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile(root .. "/main.lua", "t", env))
  chunk()
  env.init(fakePlugin)
  equal(#commands, 1)
  equal(commands[1].id, "PaletteTrio")
  equal(commands[1].title, "Palette Trio")
  equal(commands[1].group, "view_new")
  local gui = io.open(app.fs.joinPath(app.fs.appPath, "data", "gui.xml"))
    or io.open("/Applications/Aseprite.app/Contents/Resources/data/gui.xml")
  if gui then
    local xml = gui:read("a"); gui:close()
    assert(xml:find('group="view_new"', 1, true), "view_new group exists in this Aseprite's gui.xml")
    assert(xml:find('id="view_menu"', 1, true))
  end
  env.exit(fakePlugin)
end)

test("Light replace-source: one cel only, undoable, re-apply shades from the original", function()
  local sprite = spriteWithPalette(SMALL, ColorMode.RGB, 9, 9)
  local base = SMALL[4]
  local image = sprite.cels[1].image
  for y = 0, 8 do for x = 0, 8 do image:drawPixel(x, y, app.pixelColor.rgba(base[1], base[2], base[3], 255)) end end
  image:drawPixel(0, 0, app.pixelColor.rgba(0, 0, 0, 0))
  image:drawPixel(4, 4, app.pixelColor.rgba(9, 8, 7, 255))
  local other = sprite:newLayer()
  sprite:newCel(other, 1, Image(9, 9, ColorMode.RGB), Point(0, 0))
  local otherDump = imageDump(other:cel(1).image)
  local layer = sprite.layers[1]
  local originalDump = imageDump(layer:cel(1).image)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local function shadeFrom(img)
    local data = ctx.lightAseprite.readCel(layer:cel(1), img)
    local mask, key = ctx.lightEngine.extractSilhouette(data.pixels, data.width, data.height)
    local geometry = ctx.lightEngine.buildGeometry(mask, data.width, data.height, { shape = "Round / Sphere" }, {}, key)
    local out = ctx.lightEngine.render(data.pixels, data.width, data.height, ctx.model.shadeFamilies(ctx.model, 3), geometry,
      { levels = 3, directionX = -0.7, directionY = 0.7, elevation = 30, strength = 1 })
    return ctx.lightAseprite.makeImage(data.width, data.height, out), out
  end
  local record = { layer = layer, uuid = tostring(layer.uuid) }
  local shaded, out = shadeFrom(nil)
  equal(out[1].a, 0, "transparency kept")
  equal(out[41].r, 9, "unmatched color kept")
  local ok, snapshot = ctx.lightAseprite.replaceSource(sprite, record, 1, shaded)
  equal(ok, true, tostring(snapshot))
  equal(#sprite.layers, 2, "no new layer in replace mode")
  equal(imageDump(other:cel(1).image), otherDump, "other layers untouched")
  local firstResult = imageDump(layer:cel(1).image)
  assert(firstResult ~= originalDump)
  -- Re-apply: the snapshot is used, so the result is identical (no compounding).
  local source = ctx.lightAseprite.snapshotSource(snapshot, layer:cel(1))
  assert(source, "cel still holds our output, so the original is used")
  local again = shadeFrom(source)
  ctx.lightAseprite.replaceSource(sprite, record, 1, again)
  equal(imageDump(layer:cel(1).image), firstResult, "repeated Apply does not compound")
  app.command.Undo()
  app.command.Undo()
  equal(imageDump(layer:cel(1).image), originalDump, "Undo restores the source pixels")
  equal(ctx.lightAseprite.snapshotSource(snapshot, layer:cel(1)), nil, "after undo the snapshot no longer applies")
  layer.isEditable = false
  local refused = ctx.lightAseprite.replaceSource(sprite, record, 1, shaded)
  equal(refused, false, "locked layers are refused")
end)

test("Light on real cels: family detected from shades, no FG dependence, replace still idempotent + undoable", function()
  local sprite = spriteWithPalette(SMALL, ColorMode.RGB, 12, 12)
  local ctx = newCtx()
  ctx.session.load(ctx, sprite)
  local row = ctx.model.rows[5]
  local layer = sprite.layers[1]
  local image = layer:cel(1).image
  -- An object painted only with family 5's shadow and highlight (no base).
  for y = 2, 9 do for x = 2, 9 do
    local c = (x + y) % 2 == 0 and row.shades.shadow.color or row.shades.highlight.color
    image:drawPixel(x, y, app.pixelColor.rgba(c.r, c.g, c.b, 255))
  end end
  -- A few pixels of family 1 (eye) and one unknown color.
  image:drawPixel(4, 4, app.pixelColor.rgba(SMALL[1][1], SMALL[1][2], SMALL[1][3], 255))
  image:drawPixel(6, 6, app.pixelColor.rgba(1, 250, 1, 255))
  local original = imageDump(image)
  app.fgColor = Color { r = 0, g = 0, b = 0 }
  local families = ctx.model.shadeFamilies(ctx.model, 3)
  local data = ctx.lightAseprite.readCel(layer:cel(1))
  local detection = ctx.lightEngine.detectFamily(data.pixels, families)
  equal(detection.index, 5, "dominant family from shade colors only")
  local function render(pixels, fallback)
    local mask, key = ctx.lightEngine.extractSilhouette(pixels, data.width, data.height)
    local geometry = ctx.lightEngine.buildGeometry(mask, data.width, data.height, { shape = "Round / Sphere" }, {}, key)
    return ctx.lightEngine.render(pixels, data.width, data.height, families, geometry,
      { levels = 3, directionX = -0.7, directionY = 0.7, elevation = 30, strength = 1, matchShades = true, fallbackFamily = fallback })
  end
  local out, stats = render(data.pixels, nil)
  equal(stats.shaded, 63, "all family pixels shaded (unknown kept)")
  local idx = 6 * 12 + 6 + 1
  equal(out[idx].g, 250, "auto mode keeps unknown colors")
  local outFallback = render(data.pixels, 5)
  assert(outFallback[idx].g ~= 250, "explicit family recolors the unknown pixel")
  local record = { layer = layer, uuid = tostring(layer.uuid) }
  local ok, snapshot = ctx.lightAseprite.replaceSource(sprite, record, 1, ctx.lightAseprite.makeImage(data.width, data.height, out))
  equal(ok, true)
  local first = imageDump(layer:cel(1).image)
  local fromOriginal = ctx.lightAseprite.snapshotSource(snapshot, layer:cel(1))
  local again = render(ctx.lightAseprite.readCel(layer:cel(1), fromOriginal).pixels, nil)
  ctx.lightAseprite.replaceSource(sprite, record, 1, ctx.lightAseprite.makeImage(data.width, data.height, again))
  equal(imageDump(layer:cel(1).image), first, "repeat Apply from the cached original does not compound")
  app.command.Undo(); app.command.Undo()
  equal(imageDump(layer:cel(1).image), original)
end)

test("document switching keeps Light family picks per layer and families per sprite", function()
  local a = spriteWithPalette(SMALL)
  local b = spriteWithPalette({ { 255, 0, 0 } })
  local ctx = newCtx()
  ctx.session.load(ctx, a)
  ctx.lightAseprite.saveLayerSettings(a.layers[1], NAMESPACE, { familyRowId = ctx.model.rows[3].id })
  ctx.session.load(ctx, b)
  equal(#ctx.model.rows, 1)
  equal(ctx.lightAseprite.loadLayerSettings(b.layers[1], NAMESPACE).familyRowId, nil)
  ctx.session.load(ctx, a)
  equal(#ctx.model.rows, 8)
  equal(ctx.lightAseprite.loadLayerSettings(a.layers[1], NAMESPACE).familyRowId, ctx.model.rows[3].id)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error(string.format("%d integration test(s) failed", failed)) end
