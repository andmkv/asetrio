local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local projectRoot = sourcePath:match("^(.*)/tests/[^/]+$") or "."
local function loadProjectModule(path)
  return dofile(projectRoot .. "/" .. path)
end

local Color = loadProjectModule("src/color.lua")
local Model = loadProjectModule("src/model.lua")
local Persistence = loadProjectModule("src/persistence.lua")
local Aseprite = loadProjectModule("src/aseprite.lua")
local Light = loadProjectModule("src/light_engine.lua")
local LightAseprite = loadProjectModule("src/light_aseprite.lua")
local Source = loadProjectModule("src/source.lua")
local Grid = loadProjectModule("src/grid.lua")

local passed, failed = 0, 0

local function test(name, fn)
  local ok, reason = pcall(fn)
  if ok then
    passed = passed + 1
    io.write("ok - " .. name .. "\n")
  else
    failed = failed + 1
    io.write("not ok - " .. name .. "\n  " .. tostring(reason) .. "\n")
  end
end

local function equal(a, b, message)
  assert(a == b, message or (tostring(a) .. " ~= " .. tostring(b)))
end

local function near(a, b, epsilon, message)
  assert(math.abs(a - b) <= epsilon, message or (tostring(a) .. " not within " .. tostring(epsilon) .. " of " .. tostring(b)))
end

