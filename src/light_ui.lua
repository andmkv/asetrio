local UI = {}

local PREVIEW_WIDTH, PREVIEW_HEIGHT = 224, 150

-- Shape list shown in the dialog. Cylinder orientation is part of the shape,
-- so there is no separate Axis row. Stored layer values stay the same.
local SHAPE_OPTIONS = {
  { label = "Sphere", shape = "Round / Sphere" },
  { label = "Box (bevel)", shape = "Box / Beveled rectangle" },
  { label = "Cylinder (horizontal)", shape = "Cylinder", axis = "Horizontal" },
  { label = "Cylinder (vertical)", shape = "Cylinder", axis = "Vertical" },
  { label = "Contour", shape = "Contour / Auto Relief" },
}
UI.SHAPE_OPTIONS = SHAPE_OPTIONS

local function shapeLabels()
  local labels = {}
  for i, option in ipairs(SHAPE_OPTIONS) do labels[i] = option.label end
  return labels
end

function UI.shapeLabel(layer)
  for _, option in ipairs(SHAPE_OPTIONS) do
    if option.shape == layer.shape and (not option.axis or option.axis == layer.cylinderAxis) then return option.label end
  end
  return SHAPE_OPTIONS[1].label
end

-- Applies a shape label to layer settings. Returns true if the shape changed.
function UI.applyShapeLabel(layer, label)
  for _, option in ipairs(SHAPE_OPTIONS) do
    if option.label == label then
      local changed = layer.shape ~= option.shape or (option.axis ~= nil and layer.cylinderAxis ~= option.axis)
      layer.shape = option.shape
      if option.axis then layer.cylinderAxis = option.axis end
      return changed
    end
  end
  return false
end

