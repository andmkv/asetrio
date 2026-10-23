local UI = {}

local PREVIEW_WIDTH, PREVIEW_HEIGHT = 224, 150

local SHAPES = {
  "Round / Sphere",
  "Box / Beveled rectangle",
  "Cylinder",
  "Contour / Auto Relief",
}

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

local AUTO_FAMILY = "Auto (detect)"
UI.AUTO_FAMILY = AUTO_FAMILY

local function hexOf(c)
  return string.format("#%02X%02X%02X", c.r, c.g, c.b)
end

-- Family combobox labels have a constant width ("12 #RRGGBB") so updating
-- the options never changes the dialog layout.
function UI.familyOptions(model)
  local options, labelToRow, rowToLabel = { AUTO_FAMILY }, {}, {}
  for i, row in ipairs(model.rows) do
    local label = string.format("%d %s", i, hexOf(row.base))
    options[#options + 1] = label
    labelToRow[label], rowToLabel[row.id] = row.id, label
  end
  return options, labelToRow, rowToLabel
end

local function familyLabel(ctx)
  local rowId = ctx.light.layer and ctx.light.layer.familyRowId
  return (rowId and ctx.light.rowToLabel and ctx.light.rowToLabel[rowId]) or AUTO_FAMILY
end

local function refreshFamilyOptions(ctx)
  local options, labelToRow, rowToLabel = UI.familyOptions(ctx.model)
  local joined = table.concat(options, "|")
  ctx.light.labelToRow, ctx.light.rowToLabel = labelToRow, rowToLabel
  if ctx.lightDialog and joined ~= ctx.light.familyOptionsKey then
    ctx.light.familyOptionsKey = joined
    pcall(function() ctx.lightDialog:modify { id = "family", options = options, option = familyLabel(ctx) } end)
  end
  return options
end

local function updateDialogData(ctx, preserveExcludedText)
  local dlg = ctx.lightDialog
  if not dlg then return end
  local shared, layer = ctx.light.shared, ctx.light.layer
  local data = dlg.data
  data.sourceLayer = ctx.light.sourceOption or data.sourceLayer
  data.shape = layer.shape
  data.cylinderAxis = layer.cylinderAxis
  data.bevel = math.floor(layer.bevel + 0.5)
  data.curvature = math.floor(layer.curvature * 100 + 0.5)
  if not preserveExcludedText then
    data.excludedColors = formatExcluded(layer.excludedColors)
  end
  data.lightElevation = math.floor(shared.elevation + 0.5)
  data.lightStrength = math.floor(shared.strength * 100 + 0.5)
  data.levels = tostring(shared.levels)
  data.dither = shared.dither
  data.preserveOutlines = shared.preserveOutlines
  data.separateComponents = shared.separateComponents
  data.family = familyLabel(ctx)
  dlg.data = data
  -- enabled (not visible) toggles: changing visibility forces a relayout,
  -- which Aseprite 1.3.17 may not fully redraw (stale "ghost" pixels).
  dlg:modify { id = "cylinderAxis", enabled = layer.shape == "Cylinder" }
  dlg:modify { id = "bevel", enabled = layer.shape == "Box / Beveled rectangle" }
  dlg:modify { id = "curvature", enabled = layer.shape == "Cylinder" or layer.shape == "Contour / Auto Relief" }
end

local function readDialogSettings(ctx)
  local data = ctx.lightDialog and ctx.lightDialog.data or {}
  local shared, layer = ctx.light.shared, ctx.light.layer
  shared.elevation = clamp(tonumber(data.lightElevation) or shared.elevation, 1, 89)
  shared.strength = clamp((tonumber(data.lightStrength) or (shared.strength * 100)) / 100, 0, 2)
  shared.levels = data.levels == "5" and 5 or 3
  if data.dither == "Bayer 2x2" or data.dither == "Bayer 4x4" then shared.dither = data.dither else shared.dither = "Off" end
  shared.preserveOutlines = data.preserveOutlines == true
  shared.separateComponents = data.separateComponents == true
  if data.shape == "Box / Beveled rectangle" or data.shape == "Cylinder"
    or data.shape == "Contour / Auto Relief" then layer.shape = data.shape
  else layer.shape = SHAPES[1] end
  layer.cylinderAxis = data.cylinderAxis == "Vertical" and "Vertical" or "Horizontal"
  layer.bevel = clamp(tonumber(data.bevel) or layer.bevel, 1, 64)
  layer.curvature = clamp((tonumber(data.curvature) or (layer.curvature * 100)) / 100, 0.25, 3)
  layer.excludedColors = parseExcluded(data.excludedColors)
  if data.family ~= nil then
    layer.familyRowId = (ctx.light.labelToRow or {})[data.family]
  end
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

local function updateLightDirection(ctx, x, y)
  local info = ctx.light.previewBounds
  if not info then return end
  local radius = math.max(1, math.min(info.width, info.height) * 0.48)
  local dx = (x - info.centerX) / radius
  local dy = (info.centerY - y) / radius
  local distance = math.sqrt(dx * dx + dy * dy)
  if distance > 1 then dx, dy = dx / distance, dy / distance end
  if math.sqrt(dx * dx + dy * dy) < 0.08 then dx, dy = -0.65, -0.45 end
  local length = math.sqrt(dx * dx + dy * dy)
  ctx.light.shared.directionX, ctx.light.shared.directionY = dx / length, dy / length
  UI.regeneratePreview(ctx)
end

local function drawPreview(ctx, ev)
  local gc = ev.context
  local width, height = gc.width, gc.height
  gc.color = Color { r = 44, g = 44, b = 48 }
  gc:fillRect(Rectangle(0, 0, width, height))
  for y = 0, height, 12 do
    for x = 0, width, 12 do
      if ((math.floor(x / 12) + math.floor(y / 12)) % 2) == 0 then
        gc.color = Color { r = 58, g = 58, b = 63 }
        gc:fillRect(Rectangle(x, y, 12, 12))
      end
    end
  end
  local image = ctx.light.previewImage
  if not image then
    gc.color = Color { r = 220, g = 220, b = 220 }
    local message = ctx.light.message or ctx.light.status or "Choose a visible source layer."
    for i, line in ipairs(wrapText(gc, message, width - 20)) do
      gc:fillText(line, 10, 10 + (i - 1) * 13)
    end
    ctx.light.previewBounds = nil
    return
  end
  local fit = math.min((width - 24) / image.width, (height - 24) / image.height)
  local scale = fit >= 1 and math.max(1, math.floor(fit)) or fit
  local drawWidth = math.max(1, image.width * scale)
  local drawHeight = math.max(1, image.height * scale)
  local drawX, drawY = (width - drawWidth) / 2, (height - drawHeight) / 2
  gc:save()
  gc.opacity = clamp(tonumber(ctx.light.previewSource and ctx.light.previewSource.opacity) or 255, 0, 255)
  gc:drawImage(image, 0, 0, image.width, image.height, drawX, drawY, drawWidth, drawHeight)
  gc:restore()
  local radius = math.max(6, math.min(drawWidth, drawHeight) * 0.48)
  local centerX, centerY = drawX + drawWidth / 2, drawY + drawHeight / 2
  local markerX = centerX + ctx.light.shared.directionX * radius
  local markerY = centerY - ctx.light.shared.directionY * radius
  gc.color = Color { r = 246, g = 224, b = 109 }
  gc.strokeWidth = 1
  gc:beginPath()
  gc:moveTo(centerX, centerY)
  gc:lineTo(markerX, markerY)
  gc:stroke()
  gc:beginPath()
  gc:roundedRect(Rectangle(centerX - radius, centerY - radius, radius * 2, radius * 2), radius)
  gc:stroke()
  gc:fillRect(Rectangle(markerX - 5, markerY - 5, 10, 10))
  ctx.light.previewBounds = {
    x = drawX, y = drawY, width = drawWidth, height = drawHeight,
    centerX = centerX, centerY = centerY, scale = scale,
    imageWidth = image.width, imageHeight = image.height,
  }
  -- Family strip: the colors Light will use (chosen or detected family).
  local family = ctx.light.activeFamily
  if family then
    local cell = 8
    for i, c in ipairs(family.colors) do
      gc.color = Color { r = c.r, g = c.g, b = c.b }
      gc:fillRect(Rectangle(4 + (i - 1) * cell, 4, cell, cell))
    end
    gc.color = Color { r = 0, g = 0, b = 0 }
    gc:strokeRect(Rectangle(3, 3, #family.colors * cell + 2, cell + 2))
  end
  if ctx.light.picking then
    gc.color = Color { r = 246, g = 224, b = 109 }
    gc:strokeRect(Rectangle(0, 0, width, height))
    gc:fillText("Click the object to pick its family", 4, height - 14)
  end
end

-- Maps a preview point to the source pixel shown there, or nil.
function UI.previewPixel(ctx, x, y)
  local info, source = ctx.light.previewBounds, ctx.light.previewSource
  if not info or not source then return nil end
  local px = math.floor((x - info.x) / info.scale)
  local py = math.floor((y - info.y) / info.scale)
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
    setStatus(ctx, hexOf(pixel) .. " is not a Palette Trio color")
    return false
  end
  ctx.light.layer.familyRowId = families[index].rowId
  refreshFamilyOptions(ctx)
  updateDialogData(ctx, true)
  saveSettings(ctx)
  UI.regeneratePreview(ctx)
  setStatus(ctx, string.format("Picked family %d%s", index, how == "near" and " (closest match)" or ""))
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
  refreshFamilyOptions(ctx)
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
  }
  local output, stats = ctx.lightEngine.render(data.pixels, data.width, data.height, familySnapshot, geometry, options)
  ctx.light.previewImage = ctx.lightAseprite.makeImage(data.width, data.height, output)
  ctx.light.sourceRecord = source
  ctx.light.previewOutput, ctx.light.previewSource = output, data
  ctx.light.previewFrameNumber = frameNumber
  ctx.light.sprite = sprite
  local _ = cacheHit
  if stats.shaded == 0 then
    setStatus(ctx, "No family found · use Pick", "This layer has no Palette Trio colors. Click Pick and then the object, or choose a Family, to shade it with that family.")
  elseif not chosen and detection.index then
    setStatus(ctx, string.format("Auto: family %d (%d%%) · %d px",
      detection.index, math.floor(detection.share * 100 + 0.5), stats.shaded))
  elseif chosen then
    setStatus(ctx, string.format("Family %d · %d px shaded%s", chosen, stats.shaded,
      ctx.light.usingSnapshot and " · from original" or ""))
  else
    setStatus(ctx, string.format("Frame %d · %d px shaded · %d kept%s%s",
      frameNumber, stats.shaded, stats.unchanged, stats.duplicateBases > 0 and " · dup. bases" or "",
      ctx.light.usingSnapshot and " · from original" or ""))
  end
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
  dlg:button { id = "refreshLayers", text = "Refresh", onclick = function() UI.reload(ctx) end }
  dlg:combobox { id = "shape", label = "Shape", options = SHAPES, option = ctx.light.layer.shape, onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "cylinderAxis", label = "Axis", options = { "Horizontal", "Vertical" }, option = ctx.light.layer.cylinderAxis, onchange = function() persistAndPreview(ctx) end }
  dlg:slider { id = "bevel", label = "Bevel", min = 1, max = 24, value = math.floor(ctx.light.layer.bevel + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "curvature", label = "Curvature", min = 25, max = 300, value = math.floor(ctx.light.layer.curvature * 100 + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "family", label = "Family", options = refreshFamilyOptions(ctx), option = familyLabel(ctx),
    onchange = function() persistAndPreview(ctx) end }
  dlg:button { id = "pick", text = "Pick", onclick = function()
    ctx.light.picking = not ctx.light.picking
    dlg:modify { id = "pick", text = ctx.light.picking and "Picking..." or "Pick" }
    pcall(function() dlg:modify { id = "lightPreview", mousecursor = ctx.light.picking and MouseCursor.CROSSHAIR or MouseCursor.ARROW } end)
    if ctx.light.picking then setStatus(ctx, "Click the object in the preview") end
    dlg:repaint()
  end }
  dlg:newrow()
  dlg:canvas {
    id = "lightPreview", width = PREVIEW_WIDTH, height = PREVIEW_HEIGHT,
    autoscaling = true, hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ctx, ev) end,
    onmousedown = function(ev)
      -- Pick mode (or right-click): eyedropper. Otherwise drag the light.
      if (ctx.light.picking and ev.button == MouseButton.LEFT) or ev.button == MouseButton.RIGHT then
        UI.pickAt(ctx, ev.x, ev.y)
        pcall(function() dlg:modify { id = "lightPreview", mousecursor = MouseCursor.ARROW } end)
        return
      end
      if ev.button == MouseButton.LEFT and ctx.light.previewBounds then
        ctx.light.dragging = true
        updateLightDirection(ctx, ev.x, ev.y)
      end
    end,
    onmousemove = function(ev)
      if ctx.light.dragging then updateLightDirection(ctx, ev.x, ev.y) end
    end,
    onmouseup = function()
      if ctx.light.dragging then
        ctx.light.dragging = false
        saveSettings(ctx)
      end
    end,
  }
  dlg:newrow()
  dlg:label { id = "lightStatus", text = "Preparing preview..." }
  dlg:slider { id = "lightElevation", label = "Elevation", min = 1, max = 89, value = math.floor(ctx.light.shared.elevation + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "lightStrength", label = "Contrast", min = 0, max = 200, value = math.floor(ctx.light.shared.strength * 100 + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "levels", label = "Shades", options = { "3", "5" }, option = tostring(ctx.light.shared.levels), onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "dither", options = { "Off", "Bayer 2x2", "Bayer 4x4" }, option = ctx.light.shared.dither, onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "output", label = "Output", options = { OUTPUT_NEW, OUTPUT_REPLACE },
    option = ctx.light.outputMode, onchange = function()
      ctx.light.outputMode = dlg.data.output == OUTPUT_REPLACE and OUTPUT_REPLACE or OUTPUT_NEW
      updateApplyButton(ctx)
    end }
  dlg:check { id = "preserveOutlines", text = "Keep 1-px alpha outlines", selected = ctx.light.shared.preserveOutlines, onclick = function() persistAndPreview(ctx) end }
  dlg:newrow()
  dlg:check { id = "separateComponents", text = "Shade separate objects separately", selected = ctx.light.shared.separateComponents, onclick = function() persistAndPreview(ctx) end }
  dlg:entry { id = "excludedColors", label = "Keep colors", text = formatExcluded(ctx.light.layer.excludedColors), onchange = function() persistAndPreview(ctx) end }
  dlg:separator()
  dlg:button { id = "applyLight", text = "Apply to new layer", focus = true, onclick = function() applyOutput(ctx) end }
  dlg:button { id = "openPalette", text = "Colors...", onclick = function()
    ctx.ui.open(ctx)
    if ctx.currentSprite and #ctx.model.rows == 0 then ctx.dialogs.openChooser(ctx, "palette") end
  end }
  dlg:button { id = "closeLight", text = "Close", onclick = function() dlg:close() end }
  dlg:show { wait = false, bounds = ctx.ui.validBounds(ctx.preferences and ctx.preferences.lightBounds) }
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