test("new palette starts in 3-shade mode", function()
  local model = Model.new(Color)
  equal(model.shadeCount, 3)
  equal(#model.visibleSlots(model.shadeCount), 3)
end)

test("switching to 5 shades presents dark-to-light slots", function()
  local model = Model.new(Color)
  model.setShadeCount(model, 5)
  local slots = model.visibleSlots(model.shadeCount)
  equal(#slots, 5)
  equal(slots[1].key, "deepShadow")
  equal(slots[2].key, "shadow")
  equal(slots[3].key, "base")
  equal(slots[4].key, "highlight")
  equal(slots[5].key, "brightHighlight")
end)

test("base color remains exactly unchanged by shade generation", function()
  local model = Model.new(Color)
  local base = { r = 19, g = 102, b = 211 }
  local row = model.newRow(model, base)
  equal(row.base.r, base.r)
  equal(row.base.g, base.g)
  equal(row.base.b, base.b)
end)

test("normal shadow and highlight move perceptual lightness in the expected directions", function()
  local model = Model.new(Color)
  local row = model.newRow(model, { r = 126, g = 91, b = 63 })
  local baseL = Color.rgbToOklab(row.base).L
  local shadowL = Color.rgbToOklab(row.shades.shadow.color).L
  local highlightL = Color.rgbToOklab(row.shades.highlight.color).L
  assert(shadowL < baseL, "shadow should be darker in OKLab lightness")
  assert(highlightL > baseL, "highlight should be lighter in OKLab lightness")
end)

test("locked manual shade survives base changes while unlocked shade regenerates", function()
  local model = Model.new(Color)
  local row = model.newRow(model, { r = 180, g = 92, b = 44 })
  local manual = { r = 31, g = 37, b = 43 }
  model.editShade(model, 1, "shadow", manual)
  model.setLocked(model, 1, "shadow", true)
  local oldHighlight = Color.copy(row.shades.highlight.color)
  model.setBase(model, 1, { r = 30, g = 180, b = 200 })
  equal(row.shades.shadow.color.r, manual.r)
  equal(row.shades.shadow.color.g, manual.g)
  equal(row.shades.shadow.color.b, manual.b)
  equal(row.shades.shadow.override, true)
  equal(row.shades.shadow.locked, true)
  assert(row.shades.highlight.color.r ~= oldHighlight.r
    or row.shades.highlight.color.g ~= oldHighlight.g
    or row.shades.highlight.color.b ~= oldHighlight.b, "unlocked highlight should change")
end)

test("5 to 3 to 5 retains hidden shade overrides and locks", function()
  local model = Model.new(Color)
  model.setShadeCount(model, 5)
  local row = model.newRow(model, { r = 130, g = 80, b = 200 })
  local bright = { r = 220, g = 240, b = 250 }
  model.editShade(model, 1, "brightHighlight", bright)
  model.setLocked(model, 1, "brightHighlight", true)
  model.setShadeCount(model, 3)
  equal(#model.visibleSlots(model.shadeCount), 3)
  model.setShadeCount(model, 5)
  equal(#model.visibleSlots(model.shadeCount), 5)
  local shade = model.rows[1].shades.brightHighlight
  equal(shade.color.r, bright.r)
  equal(shade.color.g, bright.g)
  equal(shade.color.b, bright.b)
  equal(shade.override, true)
  equal(shade.locked, true)
end)

test("reset to auto clears a shade override and lock", function()
  local model = Model.new(Color)
  local row = model.newRow(model, { r = 100, g = 150, b = 200 })
  model.editShade(model, 1, "shadow", { r = 1, g = 2, b = 3 })
  model.setLocked(model, 1, "shadow", true)
  assert(model.resetShade(model, 1, "shadow"))
  equal(row.shades.shadow.override, false)
  equal(row.shades.shadow.locked, false)
  equal(row.shades.shadow.manualColor, nil)
  assert(Color.rgbToOklab(row.shades.shadow.color).L < Color.rgbToOklab(row.base).L)
end)

test("manual shade edit is pinned and survives serialization and base changes", function()
  local model = Model.new(Color)
  model.newRow(model, { r = 70, g = 120, b = 190 })
  model.editShade(model, 1, "highlight", { r = 240, g = 24, b = 38 })
  equal(model.rows[1].shades.highlight.locked, true)
  local restored = Model.fromTable(Color, model.toTable(model))
  equal(restored.rows[1].shades.highlight.color.r, 240)
  equal(restored.rows[1].shades.highlight.color.g, 24)
  equal(restored.rows[1].shades.highlight.override, true)
  restored.setBase(restored, 1, { r = 170, g = 80, b = 35 })
  equal(restored.rows[1].shades.highlight.color.g, 24, "pinned manual color must survive a base change")
  restored.setLocked(restored, 1, "highlight", false)
  assert(restored.rows[1].shades.highlight.color.g ~= 24, "unpinning returns the shade to auto")
  equal(restored.rows[1].shades.highlight.override, false)
end)

test("legacy v1 unlocked override keeps v1 behavior until a later recalculation", function()
  local model = Model.new(Color)
  model.newRow(model, { r = 70, g = 120, b = 190 })
  local data = model.toTable(model)
  data.version = 1
  data.source, data.ignored = nil, nil
  data.rows[1].shades.highlight = { color = { r = 240, g = 24, b = 38 }, manualColor = { r = 240, g = 24, b = 38 }, override = true, locked = false }
  local restored, valid = Model.fromTable(Color, data)
  equal(valid, true)
  equal(restored.source.kind, "legacy")
  equal(restored.rows[1].shades.highlight.color.g, 24)
  restored.setBase(restored, 1, { r = 170, g = 80, b = 35 })
  assert(restored.rows[1].shades.highlight.color.g ~= 24)
end)

test("grayscale, black, white, and low-chroma colors always generate valid RGB", function()
  local model = Model.new(Color)
  local cases = {
    { r = 0, g = 0, b = 0 }, { r = 255, g = 255, b = 255 },
    { r = 90, g = 90, b = 90 }, { r = 1, g = 2, b = 3 },
    { r = 250, g = 240, b = 245 },
  }
  for _, base in ipairs(cases) do
    local row = model.newRow(model, base)
    for _, slot in ipairs({ "deepShadow", "shadow", "highlight", "brightHighlight" }) do
      local rgb = row.shades[slot].color
      assert(Color.validRgb(rgb), "invalid color in " .. slot)
      for _, value in pairs(rgb) do assert(value == value, "NaN channel") end
    end
  end
end)

test("sRGB and OKLab conversion round-trips within 1.1 RGB values", function()
  for r = 0, 255, 17 do
    for g = 0, 255, 31 do
      for b = 0, 255, 47 do
        local source = { r = r, g = g, b = b }
        local converted = Color.oklabToRgb(Color.rgbToOklab(source))
        near(converted.r, r, 1.1)
        near(converted.g, g, 1.1)
        near(converted.b, b, 1.1)
      end
    end
  end
end)

test("gamut mapping keeps generated channels in range", function()
  local mapped = Color.oklchToRgb({ L = 0.66, C = 1.0, h = 145 }, true)
  assert(Color.validRgb(mapped))
end)

test("palette rows, order, settings, hidden states serialize and restore", function()
  local model = Model.new(Color)
  model.setShadeCount(model, 5)
  model.setSettings(model, {
    shadowStrength = 0.42, highlightStrength = 0.33,
    shadowHueShift = 7, highlightHueShift = 13,
    coolShadows = false, warmHighlights = true,
  })
  model.newRow(model, { r = 12, g = 34, b = 56 }, "first")
  model.newRow(model, { r = 210, g = 100, b = 18 }, "second")
  model.editShade(model, 1, "deepShadow", { r = 3, g = 4, b = 5 })
  model.setLocked(model, 1, "deepShadow", true)
  model.moveRow(model, 1, 1)

  local restored, valid = Model.fromTable(Color, model.toTable(model))
  equal(valid, true)
  equal(restored.shadeCount, 5)
  equal(restored.rows[1].name, "second")
  equal(restored.rows[2].name, "first")
  equal(restored.rows[2].shades.deepShadow.color.g, 4)
  equal(restored.rows[2].shades.deepShadow.override, true)
  equal(restored.rows[2].shades.deepShadow.locked, true)
  near(restored.settings.shadowStrength, 0.42, 1e-9)
  equal(restored.settings.coolShadows, false)
end)

test("malformed or unsupported project data falls back to an empty 3-shade palette", function()
  local model, valid = Model.fromTable(Color, { version = 999, rows = {} })
  equal(valid, false)
  equal(model.shadeCount, 3)
  equal(#model.rows, 0)
end)

test("separate sprite property stores retain independent project palettes", function()
  local function sprite()
    local properties = {}
    return {
      properties = function(namespace, values)
        if values then properties[namespace] = values end
        properties[namespace] = properties[namespace] or {}
        return properties[namespace]
      end,
    }
  end
  local first, second = sprite(), sprite()
  local a, b = Model.new(Color), Model.new(Color)
  a.newRow(a, { r = 255, g = 0, b = 0 }, "red")
  b.newRow(b, { r = 0, g = 0, b = 255 }, "blue")
  Persistence.save(first, "publisher/extension", a)
  Persistence.save(second, "publisher/extension", b)
  local restoredA = Persistence.load(first, "publisher/extension", Model, Color)
  local restoredB = Persistence.load(second, "publisher/extension", Model, Color)
  equal(restoredA.rows[1].base.r, 255)
  equal(restoredA.rows[1].base.b, 0)
  equal(restoredB.rows[1].base.r, 0)
  equal(restoredB.rows[1].base.b, 255)
end)

test("Palette Trio model methods are available without changing the saved schema", function()
  local model = Model.new(Color)
  assert(type(model.newRow) == "function")
  model.newRow(model, { r = 1, g = 2, b = 3 })
  local saved = model.toTable(model)
  equal(saved.version, Model.SCHEMA_VERSION)
  equal(saved.rows[1].shades.base, nil)
end)

test("shared Light settings coexist with the existing palette property", function()
  local state = {}
  local sprite = { properties = function(namespace)
    state[namespace] = state[namespace] or {}
    return state[namespace]
  end }
  local model = Model.new(Color)
  model.newRow(model, { r = 10, g = 20, b = 30 })
  Persistence.save(sprite, "palette-trio/palette-trio", model)
  local palette = state["palette-trio/palette-trio"].paletteTrio
  LightAseprite.saveShared(sprite, "palette-trio/palette-trio", { levels = 5, strength = 0.7 })
  equal(state["palette-trio/palette-trio"].paletteTrio, palette)
  equal(LightAseprite.loadShared(sprite, "palette-trio/palette-trio").levels, 5)
end)

test("indexed palette planning only appends and leaves all old entries intact", function()
  local originalColors = {
    { r = 1, g = 2, b = 3, a = 255 },
    { r = 4, g = 5, b = 6, a = 255 },
  }
  local plan = Aseprite.indexedPlan(originalColors, {
    { r = 4, g = 5, b = 6 },
    { r = 7, g = 8, b = 9 },
  }, 256)
  equal(plan.firstIndex, 2)
  equal(#plan.additions, 1)
  equal(plan.additions[1].r, 7)
  equal(#originalColors, 2)
  equal(originalColors[1].r, 1)
  equal(originalColors[2].r, 4)
end)

test("indexed palette capacity is enforced at 256 entries", function()
  local colors = {}
  for i = 1, 256 do colors[i] = { r = i % 256, g = 0, b = 0, a = 255 } end
  local plan, reason = Aseprite.indexedPlan(colors, { { r = 1, g = 1, b = 1 } }, 256)
  equal(plan, nil)
  assert(reason:match("256%-color limit"))
  local duplicateOnly = Aseprite.indexedPlan(colors, { { r = 20, g = 0, b = 0 } }, 256)
  equal(#duplicateOnly.additions, 0)
end)

test("transparent indexed colors are not mistaken for opaque matches", function()
  local palette = { { r = 20, g = 30, b = 40, a = 0 } }
  local plan = Aseprite.indexedPlan(palette, { { r = 20, g = 30, b = 40 } }, 256)
  equal(#plan.additions, 1)
end)

local function imagePixels(width, height, colorFn)
  local result = {}
  for y = 1, height do
    for x = 1, width do result[(y - 1) * width + x] = colorFn(x, y) end
  end
  return result
end

local function constantGeometry(width, height, nx, ny, nz)
  local geometry = { outline = {}, normals = { x = {}, y = {}, z = {} } }
  for i = 1, width * height do
    geometry.normals.x[i], geometry.normals.y[i], geometry.normals.z[i] = nx, ny, nz
  end
  return geometry
end

local testFamily = {
  base = { r = 12, g = 34, b = 56 },
  colors = {
    { r = 2, g = 4, b = 6 },
    { r = 12, g = 34, b = 56 },
    { r = 90, g = 100, b = 110 },
  },
}

test("silhouette extraction treats any nonzero alpha as solid", function()
  local pixels = {
    { r = 1, g = 1, b = 1, a = 0 }, { r = 1, g = 1, b = 1, a = 1 },
    { r = 1, g = 1, b = 1, a = 127 }, { r = 1, g = 1, b = 1, a = 255 },
  }
  local mask = Light.extractSilhouette(pixels, 4, 1)
  equal(mask[1], 0); equal(mask[2], 1); equal(mask[3], 1); equal(mask[4], 1)
end)

test("4-connected components keep diagonal pixels separate", function()
  local mask = { 1, 0, 0, 1 }
  local labels, components = Light.connectedComponents(mask, 2, 2)
  equal(#components, 2)
  assert(labels[1] ~= labels[4])
end)

test("sphere normals are centered, normalized, and mirror across its axis", function()
  local pixels = imagePixels(5, 5, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local mask, key = Light.extractSilhouette(pixels, 5, 5)
  local geometry = Light.buildGeometry(mask, 5, 5, { shape = "Round / Sphere" }, {}, key)
  near(geometry.normals.x[13], 0, 1e-9)
  near(geometry.normals.y[13], 0, 1e-9)
  near(geometry.normals.z[13], 1, 1e-9)
  near(geometry.normals.x[11], -geometry.normals.x[15], 1e-9)
  near(geometry.normals.z[11], geometry.normals.z[15], 1e-9)
  assert(geometry.normals.y[3] > 0, "top-of-image normal must point toward positive light Y")
end)

test("box normals keep front flat and tilt at beveled boundary", function()
  local pixels = imagePixels(7, 7, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local mask, key = Light.extractSilhouette(pixels, 7, 7)
  local geometry = Light.buildGeometry(mask, 7, 7, { shape = "Box / Beveled rectangle", bevel = 3 }, {}, key)
  near(geometry.normals.z[25], 1, 1e-9)
  assert(math.abs(geometry.normals.x[22]) + math.abs(geometry.normals.y[22]) > 0.1)
end)

test("horizontal cylinder curvature is invariant along its axis", function()
  local pixels = imagePixels(7, 5, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local mask, key = Light.extractSilhouette(pixels, 7, 5)
  local geometry = Light.buildGeometry(mask, 7, 5, { shape = "Cylinder", cylinderAxis = "Horizontal" }, {}, key)
  for x = 1, 7 do
    local index = 2 * 7 + x
    near(geometry.normals.x[index], 0, 1e-9)
    near(geometry.normals.y[index], geometry.normals.y[18], 1e-9)
  end
  assert(geometry.normals.y[4] > 0, "top of a horizontal cylinder should face upward")
end)

test("single-pixel and fully opaque silhouettes produce finite normals", function()
  local singleton = { { r = 1, g = 2, b = 3, a = 255 } }
  local mask, key = Light.extractSilhouette(singleton, 1, 1)
  local geometry = Light.buildGeometry(mask, 1, 1, { shape = "Round / Sphere" }, {}, key)
  near(geometry.normals.x[1], 0, 1e-9)
  near(geometry.normals.y[1], 0, 1e-9)
  near(geometry.normals.z[1], 1, 1e-9)
  local opaque = imagePixels(4, 2, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local opaqueMask, opaqueKey = Light.extractSilhouette(opaque, 4, 2)
  local opaqueGeometry = Light.buildGeometry(opaqueMask, 4, 2, { shape = "Box / Beveled rectangle" }, {}, opaqueKey)
  for i = 1, 8 do
    assert(opaqueGeometry.normals.z[i] == opaqueGeometry.normals.z[i])
    near(math.sqrt(opaqueGeometry.normals.x[i]^2 + opaqueGeometry.normals.y[i]^2 + opaqueGeometry.normals.z[i]^2), 1, 1e-6)
  end
end)

test("contour relief produces finite normals and a raised interior", function()
  local pixels = imagePixels(9, 9, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local mask, key = Light.extractSilhouette(pixels, 9, 9)
  local geometry = Light.buildGeometry(mask, 9, 9, { shape = "Contour / Auto Relief", curvature = 1 }, {}, key)
  for i = 1, 81 do
    local nx, ny, nz = geometry.normals.x[i], geometry.normals.y[i], geometry.normals.z[i]
    assert(nx == nx and ny == ny and nz == nz)
    near(math.sqrt(nx * nx + ny * ny + nz * nz), 1, 1e-6)
  end
  assert(geometry.normals.z[41] > geometry.normals.z[5])
end)

test("directional light favors the surface facing it", function()
  local pixels = {
    { r = testFamily.base.r, g = testFamily.base.g, b = testFamily.base.b, a = 255 },
    { r = testFamily.base.r, g = testFamily.base.g, b = testFamily.base.b, a = 255 },
  }
  local geometry = { outline = {}, normals = { x = { 1, -1 }, y = { 0, 0 }, z = { 0, 0 } } }
  local output = Light.render(pixels, 2, 1, { testFamily }, geometry, {
    levels = 3, directionX = 1, directionY = 0, elevation = 10, strength = 1,
  })
  assert(output[1].r > output[2].r)
end)

test("three and five level quantization preserve endpoints and base midpoint", function()
  equal(Light.quantize(0, 3, "Off"), 1)
  equal(Light.quantize(0.5, 3, "Off"), 2)
  equal(Light.quantize(1, 3, "Off"), 3)
  equal(Light.quantize(0, 5, "Off"), 1)
  equal(Light.quantize(0.5, 5, "Off"), 3)
  equal(Light.quantize(1, 5, "Off"), 5)
end)

test("exact base RGB maps to its matching family while near colors remain untouched", function()
  local pixels = {
    { r = 12, g = 34, b = 56, a = 200 },
    { r = 12, g = 34, b = 56, a = 111 },
    { r = 13, g = 34, b = 56, a = 200 },
  }
  local geometry = { outline = {}, normals = { x = { 1, -1, 1 }, y = { 0, 0, 0 }, z = { 0, 0, 0 } } }
  local output = Light.render(pixels, 3, 1, { testFamily }, geometry, {
    levels = 3, directionX = 1, directionY = 0, elevation = 1, strength = 2,
  })
  equal(output[1].r, testFamily.colors[3].r)
  equal(output[1].g, testFamily.colors[3].g)
  equal(output[1].b, testFamily.colors[3].b)
  equal(output[1].a, 200)
  equal(output[2].r, testFamily.colors[1].r)
  equal(output[2].g, testFamily.colors[1].g)
  equal(output[2].b, testFamily.colors[1].b)
  equal(output[2].a, 111)
  equal(output[3].r, 13); equal(output[3].g, 34); equal(output[3].b, 56)
  equal(output[3].a, 200)
end)

test("outline preservation keeps outer and hole boundary colors", function()
  local pixels = imagePixels(3, 3, function(x, y)
    if x == 2 and y == 2 then return { r = 9, g = 8, b = 7, a = 0 } end
    return { r = 12, g = 34, b = 56, a = 255 }
  end)
  local mask, key = Light.extractSilhouette(pixels, 3, 3)
  local geometry = Light.buildGeometry(mask, 3, 3, { shape = "Contour / Auto Relief" }, {}, key)
  local output = Light.render(pixels, 3, 3, { testFamily }, geometry, {
    levels = 3, directionX = -1, directionY = 0, elevation = 20, strength = 2,
    preserveOutlines = true,
  })
  equal(output[1].r, 12)
  equal(output[5].r, 9); equal(output[5].a, 0)
end)

test("Bayer 2x2 dithering follows its ordered thresholds", function()
  local result = {}
  for y = 0, 1 do
    for x = 0, 1 do result[#result + 1] = Light.quantize(0.25, 3, "Bayer 2x2", x, y) end
  end
  equal(result[1], 2); equal(result[2], 1); equal(result[3], 1); equal(result[4], 2)
end)

test("Bayer 4x4 dithering uses the ordered matrix", function()
  equal(Light.quantize(0.25, 3, "Bayer 4x4", 0, 0), 2)
  equal(Light.quantize(0.25, 3, "Bayer 4x4", 1, 0), 1)
  equal(Light.quantize(0.25, 3, "Bayer 4x4", 2, 0), 2)
  equal(Light.quantize(0.25, 3, "Bayer 4x4", 3, 0), 1)
end)

test("excluded colors and unknown RGBs remain exact with alpha retained", function()
  local pixels = {
    { r = 12, g = 34, b = 56, a = 123 },
    { r = 77, g = 88, b = 99, a = 42 },
  }
  local geometry = constantGeometry(2, 1, 0, 0, 1)
  local output = Light.render(pixels, 2, 1, { testFamily }, geometry, {
    levels = 3, directionX = 0, directionY = 0, elevation = 45, strength = 2,
    excludedColors = { { r = 12, g = 34, b = 56 } },
  })
  equal(output[1].r, 12); equal(output[1].g, 34); equal(output[1].b, 56); equal(output[1].a, 123)
  equal(output[2].r, 77); equal(output[2].g, 88); equal(output[2].b, 99); equal(output[2].a, 42)
end)

test("shade-family snapshot does not mutate Palette Trio's shade mode", function()
  local model = Model.new(Color)
  local row = model.newRow(model, { r = 100, g = 120, b = 140 })
  local five = model.shadeFamilies(model, 5)
  equal(model.shadeCount, 3)
  equal(#five[1].colors, 5)
  equal(five[1].colors[3].r, row.base.r)
end)

test("geometry cache ignores light settings but invalidates on alpha silhouette changes", function()
  local cache = {}
  local pixels = imagePixels(2, 1, function() return { r = 1, g = 2, b = 3, a = 255 } end)
  local mask, key = Light.extractSilhouette(pixels, 2, 1)
  local geometry, hit = Light.buildGeometry(mask, 2, 1, { shape = "Cylinder", cylinderAxis = "Horizontal" }, cache, key)
  equal(hit, false)
  local reused, secondHit = Light.buildGeometry(mask, 2, 1, { shape = "Cylinder", cylinderAxis = "Horizontal" }, cache, key)
  equal(secondHit, true); equal(reused, geometry)
  pixels[1].a = 0
  local changedMask, changedKey = Light.extractSilhouette(pixels, 2, 1)
  assert(changedKey ~= key)
  local _, changedHit = Light.buildGeometry(changedMask, 2, 1, { shape = "Cylinder", cylinderAxis = "Horizontal" }, cache, changedKey)
  equal(changedHit, false)
end)


------------------------------------------------------------------------------
-- v2 workflow: source discovery, sync, choose, grid
------------------------------------------------------------------------------

local function rgb(r, g, b) return { r = r, g = g, b = b } end
local function entries(list)
  local result = {}
  for i, c in ipairs(list) do result[i] = { color = c, index = i - 1 } end
  return result
end
local function same(a, b) return a.r == b.r and a.g == b.g and a.b == b.b end

test("v1 project data migrates to schema v2 without losing families", function()
  local v1 = {
    version = 1, shadeCount = 5, nextId = 3,
    settings = { shadowStrength = 0.4 },
    rows = {
      { id = 1, name = "skin", base = rgb(200, 150, 120), shades = {
        shadow = { color = rgb(1, 2, 3), override = true, locked = true } } },
      { id = 2, name = "", base = rgb(30, 60, 90), shades = {} },
    },
  }
  local model, valid = Model.fromTable(Color, v1)
  equal(valid, true)
  equal(#model.rows, 2)
  equal(model.rows[1].name, "skin")
  equal(model.rows[1].shades.shadow.color.g, 2)
  equal(model.rows[1].shades.shadow.locked, true)
  equal(model.shadeCount, 5)
  local saved = model.toTable(model)
  equal(saved.version, 2)
  equal(saved.source.kind, "legacy")
end)

test("source dedupe drops transparent entries, the indexed transparent index, and duplicates", function()
  local list, info = Source.dedupe({
    { r = 0, g = 0, b = 0, a = 0, index = 0 },
    { r = 10, g = 10, b = 10, a = 255, index = 1 },
    { r = 10, g = 10, b = 10, a = 255, index = 2 },
    { r = 50, g = 60, b = 70, a = 255, index = 3 },
    { r = 90, g = 90, b = 90, a = 255, index = 4 },
  }, 4)
  equal(#list, 2)
  equal(list[1].index, 1)
  equal(list[2].index, 3)
  equal(info.transparent, 2)
  equal(info.duplicates, 1)
end)

test("all 32 native palette colors become candidates, in order (no size cut-off)", function()
  local raw = {}
  for i = 0, 31 do raw[#raw + 1] = { r = (i * 53) % 256, g = (i * 97) % 256, b = (i * 29 + 40) % 256, a = 255, index = i } end
  local list = Source.dedupe(raw)
  equal(#list, 32)
  for i, entry in ipairs(list) do equal(entry.index, i - 1) end
  local model = Model.new(Color)
  model.setSource(model, "palette", "")
  local report = model.syncSource(model, list)
  equal(report.added, 32)
  equal(#model.rows, 32)
  equal(model.rows[32].link.index, 31)
end)

test("authored colors that resemble shades are never removed; only recorded provenance is", function()
  local probe = Model.new(Color)
  probe.newRow(probe, rgb(180, 60, 50))
  local shadow = probe.rows[1].shades.shadow.color
  local list = entries({ rgb(180, 60, 50), shadow })
  local fresh = Model.new(Color)
  local kept, removed = Source.removeGenerated(list, fresh)
  equal(#kept, 2, "an authored color equal to a would-be shade stays")
  equal(removed, 0)
  fresh.newRow(fresh, rgb(180, 60, 50))
  fresh.recordGenerated(fresh, fresh.allColors(fresh))
  kept, removed = Source.removeGenerated(list, fresh)
  equal(#kept, 1)
  equal(removed, 1)
  assert(same(kept[1].color, rgb(180, 60, 50)), "the base itself is never treated as generated")
  local restored = Model.fromTable(Color, fresh.toTable(fresh))
  equal(select(2, Source.removeGenerated(list, restored)), 1, "provenance persists")
end)

test("artwork byte counting stops at the distinct-color limit and orders by usage", function()
  local bytes = string.char(1, 2, 3, 255, 1, 2, 3, 255, 9, 9, 9, 0, 4, 5, 6, 255)
  local counts, state = {}, { distinct = 0 }
  equal(Source.countRgbaBytes(bytes, counts, state, 10), true)
  equal(state.distinct, 2)
  equal(counts[(1 * 256 + 2) * 256 + 3], 2)
  local limited = { distinct = 0 }
  equal(Source.countRgbaBytes(bytes, {}, limited, 1), false)
  local ordered = Source.orderArtwork(counts)
  equal(ordered[1].color.r, 1, "most used first")
  local model = Model.new(Color)
  model.newRow(model, rgb(1, 2, 3))
  local kept = Source.removeKnown(ordered, model)
  equal(#kept, 1, "existing bases are not offered again")
end)

test("palette sync keeps unchanged families, follows edited slots, and keeps pins", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(200, 40, 40), rgb(40, 200, 40), rgb(40, 40, 200) }))
  model.editShade(model, 2, "shadow", rgb(1, 2, 3))
  model.setName(model, 2, "leaf")
  local ids = { model.rows[1].id, model.rows[2].id, model.rows[3].id }
  local oldHighlight = Color.copy(model.rows[2].shades.highlight.color)
  -- Palette index 1 changes from green to a yellow-green.
  local report = model.syncSource(model, entries({ rgb(200, 40, 40), rgb(120, 200, 40), rgb(40, 40, 200) }))
  equal(report.kept, 2); equal(report.updated, 1); equal(report.added, 0); equal(report.missing, 0)
  equal(model.rows[2].id, ids[2])
  equal(model.rows[2].name, "leaf")
  equal(model.rows[2].base.r, 120)
  equal(model.rows[2].shades.shadow.color.g, 2, "pinned shade survives sync")
  assert(not same(model.rows[2].shades.highlight.color, oldHighlight), "auto shade follows the new base")
end)

test("palette sync adds new colors and keeps families whose color disappeared", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(200, 40, 40), rgb(40, 200, 40) }))
  local report = model.syncSource(model, { { color = rgb(200, 40, 40), index = 0 }, { color = rgb(9, 9, 9), index = 5 } })
  equal(report.added, 1)
  equal(report.missing, 1)
  equal(#model.rows, 3)
  equal(model.rows[2].missing, true)
  equal(model.rows[3].base.r, 9)
end)

test("sync never overwrites a base edited inside Palette Trio", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(200, 40, 40) }))
  model.setBase(model, 1, rgb(210, 50, 50))
  equal(model.rows[1].baseEdited, true)
  local report = model.syncSource(model, entries({ rgb(180, 20, 20) }))
  equal(report.updated, 1)
  equal(model.rows[1].base.r, 210)
  equal(model.rows[1].link.color.r, 180)
end)

test("removed or unselected source colors are not re-added by sync", function()
  local model = Model.new(Color)
  local palette = entries({ rgb(200, 40, 40), rgb(40, 200, 40), rgb(40, 40, 200) })
  model.chooseColors(model, palette)
  model.removeRow(model, 2)
  local report = model.syncSource(model, palette)
  equal(report.added, 0)
  equal(report.ignored, 1)
  equal(#model.rows, 2)
  local restored = Model.fromTable(Color, model.toTable(model))
  equal(restored.syncSource(restored, palette).added, 0, "ignore list persists")
  restored.chooseColors(restored, palette)
  equal(#restored.rows, 3, "choosing a color again un-ignores it")
end)

test("choosing colors keeps edited families and reports removals in a dry run", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(200, 40, 40), rgb(40, 200, 40), rgb(40, 40, 200) }))
  model.editShade(model, 1, "highlight", rgb(250, 250, 0))
  local keepId = model.rows[1].id
  local removed = model.chooseColors(model, entries({ rgb(200, 40, 40), rgb(1, 1, 1) }), true)
  equal(#removed, 2)
  equal(#model.rows, 3, "dry run does not change the model")
  model.chooseColors(model, entries({ rgb(200, 40, 40), rgb(1, 1, 1) }))
  equal(#model.rows, 2)
  equal(model.rows[1].id, keepId)
  equal(model.rows[1].shades.highlight.color.b, 0)
  equal(Model.hasUserEdits(model.rows[1]), true)
  equal(Model.hasUserEdits(model.rows[2]), false)
end)

test("3/5 switching after sync keeps the same families and hidden pins", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(120, 80, 60) }))
  model.setShadeCount(model, 5)
  model.editShade(model, 1, "deepShadow", rgb(5, 5, 5))
  model.setShadeCount(model, 3)
  model.syncSource(model, entries({ rgb(120, 80, 60) }))
  model.setShadeCount(model, 5)
  equal(#model.colorsForRow(model, model.rows[1]), 5)
  equal(model.rows[1].shades.deepShadow.color.r, 5)
end)

test("Light reads exactly the families, including pinned shades", function()
  local model = Model.new(Color)
  model.chooseColors(model, entries({ rgb(120, 80, 60) }))
  model.editShade(model, 1, "highlight", rgb(250, 240, 10))
  local families = model.shadeFamilies(model, 3)
  equal(#families, 1)
  equal(families[1].colors[3].g, 240)
  local pixels = { { r = 120, g = 80, b = 60, a = 255 } }
  local geometry = { outline = {}, normals = { x = { 1 }, y = { 0 }, z = { 0 } } }
  local out = Light.render(pixels, 1, 1, families, geometry, { levels = 3, directionX = 1, directionY = 0, elevation = 1, strength = 2 })
  equal(out[1].g, 240)
end)

test("grid: native box size, initial height only, then scrolls", function()
  equal(Grid.initialHeight(0, 3), Grid.initialHeight(Grid.MIN_ROWS, 3))
  equal(Grid.initialHeight(64, 3), Grid.initialHeight(Grid.DEFAULT_ROWS, 3))
  equal(Grid.initialHeight(64, 3, 11, 1), Grid.TOOLBAR_H + 16 * 12 + 1)
  local layout = Grid.layout(Grid.WIDTH, 3)
  equal(layout.cell, 11, "same as Aseprite's default palette box size")
  equal(layout.rowH, 12, "cells touch, separated by one 1px line")
  local top = Grid.TOOLBAR_H
  local h = Grid.initialHeight(64, 3)
  assert(Grid.maxScroll(layout, h, 64, top) > 0, "64 families scroll")
  equal(Grid.maxScroll(layout, h, 3, top), 0)
  local first, last = Grid.visibleRange(layout, h, 64, layout.rowH * 40, top)
  assert(first >= 40 and last <= 64 and last - first <= Grid.DEFAULT_ROWS + 1)
end)

test("cells sit edge to edge like the native palette; the block is as narrow as possible", function()
  for _, count in ipairs({ 3, 5 }) do
    for _, box in ipairs({ 7, 11, 16 }) do
      local width = Grid.naturalWidth(count, box, 1)
      equal(width, count * box + count + 1 + Grid.RIGHT_PAD)
      local layout = Grid.layout(width, count, box, 1)
      equal(layout.cell, box)
      equal(layout.left, 0, "no side margin at the natural width")
      for i = 2, count do
        equal(layout.columns[i].x - (layout.columns[i - 1].x + box), 1, "exactly one separator pixel")
      end
      equal(layout.right + Grid.RIGHT_PAD, width)
      local noLines = Grid.layout(Grid.naturalWidth(count, box, 0), count, box, 0)
      equal(noLines.columns[2].x - noLines.columns[1].x, box, "entries_separator off: no lines at all")
    end
  end
  equal(Grid.WIDTH, 40, "3 shades at box 11: 40 logical px wide")
  local wide = Grid.layout(300, 3, 11, 1)
  equal(wide.cell, 11, "wider windows never enlarge cells")
  assert(wide.left > 0 and math.abs((wide.left) - (300 - Grid.RIGHT_PAD - wide.right)) <= 1, "block is centered")
  local narrow = Grid.layout(25, 5, 11, 1)
  assert(narrow.cell < 11 and narrow.cell >= Grid.MIN_CELL, "narrower windows shrink cells")
  for _, count in ipairs({ 3, 5 }) do
    for width = Grid.RIGHT_PAD + (Grid.MIN_CELL + 1) * count + 1, 200 do
      assert(Grid.layout(width, count, 11, 1).right <= width - Grid.RIGHT_PAD, "fits at " .. width)
    end
  end
end)

test("hit-testing maps every cell at narrow, default and wide widths, with scrolling", function()
  for _, width in ipairs({ 30, Grid.WIDTH, 200 }) do
    for _, count in ipairs({ 3, 5 }) do
      local layout = Grid.layout(width, count, 11, 1)
      for i, column in ipairs(layout.columns) do
        local row, col = Grid.hit(layout, 4, 0, column.x + 1, Grid.rowTop(layout, 3, 0, 20) + 1, 20)
        equal(row, 3); equal(col, i)
      end
      equal(Grid.hit(layout, 4, 0, 5, 5, 20), nil, "toolbar is not a swatch")
      equal(Grid.hit(layout, 4, 0, layout.columns[1].x, Grid.rowTop(layout, 5, 0, 20) + 1, 20), nil, "below the last row")
      equal(Grid.hit(layout, 64, layout.rowH * 10, layout.columns[1].x, 21 + 1, 20), 11, "scrolling offsets hit-testing")
    end
  end
end)

test("toolbar: only Light and More, both always visible and clickable at any width", function()
  for _, width in ipairs({ 20, 26, 40, Grid.WIDTH, 300 }) do
    local items = Grid.toolbar(width)
    equal(#items, 2)
    equal(items[1].id, "light"); equal(items[2].id, "menu")
    assert(items[1].x >= 1, "never pushed off the left edge")
    assert(items[1].x + items[1].width <= items[2].x, "icons do not overlap")
    if width >= 2 * Grid.ICON + 3 then
      assert(items[2].x + items[2].width <= width, "fits at width " .. width)
    end
    equal(Grid.toolbarHit(width, items[1].x + 2, 4), "light")
    equal(Grid.toolbarHit(width, items[2].x + 2, 4), "menu")
  end
  local wide = Grid.toolbar(300)
  equal(wide[2].x + wide[2].width, 299, "right-aligned when there is room")
end)

test("PNG and other flat formats are recognized as unable to store families", function()
  local Persistence2 = Persistence
  equal(Persistence2.storesProperties("/a/b/hero.png"), false)
  equal(Persistence2.storesProperties("hero.GIF"), false)
  equal(Persistence2.storesProperties("/a/hero.aseprite"), true)
  equal(Persistence2.storesProperties("/a/hero.ase"), true)
  equal(Persistence2.storesProperties("Sprite-0001"), true)
  equal(Persistence2.storesProperties(""), true)
end)

test("persistence reports save failures instead of hiding them", function()
  local broken = { properties = function() error("read-only document") end }
  local ok, reason = Persistence.save(broken, "ns", Model.new(Color))
  equal(ok, false)
  assert(reason:match("read%-only"))
  local okNil, reasonNil = Persistence.save(nil, "ns", Model.new(Color))
  equal(okNil, false); assert(reasonNil)
  local _, status = Persistence.load(broken, "ns", Model, Color)
  equal(status, "error")
  local store = { paletteTrio = { version = 99, rows = {} } }
  local _, futureStatus = Persistence.load({ properties = function() return store end }, "ns", Model, Color)
  equal(futureStatus, "invalid")
end)

test("large palette performance: 256 native colors sync and regenerate quickly", function()
  local list = {}
  for i = 0, 255 do list[#list + 1] = rgb((i * 37) % 256, (i * 91) % 256, (i * 53) % 256) end
  local started = os.clock()
  local model = Model.new(Color)
  local deduped = Source.dedupe((function()
    local raw = {}
    for i, c in ipairs(list) do raw[i] = { r = c.r, g = c.g, b = c.b, a = 255, index = i - 1 } end
    return raw
  end)())
  model.syncSource(model, deduped)
  model.setShadeCount(model, 5)
  model.sortByLink(model)
  local report = model.syncSource(model, deduped)
  equal(report.kept, #deduped)
  local elapsed = os.clock() - started
  assert(elapsed < 2, string.format("took %.2fs", elapsed))
end)

test("palette order is kept unless the artist reorders; custom colors follow", function()
  local model = Model.new(Color)
  model.syncSource(model, { { color = rgb(1, 1, 1), index = 5 }, { color = rgb(2, 2, 2), index = 1 } })
  model.addCustom(model, rgb(9, 9, 9))
  model.sortByLink(model)
  equal(model.rows[1].base.r, 2); equal(model.rows[2].base.r, 1); equal(model.rows[3].base.r, 9)
  equal(model.addCustom(model, rgb(9, 9, 9)), nil, "no duplicate custom colors")
  model.moveRow(model, 3, -2)
  model.sortByLink(model)
  equal(model.rows[1].base.r, 9, "manual order wins")
  equal(Model.fromTable(Color, model.toTable(model)).manualOrder, true)
end)

test("2.0 stored data loads unchanged (schema v2 without new fields)", function()
  local data = {
    version = 2, shadeCount = 3, nextId = 3, settings = {},
    source = { kind = "artwork", label = "Artwork colors" }, ignored = { "1,2,3" },
    rows = { { id = 1, name = "x", base = rgb(10, 20, 30), shades = {} },
      { id = 2, name = "", base = rgb(40, 50, 60), link = { color = rgb(40, 50, 60), index = 4 }, shades = {} } },
  }
  local model, valid = Model.fromTable(Color, data)
  equal(valid, true)
  equal(model.source.kind, "artwork")
  equal(#model.rows, 2)
  equal(model.ignored["1,2,3"], true)
  equal(model.manualOrder, false)
  equal(next(model.generated), nil)
end)

------------------------------------------------------------------------------
-- 2.2 Light: family detection, eyedropper resolution, shade matching
------------------------------------------------------------------------------

local function lightFamilies()
  local model = Model.new(Color)
  model.newRow(model, rgb(180, 60, 50))   -- family 1 (red)
  model.newRow(model, rgb(60, 140, 200))  -- family 2 (blue)
  return model, model.shadeFamilies(model, 3)
end

local function px(c, a) return { r = c.r, g = c.g, b = c.b, a = a or 255 } end

test("detection: a base-colored object selects its family", function()
  local _, families = lightFamilies()
  local pixels = { px(families[2].base), px(families[2].base), px(rgb(0, 0, 0), 0) }
  local d = Light.detectFamily(pixels, families)
  equal(d.index, 2); equal(d.matched, 2); equal(d.opaque, 2); equal(d.share, 1)
end)

test("detection: shadow and highlight pixels still identify the family", function()
  local model, families = lightFamilies()
  local row = model.rows[1]
  local pixels = { px(row.shades.shadow.color), px(row.shades.highlight.color), px(row.shades.deepShadow.color) }
  local d = Light.detectFamily(pixels, families)
  equal(d.index, 1, "deep shadow counts even in 3-shade mode")
  equal(d.matched, 3)
end)

test("detection: mixed object picks the most frequent family; unknown colors are not counted", function()
  local model, families = lightFamilies()
  local pixels = {
    px(families[1].base), px(model.rows[2].shades.shadow.color), px(families[2].base),
    px(families[2].base), px(rgb(1, 2, 3)),
  }
  local d = Light.detectFamily(pixels, families)
  equal(d.index, 2); equal(d.count, 3); equal(d.matched, 4); equal(d.opaque, 5)
  equal(d.counts[1], 1)
  local none = Light.detectFamily({ px(rgb(1, 2, 3)) }, families)
  equal(none.index, nil, "no confident family when nothing matches")
end)

test("eyedropper resolution: exact for any shade; nearest only when clearly reliable", function()
  local model, families = lightFamilies()
  equal(Light.resolveColor(model.rows[1].shades.highlight.color, families, Color.rgbToOklab), 1)
  local index, how = Light.resolveColor(families[2].base, families, Color.rgbToOklab)
  equal(index, 2); equal(how, "exact")
  local near = { r = families[2].base.r + 2, g = families[2].base.g - 1, b = families[2].base.b + 1 }
  local nIndex, nHow = Light.resolveColor(near, families, Color.rgbToOklab)
  equal(nIndex, 2); equal(nHow, "near")
  equal(Light.resolveColor(rgb(120, 200, 40), families, Color.rgbToOklab), nil, "far colors are not guessed")
  equal(Light.resolveColor(near, families, nil), nil, "without a distance function only exact matches")
end)

test("render: shade pixels are re-shaded with their family; FG color is irrelevant", function()
  local model, families = lightFamilies()
  local shadow = model.rows[1].shades.shadow.color
  local pixels = { px(shadow), px(shadow) }
  local geometry = { outline = {}, normals = { x = { 1, -1 }, y = { 0, 0 }, z = { 0, 0 } } }
  local opts = { levels = 3, directionX = 1, directionY = 0, elevation = 1, strength = 2, matchShades = true }
  local out = Light.render(pixels, 2, 1, families, geometry, opts)
  local lit = families[1].colors[3]
  equal(out[1].r, lit.r); equal(out[1].g, lit.g)
  local old = Light.render(pixels, 2, 1, families, geometry, { levels = 3, directionX = 1, directionY = 0, elevation = 1, strength = 2 })
  equal(old[1].r, shadow.r, "without matchShades only bases are shaded (2.1 behavior)")
end)

test("render: explicit family shades unknown-colored pixels; other families and exclusions keep theirs", function()
  local model, families = lightFamilies()
  local pixels = { px(rgb(9, 9, 9)), px(families[2].base), px(rgb(1, 1, 1)), px(rgb(5, 5, 5), 0) }
  local geometry = { outline = {}, normals = { x = { 1, 1, 1, 1 }, y = { 0, 0, 0, 0 }, z = { 0, 0, 0, 0 } } }
  local out = Light.render(pixels, 4, 1, families, geometry, {
    levels = 3, directionX = 1, directionY = 0, elevation = 1, strength = 2,
    matchShades = true, fallbackFamily = 1, excludedColors = { rgb(1, 1, 1) },
  })
  local lit1, lit2 = families[1].colors[3], families[2].colors[3]
  equal(out[1].r, lit1.r, "unknown color uses the chosen family")
  equal(out[2].r, lit2.r, "other family keeps its own family")
  equal(out[3].r, 1, "excluded color untouched")
  equal(out[4].a, 0, "transparent untouched")
  local _ = model
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
assert(failed == 0, string.format("%d acceptance test(s) failed", failed))