-- One "Form" slider: bevel width for Box, curvature (%) for Cylinder and
-- Contour, unused for Sphere.
function UI.formRange(layer)
  if layer.shape == "Box / Beveled rectangle" then return 1, 24, math.floor(layer.bevel + 0.5), true end
  if layer.shape == "Cylinder" or layer.shape == "Contour / Auto Relief" then
    return 25, 300, math.floor(layer.curvature * 100 + 0.5), true
  end
  return 0, 100, 0, false
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function parseExcluded(text)
  local colors, seen = {}, {}
  text = type(text) == "string" and text or ""
  for token in text:gmatch("[^,;%s]+") do
    local hex = token:gsub("^#", "")
    if #hex == 6 and hex:match("^%x%x%x%x%x%x$") then
      local color = {
        r = tonumber(hex:sub(1, 2), 16),
        g = tonumber(hex:sub(3, 4), 16),
        b = tonumber(hex:sub(5, 6), 16),
      }
      local key = string.format("%d,%d,%d", color.r, color.g, color.b)
      if not seen[key] then colors[#colors + 1], seen[key] = color, true end
    end
  end
  return colors
end

local function formatExcluded(colors)
  local parts = {}
  for _, color in ipairs(colors or {}) do
    parts[#parts + 1] = string.format("#%02X%02X%02X", color.r, color.g, color.b)
  end
  return table.concat(parts, ", ")
end

local function wrapText(gc, text, maxWidth)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if line ~= "" and gc:measureText(candidate).width > maxWidth then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- status: short line under the preview. message: longer explanation drawn in
-- the empty preview area (labels cannot wrap).
local function setStatus(ctx, text, message)
  ctx.light.status = text
  ctx.light.message = message
  if ctx.lightDialog then
    pcall(function() ctx.lightDialog:modify { id = "lightStatus", text = text } end)
    ctx.lightDialog:repaint()
  end
end

local function currentFrameNumber()
  local frame = app.frame
  return frame and frame.frameNumber or 1
end

local function getLayerRecords(ctx)
  local sprite = app.sprite
  if not sprite then return {}, nil, nil, "Open an RGB sprite to use Palette Trio Light." end
  local frameNumber = currentFrameNumber()
  local records = ctx.lightAseprite.sourceLayers(sprite, frameNumber, ctx.namespace)
  return records, sprite, frameNumber
end

local function selectedRecord(ctx, records)
  local record = ctx.lightAseprite.findSource(records, ctx.light.sourceLayerUuid)
  if record then return record end
  local siteLayer = app.layer
  for _, item in ipairs(records) do
    if item.layer == siteLayer then return item end
  end
  return records[1]
end

local function updateFamilyControls(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  pcall(function()
    dlg:modify { id = "autoFamily", enabled = ctx.light.layer and ctx.light.layer.familyRowId ~= nil }
  end)
  dlg:repaint()
end

local function updateDialogData(ctx, preserveExcludedText)
  local dlg = ctx.lightDialog
  if not dlg then return end
  local shared, layer = ctx.light.shared, ctx.light.layer
  local data = dlg.data
  data.sourceLayer = ctx.light.sourceOption or data.sourceLayer
  data.shape = UI.shapeLabel(layer)
  data.material = layer.material
  if not preserveExcludedText then
    data.excludedColors = formatExcluded(layer.excludedColors)
  end
  data.lightHeight = math.floor((shared.lightHeight or 32) + 0.5)
  data.falloff = math.floor(shared.falloff + 0.5)
  data.lightStrength = math.floor(shared.strength * 100 + 0.5)
  data.levels = tostring(shared.levels)
  data.dither = shared.dither == "Off" and "No dither" or shared.dither
  data.preserveOutlines = shared.preserveOutlines
  data.separateComponents = shared.separateComponents
  dlg.data = data
  -- enabled (not visible) toggles: changing visibility forces a relayout,
  -- which Aseprite 1.3.17 may not fully redraw (stale "ghost" pixels).
  local min, max, value, enabled = UI.formRange(layer)
  dlg:modify { id = "form", min = min, max = max, value = value, enabled = enabled }
  updateFamilyControls(ctx)
end

local function readDialogSettings(ctx)
  local data = ctx.lightDialog and ctx.lightDialog.data or {}
  local shared, layer = ctx.light.shared, ctx.light.layer
  shared.lightHeight = clamp(tonumber(data.lightHeight) or shared.lightHeight or 32, 1, 4096)
  shared.falloff = clamp(tonumber(data.falloff) or shared.falloff, 0, 100)
  shared.strength = clamp((tonumber(data.lightStrength) or (shared.strength * 100)) / 100, 0, 2)
  shared.levels = data.levels == "5" and 5 or 3
  if data.dither == "Bayer 2x2" or data.dither == "Bayer 4x4" then shared.dither = data.dither else shared.dither = "Off" end
  shared.preserveOutlines = data.preserveOutlines == true
  shared.separateComponents = data.separateComponents == true
  local shapeChanged = data.shape ~= nil and UI.applyShapeLabel(layer, data.shape)
  layer.material = data.material == "Glossy" and "Glossy" or "Matte"
  -- The Form slider means bevel or curvature depending on the shape; after a
  -- shape change its old value belongs to the previous meaning.
  local form = tonumber(data.form)
  if form and not shapeChanged then
    if layer.shape == "Box / Beveled rectangle" then
      layer.bevel = clamp(form, 1, 64)
    elseif layer.shape == "Cylinder" or layer.shape == "Contour / Auto Relief" then
      layer.curvature = clamp(form / 100, 0.25, 3)
    end
  end
  layer.excludedColors = parseExcluded(data.excludedColors)
end

local function saveSettings(ctx)
  local sprite = app.sprite
  local source = ctx.light.sourceRecord
  if not sprite or not source then return end
  local ok, reason = pcall(function()
    app.transaction("Save Palette Trio Light settings", function()
      assert(ctx.lightAseprite.saveShared(sprite, ctx.namespace, ctx.light.shared), "Could not store sprite light settings")
      assert(ctx.lightAseprite.saveLayerSettings(source.layer, ctx.namespace, ctx.light.layer), "Could not store layer shading settings")
    end)
  end)
  if not ok then setStatus(ctx, "Settings could not be saved: " .. tostring(reason)) end
end

local function selectSource(ctx, persist)
  local data = ctx.lightDialog.data
  local uuid = ctx.light.optionToUuid[data.sourceLayer]
  if not uuid then
    ctx.light.sourceRecord = nil
    return false
  end
  ctx.light.sourceLayerUuid = uuid
  ctx.light.sourceOption = data.sourceLayer
  local records, sprite = getLayerRecords(ctx)
  ctx.light.sourceRecord = ctx.lightAseprite.findSource(records, uuid)
  ctx.light.shared.sourceLayerUuid = uuid
  ctx.light.layer = ctx.lightAseprite.loadLayerSettings(ctx.light.sourceRecord and ctx.light.sourceRecord.layer, ctx.namespace)
  if sprite then ctx.light.shared = ctx.lightAseprite.normalizeShared(ctx.light.shared) end
  if persist then saveSettings(ctx) end
  updateDialogData(ctx)
  return ctx.light.sourceRecord ~= nil
end

-- Bounding box of the opaque pixels of a cel (cel-local), or nil if empty.
function UI.objectBounds(data)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for y = 0, data.height - 1 do
    for x = 0, data.width - 1 do
      local p = data.pixels[y * data.width + x + 1]
      if p and (p.a or 0) > 0 then
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
      end
    end
  end
  if minX == math.huge then return nil end
  return { x = minX, y = minY, width = maxX - minX + 1, height = maxY - minY + 1,
    centerX = (minX + maxX + 1) / 2, centerY = (minY + maxY + 1) / 2,
    size = math.max(maxX - minX + 1, maxY - minY + 1) }
end

-- First use: place the point light where the old direction/elevation pointed,
-- at a height equal to the object size, so existing settings look the same.
local function ensureLight(ctx, data, celX, celY)
  local shared = ctx.light.shared
  if shared.lightX and shared.lightY and shared.lightHeight then return end
  local bounds = UI.objectBounds(data) or { centerX = data.width / 2, centerY = data.height / 2,
    size = math.max(data.width, data.height) }
  shared.lightHeight = shared.lightHeight or math.max(4, math.floor(bounds.size + 0.5))
  local lx, ly = ctx.lightEngine.pointFromDirection(shared.directionX, shared.directionY, shared.elevation,
    bounds.centerX, bounds.centerY, shared.lightHeight)
  shared.lightX, shared.lightY = math.floor(celX + lx + 0.5), math.floor(celY + ly + 0.5)
  updateDialogData(ctx, true)
end

-- Moves the light to a preview point (stored in sprite coordinates).
local function moveLightTo(ctx, sx, sy)
  local t, source = ctx.light.viewT, ctx.light.previewSource
  if not t or not source then return end
  local cx, cy = ctx.lightView.toCel(t, sx, sy)
  ctx.light.shared.lightX = math.floor(source.position.x + cx + 0.5)
  ctx.light.shared.lightY = math.floor(source.position.y + cy + 0.5)
  UI.regeneratePreview(ctx)
end

local function drawPreview(ctx, ev)
  local gc = ev.context
  local width, height = gc.width, gc.height
  ctx.light.canvasW, ctx.light.canvasH = width, height
  gc.color = Color { r = 44, g = 44, b = 48 }
  gc:fillRect(Rectangle(0, 0, width, height))
  local image = ctx.light.previewImage
  if not image then
    gc.color = Color { r = 220, g = 220, b = 220 }
    local message = ctx.light.message or ctx.light.status or "Choose a visible source layer."
    for i, line in ipairs(wrapText(gc, message, width - 20)) do
      gc:fillText(line, 10, 10 + (i - 1) * 13)
    end
    ctx.light.viewT = nil
    return
  end
  local View = ctx.lightView
  local t = View.transform(ctx.light.view, width, height, image.width, image.height)
  ctx.light.viewT = t
  local drawW, drawH = image.width * t.scale, image.height * t.scale
  -- Checkerboard only under the cel, so the cel's extent is visible.
  local tile = math.max(4, math.floor(t.scale * 4))
  gc:save()
  pcall(function()
    gc:beginPath()
    gc:rect(Rectangle(t.originX, t.originY, drawW, drawH))
    gc:clip()
  end)
  for y = math.floor(t.originY), t.originY + drawH, tile do
    for x = math.floor(t.originX), t.originX + drawW, tile do
      if ((math.floor((x - t.originX) / tile) + math.floor((y - t.originY) / tile)) % 2) == 0 then
        gc.color = Color { r = 58, g = 58, b = 63 }
        gc:fillRect(Rectangle(x, y, tile, tile))
      end
    end
  end
  gc:restore()
  gc:save()
  gc.opacity = clamp(tonumber(ctx.light.previewSource and ctx.light.previewSource.opacity) or 255, 0, 255)
  gc:drawImage(image, 0, 0, image.width, image.height, t.originX, t.originY, drawW, drawH)
  gc:restore()

  -- Light marker (a sun) with a guide line to the object's center. When the
  -- light is outside the view, the marker sits on the edge, hollow.
  local shared, source = ctx.light.shared, ctx.light.previewSource
  if shared.lightX and source then
    local bounds = ctx.light.objectBounds
    local ox, oy = bounds and bounds.centerX or image.width / 2, bounds and bounds.centerY or image.height / 2
    local cx, cy = View.toScreen(t, ox, oy)
    local mx, my = View.toScreen(t, shared.lightX - source.position.x + 0.5, shared.lightY - source.position.y + 0.5)
    local inside = mx >= 0 and my >= 0 and mx <= width and my <= height
    local ex, ey = clamp(mx, 6, width - 6), clamp(my, 6, height - 6)
    local yellow = Color { r = 246, g = 224, b = 109 }
    gc.strokeWidth = 1
    gc.color = yellow
    gc:beginPath()
    gc:moveTo(cx, cy)
    gc:lineTo(ex, ey)
    gc:stroke()
    gc.color = Color { r = 30, g = 24, b = 20 }
    gc:fillRect(Rectangle(ex - 5, ey - 5, 11, 11))
    gc.color = yellow
    if inside then
      gc:fillRect(Rectangle(ex - 4, ey - 4, 9, 9))
    else
      gc:strokeRect(Rectangle(ex - 4, ey - 4, 9, 9))
    end
    gc:fillRect(Rectangle(ex, ey - 8, 1, 3)); gc:fillRect(Rectangle(ex, ey + 6, 1, 3))
    gc:fillRect(Rectangle(ex - 8, ey, 3, 1)); gc:fillRect(Rectangle(ex + 6, ey, 3, 1))
  end
  -- Family strip in the top-left corner: the colors Light will use.
  local family = ctx.light.activeFamily
  if family then
    local cell = 8
    for i, c in ipairs(family.colors) do
      gc.color = Color { r = c.r, g = c.g, b = c.b }
      gc:fillRect(Rectangle(4 + (i - 1) * cell, 4, cell, cell))
    end
    gc.color = Color { r = 0, g = 0, b = 0 }
    gc:strokeRect(Rectangle(3, 3, #family.colors * cell + 2, cell + 2))
    gc.color = Color { r = 200, g = 200, b = 205 }
    gc:fillText(ctx.light.layer.familyRowId and "picked" or "auto", 8 + #family.colors * cell, 3)
  end
  gc.color = Color { r = 150, g = 150, b = 155 }
  if ctx.light.picking then
    gc.color = Color { r = 246, g = 224, b = 109 }
    gc:strokeRect(Rectangle(0, 0, width, height))
    gc:fillText("Click the object to pick its family", 4, height - 12)
  else
    gc:fillText("Drag: light  Wheel: zoom  Alt+drag: pan", 4, height - 12)
  end
end

-- Maps a preview point to the source pixel shown there, or nil.
function UI.previewPixel(ctx, x, y)
  local t, source = ctx.light.viewT, ctx.light.previewSource
  if not t or not source then return nil end
  local cx, cy = ctx.lightView.toCel(t, x, y)
  local px, py = math.floor(cx), math.floor(cy)
  if px < 0 or py < 0 or px >= source.width or py >= source.height then return nil end
  return source.pixels[py * source.width + px + 1]
end

-- Eyedropper: resolves the clicked color to a family (any shade counts).
-- Nearest-color matching is used only when one family is clearly closest.
function UI.pickAt(ctx, x, y)
  ctx.light.picking = false
  pcall(function() ctx.lightDialog:modify { id = "pick", text = "Pick" } end)
  local pixel = UI.previewPixel(ctx, x, y)
  if not pixel or (pixel.a or 0) == 0 then
    setStatus(ctx, "Click inside the object to pick")
    UI.regeneratePreview(ctx)
    return false
  end
  local families = ctx.model.shadeFamilies(ctx.model, ctx.light.shared.levels)
  local index, how = ctx.lightEngine.resolveColor(pixel, families, ctx.color.rgbToOklab)
  if not index then
    UI.regeneratePreview(ctx)
    setStatus(ctx, "That color is not in any family")
    return false
  end
  ctx.light.layer.familyRowId = families[index].rowId
  updateDialogData(ctx, true)
  saveSettings(ctx)
  UI.regeneratePreview(ctx)
  setStatus(ctx, how == "near" and "Picked the closest family" or "Picked this family")
  return true
end

function UI.regeneratePreview(ctx)
  if not ctx.lightDialog then return false end
  if not app.sprite then
    ctx.light.previewImage = nil
    setStatus(ctx, "No sprite", "Open an RGB sprite to preview lighting.")
    return false
  end
  if app.sprite ~= ctx.light.sprite then UI.reload(ctx); if app.sprite ~= ctx.light.sprite then return false end end
  if not ctx.lightAseprite.isRgbSprite(app.sprite) then
    ctx.light.previewImage = nil
    setStatus(ctx, "RGB sprites only", "Palette Trio Light processes RGB sprites only. Indexed and grayscale sprites are not modified.")
    return false
  end
  local records, sprite, frameNumber = getLayerRecords(ctx)
  local source = ctx.lightAseprite.findSource(records, ctx.light.sourceLayerUuid)
  if not source then
    ctx.light.previewImage = nil
    setStatus(ctx, "No source cel", "The chosen layer has no visible cel in this frame. Pick another layer or click Refresh.")
    ctx.lightDialog:repaint()
    return false
  end
  local familySnapshot = ctx.model.shadeFamilies(ctx.model, ctx.light.shared.levels)
  if #familySnapshot == 0 then
    ctx.light.previewImage = nil
    setStatus(ctx, "No shade families", "Light shades pixels using Palette Trio's families, and there are none yet. Click Colors... to add base colors.")
    ctx.lightDialog:repaint()
    return false
  end
  local snapshotKey = source.uuid .. ":" .. tostring(frameNumber)
  local original = ctx.lightAseprite.snapshotSource(ctx.light.snapshots[snapshotKey], source.cel)
  local data, reason = ctx.lightAseprite.readCel(source.cel, original)
  ctx.light.usingSnapshot = original ~= nil
  if not data then
    ctx.light.previewImage = nil
    setStatus(ctx, "Cannot read cel", reason)
    ctx.lightDialog:repaint()
    return false
  end
  local maskKey = ctx.lightEngine.silhouetteKey(data.pixels, data.width, data.height)
  local cache = ctx.light.cache
  if cache.silhouetteKey ~= maskKey then
    cache.mask, cache.silhouetteKey = ctx.lightEngine.extractSilhouette(data.pixels, data.width, data.height)
  end
  local geometry, cacheHit = ctx.lightEngine.buildGeometry(
    cache.mask, data.width, data.height, ctx.light.layer, cache, maskKey)
  if cache.boundsKey ~= maskKey then
    cache.bounds, cache.boundsKey = UI.objectBounds(data), maskKey
  end
  ctx.light.objectBounds = cache.bounds
  ensureLight(ctx, data, source.cel.position.x, source.cel.position.y)
  local detection = ctx.lightEngine.detectFamily(data.pixels, familySnapshot, ctx.light.layer.excludedColors)
  ctx.light.detection = detection
  local chosen = nil
  local chosenRowId = ctx.light.layer.familyRowId
  if chosenRowId then
    for i, family in ipairs(familySnapshot) do
      if family.rowId == chosenRowId then chosen = i; break end
    end
  end
  ctx.light.chosenIndex = chosen
  ctx.light.activeFamily = familySnapshot[chosen or detection.index or 0]
  local options = {
    matchShades = true,
    fallbackFamily = chosen,
    material = ctx.light.layer.material,
    levels = ctx.light.shared.levels,
    directionX = ctx.light.shared.directionX,
    directionY = ctx.light.shared.directionY,
    elevation = ctx.light.shared.elevation,
    strength = ctx.light.shared.strength,
    dither = ctx.light.shared.dither,
    preserveOutlines = ctx.light.shared.preserveOutlines,
    excludedColors = ctx.light.layer.excludedColors,
    offsetX = source.cel.position.x,
    offsetY = source.cel.position.y,
    pointLight = {
      x = ctx.light.shared.lightX - source.cel.position.x,
      y = ctx.light.shared.lightY - source.cel.position.y,
      z = ctx.light.shared.lightHeight,
      falloff = ctx.light.shared.falloff / 100,
      size = cache.bounds and cache.bounds.size or math.max(data.width, data.height),
    },
  }
  local output, stats = ctx.lightEngine.render(data.pixels, data.width, data.height, familySnapshot, geometry, options)
  ctx.light.previewImage = ctx.lightAseprite.makeImage(data.width, data.height, output)
  ctx.light.sourceRecord = source
  ctx.light.previewOutput, ctx.light.previewSource = output, data
  ctx.light.previewFrameNumber = frameNumber
  ctx.light.sprite = sprite
  local _ = cacheHit
  local fromOriginal = ctx.light.usingSnapshot and " · from original" or ""
  if stats.shaded == 0 then
    setStatus(ctx, "No family found · use Pick", "This layer has no Palette Trio colors. Click Pick and then the object to shade it with that family.")
  elseif chosen then
    setStatus(ctx, string.format("Picked family · %d px shaded%s", stats.shaded, fromOriginal))
  else
    setStatus(ctx, string.format("Auto family (%d%%) · %d px shaded%s",
      math.floor(detection.share * 100 + 0.5), stats.shaded, fromOriginal))
  end
  updateFamilyControls(ctx)
  ctx.lightDialog:repaint()
  return true
end

local OUTPUT_NEW, OUTPUT_REPLACE = "New layer", "Replace source"
UI.OUTPUT_NEW, UI.OUTPUT_REPLACE = OUTPUT_NEW, OUTPUT_REPLACE

local function alert(ctx, options)
  return (ctx.alert or app.alert)(options)
end

local function applyOutput(ctx)
  if not UI.regeneratePreview(ctx) then return false end
  local sprite = app.sprite
  local source = ctx.light.sourceRecord
  local frameNumber = ctx.light.previewFrameNumber
  if not sprite or sprite ~= ctx.light.sprite or not source or not ctx.light.previewOutput then
    setStatus(ctx, "The source changed before Apply. Click Apply again.")
    return false
  end
  local image = ctx.lightAseprite.makeImage(ctx.light.previewSource.width, ctx.light.previewSource.height, ctx.light.previewOutput)
  if ctx.light.outputMode == OUTPUT_REPLACE then
    local answer = alert(ctx, {
      title = "Replace source pixels?",
      text = {
        string.format("Overwrite layer \"%s\" on frame %d with the shaded result?", source.layer.name or "Layer", frameNumber),
        "Only this cel changes; transparency and unmatched colors are kept. Undo restores it.",
        "While Aseprite stays open, applying again re-shades the original pixels.",
        "The original is NOT saved in the file. After a restart, or if you edit the layer,",
        "the shaded pixels become the new source. Keep a copy of the unshaded layer.",
      },
      buttons = { "Replace", "Cancel" },
    })
    if answer ~= 1 then return false end
    local key = source.uuid .. ":" .. tostring(frameNumber)
    local previous = ctx.light.snapshots[key]
    local keepOriginal = ctx.lightAseprite.snapshotSource(previous, source.cel)
    local success, result = ctx.lightAseprite.replaceSource(sprite, source, frameNumber, image)
    if not success then
      alert(ctx, { title = "Palette Trio Light", text = tostring(result), buttons = "OK" })
      return false
    end
    if keepOriginal then result.original = keepOriginal end
    ctx.light.snapshots[key] = result
    setStatus(ctx, string.format("Frame %d · source replaced (Undo restores it)", frameNumber))
    return true
  end
  local success, result = ctx.lightAseprite.applyOutput(
    sprite, source, frameNumber, image, source.cel, ctx.light.layer, ctx.namespace)
  if not success then
    alert(ctx, { title = "Palette Trio Light", text = tostring(result), buttons = "OK" })
    return false
  end
  setStatus(ctx, string.format("Frame %d · output layer updated", frameNumber))
  return true
end
UI.applyOutput = applyOutput

local function persistAndPreview(ctx)
  readDialogSettings(ctx)
  saveSettings(ctx)
  updateDialogData(ctx, true)
  UI.regeneratePreview(ctx)
end

-- Reads layers and stored settings for the active sprite (no UI changes).
local function loadState(ctx)
  local records, sprite = getLayerRecords(ctx)
  ctx.light.sprite = sprite
  ctx.light.optionToUuid, ctx.light.uuidToOption = {}, {}
  local options = {}
  for _, record in ipairs(records) do
    options[#options + 1] = record.label
    ctx.light.optionToUuid[record.label] = record.uuid
    ctx.light.uuidToOption[record.uuid] = record.label
  end
  if #options == 0 then options[1] = sprite and "(no visible image layer)" or "(no sprite)" end
  ctx.light.options = options

  ctx.light.shared = ctx.lightAseprite.loadShared(sprite, ctx.namespace)
  local hasShared = sprite ~= nil and pcall(function()
    assert(sprite.properties(ctx.namespace).paletteTrioLightShared ~= nil)
  end)
  if not hasShared then ctx.light.shared.levels = ctx.model.shadeCount end
  local preferred = ctx.light.sourceLayerUuid ~= "" and ctx.light.sourceLayerUuid or ctx.light.shared.sourceLayerUuid
  local chosen = ctx.lightAseprite.findSource(records, preferred) or selectedRecord(ctx, records)
  ctx.light.sourceRecord = chosen
  ctx.light.sourceLayerUuid = chosen and chosen.uuid or ""
  ctx.light.sourceOption = chosen and chosen.label or options[1]
  ctx.light.shared.sourceLayerUuid = ctx.light.sourceLayerUuid
  ctx.light.layer = ctx.lightAseprite.loadLayerSettings(chosen and chosen.layer, ctx.namespace)
end

local function updateApplyButton(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  local replace = ctx.light.outputMode == OUTPUT_REPLACE
  dlg:modify { id = "applyLight", text = replace and "Replace source..." or "Apply to new layer" }
end

local function buildDialog(ctx)
  loadState(ctx)
  local options = ctx.light.options
  local dlg = Dialog {
    title = "Palette Trio Light",
    resizeable = true,
    onclose = function()
      pcall(function()
        local b = ctx.lightDialog.bounds
        if ctx.preferences and b.width >= 60 and b.height >= 60 then
          ctx.preferences.lightBounds = { x = b.x, y = b.y, width = b.width, height = b.height }
        end
      end)
      ctx.lightDialog = nil
      ctx.light.picking = false
      if ctx.ui then pcall(ctx.ui.repaint, ctx) end
    end,
  }
  if not dlg then return end
  ctx.lightDialog = dlg
  local function previewChange()
    readDialogSettings(ctx)
    updateDialogData(ctx, true)
    UI.regeneratePreview(ctx)
  end
  dlg:combobox {
    id = "sourceLayer", label = "Layer", options = options,
    option = ctx.light.sourceOption,
    onchange = function()
      selectSource(ctx, true)
      UI.regeneratePreview(ctx)
    end,
  }
  -- Shape and Material share a row: their options explain themselves.
  dlg:combobox { id = "shape", label = "Shape", options = shapeLabels(), option = UI.shapeLabel(ctx.light.layer),
    onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "material", options = ctx.lightEngine.MATERIALS, option = ctx.light.layer.material,
    onchange = function() persistAndPreview(ctx) end }
  local formMin, formMax, formValue, formEnabled = UI.formRange(ctx.light.layer)
  dlg:slider { id = "form", label = "Form", min = formMin, max = formMax, value = formValue, enabled = formEnabled,
    onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:button { id = "pick", label = "Family", text = "Pick", onclick = function()
    ctx.light.picking = not ctx.light.picking
    dlg:modify { id = "pick", text = ctx.light.picking and "Picking..." or "Pick" }
    pcall(function() dlg:modify { id = "lightPreview", mousecursor = ctx.light.picking and MouseCursor.CROSSHAIR or MouseCursor.ARROW } end)
    if ctx.light.picking then setStatus(ctx, "Click the object in the preview") end
    dlg:repaint()
  end }
  dlg:button { id = "autoFamily", text = "Auto", onclick = function()
    ctx.light.layer.familyRowId = nil
    saveSettings(ctx)
    UI.regeneratePreview(ctx)
  end }
  dlg:newrow()
  dlg:canvas {
    id = "lightPreview", width = PREVIEW_WIDTH, height = PREVIEW_HEIGHT,
    autoscaling = true, hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ctx, ev) end,
    onmousedown = function(ev)
      -- Pick mode (or right-click): eyedropper. Middle or Alt/Shift+drag:
      -- pan. Otherwise place / drag the light anywhere.
      if (ctx.light.picking and ev.button == MouseButton.LEFT) or ev.button == MouseButton.RIGHT then
        UI.pickAt(ctx, ev.x, ev.y)
        pcall(function() dlg:modify { id = "lightPreview", mousecursor = MouseCursor.ARROW } end)
        return
      end
      if ev.button == MouseButton.MIDDLE or (ev.button == MouseButton.LEFT and (ev.altKey or ev.shiftKey)) then
        ctx.light.panning = { x = ev.x, y = ev.y }
        return
      end
      if ev.button == MouseButton.LEFT and ctx.light.viewT then
        ctx.light.beforeDrag = { x = ctx.light.shared.lightX, y = ctx.light.shared.lightY }
        ctx.light.dragging = true
        moveLightTo(ctx, ev.x, ev.y)
      end
    end,
    onmousemove = function(ev)
      if ctx.light.panning then
        ctx.lightView.pan(ctx.light.view, ev.x - ctx.light.panning.x, ev.y - ctx.light.panning.y)
        ctx.light.panning = { x = ev.x, y = ev.y }
        dlg:repaint()
      elseif ctx.light.dragging then
        moveLightTo(ctx, ev.x, ev.y)
      end
    end,
    onmouseup = function()
      ctx.light.panning = nil
      if ctx.light.dragging then
        ctx.light.dragging = false
        saveSettings(ctx)
      end
    end,
    onwheel = function(ev)
      local image = ctx.light.previewImage
      if not image or not ctx.light.viewT then return end
      local steps = (ev.deltaY or 0) > 0 and 1 or ((ev.deltaY or 0) < 0 and -1 or 0)
      local gcW = ctx.light.canvasW or PREVIEW_WIDTH
      local gcH = ctx.light.canvasH or PREVIEW_HEIGHT
      ctx.lightView.zoomAt(ctx.light.view, gcW, gcH, image.width, image.height, ev.x, ev.y, steps)
      dlg:repaint()
    end,
    ondblclick = function()
      -- Fit the view; the first click of the double-click does not move the light.
      if ctx.light.beforeDrag and ctx.light.beforeDrag.x then
        ctx.light.shared.lightX, ctx.light.shared.lightY = ctx.light.beforeDrag.x, ctx.light.beforeDrag.y
      end
      ctx.lightView.reset(ctx.light.view)
      UI.regeneratePreview(ctx)
    end,
  }
  dlg:newrow()
  dlg:label { id = "lightStatus", text = "Preparing preview..." }
  dlg:slider { id = "lightHeight", label = "Height", min = 1, max = 256, value = math.floor((ctx.light.shared.lightHeight or 32) + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "falloff", label = "Falloff", min = 0, max = 100, value = math.floor(ctx.light.shared.falloff + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "lightStrength", label = "Contrast", min = 0, max = 200, value = math.floor(ctx.light.shared.strength * 100 + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "levels", label = "Shades", options = { "3", "5" }, option = tostring(ctx.light.shared.levels), onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "dither", options = { "No dither", "Bayer 2x2", "Bayer 4x4" },
    option = ctx.light.shared.dither == "Off" and "No dither" or ctx.light.shared.dither, onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "output", label = "Output", options = { OUTPUT_NEW, OUTPUT_REPLACE },
    option = ctx.light.outputMode, onchange = function()
      ctx.light.outputMode = dlg.data.output == OUTPUT_REPLACE and OUTPUT_REPLACE or OUTPUT_NEW
      updateApplyButton(ctx)
    end }
  dlg:newrow()
  dlg:check { id = "preserveOutlines", text = "Keep outlines", selected = ctx.light.shared.preserveOutlines, onclick = function() persistAndPreview(ctx) end }
  dlg:check { id = "separateComponents", text = "Separate objects", selected = ctx.light.shared.separateComponents, onclick = function() persistAndPreview(ctx) end }
  dlg:entry { id = "excludedColors", label = "Keep colors", text = formatExcluded(ctx.light.layer.excludedColors), onchange = function() persistAndPreview(ctx) end }
  dlg:separator()
  dlg:button { id = "applyLight", text = "Apply to new layer", focus = true, onclick = function() applyOutput(ctx) end }
  dlg:button { id = "refreshLayers", text = "Refresh", onclick = function() UI.reload(ctx) end }
  dlg:button { id = "openPalette", text = "Colors...", onclick = function()
    ctx.ui.open(ctx)
    if ctx.currentSprite and #ctx.model.rows == 0 then ctx.dialogs.openChooser(ctx, "palette") end
  end }
  -- autoscrollbars: if the window does not fit the screen (or is made
  -- smaller), Aseprite adds scrollbars instead of cutting controls off.
  dlg:show { wait = false, autoscrollbars = true,
    bounds = ctx.ui.validBounds(ctx.preferences and ctx.preferences.lightBounds) }
  updateDialogData(ctx)
  updateApplyButton(ctx)
  UI.regeneratePreview(ctx)
end

-- Opens Light; only reachable from the Palette Trio panel.
function UI.open(ctx)
  ctx.light = ctx.light or {}
  ctx.light.cache = ctx.light.cache or { normalEntries = {} }
  ctx.light.snapshots = ctx.light.snapshots or {}
  ctx.light.outputMode = ctx.light.outputMode or OUTPUT_NEW
  ctx.light.sourceLayerUuid = ctx.light.sourceLayerUuid or ""
  ctx.light.view = ctx.light.view or ctx.lightView.new()
  if ctx.lightDialog then
    pcall(function() ctx.lightDialog:show { wait = false } end)
    return
  end
  buildDialog(ctx)
end

-- Re-reads layers/settings for the active sprite and updates the existing
-- dialog in place (no close/rebuild, so no extra window or bounds change).
function UI.reload(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  if app.sprite ~= ctx.light.sprite then ctx.light.sourceLayerUuid = "" end
  loadState(ctx)
  dlg:modify { id = "sourceLayer", options = ctx.light.options, option = ctx.light.sourceOption }
  updateDialogData(ctx)
  if app.sprite then UI.regeneratePreview(ctx) else
    ctx.light.previewImage = nil
    setStatus(ctx, "No sprite", "Open an RGB sprite to preview lighting.")
  end
end

function UI.refresh(ctx) UI.reload(ctx) end
function UI.onSpriteChange(ctx) UI.reload(ctx) end
function UI.onUndo(ctx) UI.reload(ctx) end

return UI
