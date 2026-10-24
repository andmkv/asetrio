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

local SCOPE_THIS, SCOPE_ALL = "This frame", "All frames"
local OUTPUT_NEW, OUTPUT_REPLACE = "New layer", "Replace source"
UI.SCOPE_THIS, UI.SCOPE_ALL = SCOPE_THIS, SCOPE_ALL
UI.OUTPUT_NEW, UI.OUTPUT_REPLACE = OUTPUT_NEW, OUTPUT_REPLACE

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

local function alert(ctx, options)
  return (ctx.alert or app.alert)(options)
end

local function repaintAll(ctx)
  if ctx.lightDialog then ctx.lightDialog:repaint() end
end

------------------------------------------------------------------------------
-- State: records (all visible image layers, bottom to top), the checked set,
-- the preview frame
------------------------------------------------------------------------------

local function frameCount(ctx)
  local sprite = ctx.light.sprite
  local ok, count = pcall(function() return #sprite.frames end)
  return ok and count or 1
end

local function clampFrame(ctx, frame)
  return math.max(1, math.min(frameCount(ctx), math.floor(tonumber(frame) or 1)))
end

local function editorFrame()
  local ok, number = pcall(function() return app.frame and app.frame.frameNumber end)
  return ok and number or 1
end

-- Checked layers, in stack order (bottom to top).
local function selectedRecords(ctx)
  local list = {}
  for _, record in ipairs(ctx.light.records or {}) do
    if ctx.light.selected[record.uuid] then list[#list + 1] = record end
  end
  return list
end
UI.selectedRecords = selectedRecords

local function recordByUuid(ctx, uuid)
  for _, record in ipairs(ctx.light.records or {}) do
    if record.uuid == uuid then return record end
  end
  return nil
end

-- The layer whose stored settings are shown (the others get the same ones).
local function activeRecord(ctx)
  local record = recordByUuid(ctx, ctx.light.activeUuid)
  if record and ctx.light.selected[record.uuid] then return record end
  local list = selectedRecords(ctx)
  return list[#list]
end

local function selectedUuidList(ctx)
  local list = {}
  for _, record in ipairs(selectedRecords(ctx)) do list[#list + 1] = record.uuid end
  return list
end

------------------------------------------------------------------------------
-- Dialog data <-> settings
------------------------------------------------------------------------------

local function updateFamilyControls(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  dlg:repaint()
end

local function updateDialogData(ctx, preserveExcludedText)
  local dlg = ctx.lightDialog
  if not dlg then return end
  local shared, layer = ctx.light.shared, ctx.light.layer
  local data = dlg.data
  data.shape = UI.shapeLabel(layer)
  data.material = layer.material
  data.lightHeight = math.floor((shared.lightHeight or 32) + 0.5)
  data.falloff = math.floor(shared.falloff + 0.5)
  data.lightStrength = math.floor(shared.strength * 100 + 0.5)
  data.levels = tostring(shared.levels)
  data.dither = shared.dither == "Off" and "No dither" or shared.dither
  data.preserveOutlines = shared.preserveOutlines
  data.separateComponents = shared.separateComponents
  data.scope = ctx.light.scope
  data.output = ctx.light.outputMode
  dlg.data = data
  -- enabled (not visible) toggles: changing visibility forces a relayout,
  -- which Aseprite 1.3.17 may not fully redraw (stale "ghost" pixels).
  local min, max, value, enabled = UI.formRange(layer)
  dlg:modify { id = "form", min = min, max = max, value = value, enabled = enabled }
  pcall(function()
    dlg:modify { id = "keepClear", enabled = #(layer.excludedColors or {}) > 0 }
    dlg:modify { id = "keepAdd", text = ctx.light.keeping and "Done" or "Add color" }
  end)
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
end

-- Stores the light settings on the sprite and the (shared) shading settings
-- on every checked layer. The checked set is stored too.
local function saveSettings(ctx)
  local sprite = app.sprite
  local active = activeRecord(ctx)
  if not sprite or not active then return end
  ctx.light.shared.sourceLayerUuid = active.uuid
  ctx.light.shared.sourceLayerUuids = selectedUuidList(ctx)
  local ok, reason = pcall(function()
    app.transaction("Save Palette Trio Light settings", function()
      assert(ctx.lightAseprite.saveShared(sprite, ctx.namespace, ctx.light.shared), "Could not store sprite light settings")
      for _, record in ipairs(selectedRecords(ctx)) do
        assert(ctx.lightAseprite.saveLayerSettings(record.layer, ctx.namespace, ctx.light.layer),
          "Could not store layer shading settings")
      end
    end)
  end)
  if not ok then setStatus(ctx, "Settings could not be saved: " .. tostring(reason)) end
end

local function persistAndPreview(ctx)
  readDialogSettings(ctx)
  saveSettings(ctx)
  updateDialogData(ctx, true)
  UI.regeneratePreview(ctx)
end

------------------------------------------------------------------------------
-- Layer selection and frame selection
------------------------------------------------------------------------------

-- Makes `record` the layer whose stored settings are shown.
local function setActive(ctx, record)
  ctx.light.activeUuid = record and record.uuid or nil
  if record then
    ctx.light.layer = ctx.lightAseprite.loadLayerSettings(record.layer, ctx.namespace)
    updateDialogData(ctx)
  end
end

-- Check or uncheck one layer. The checked layers are shaded and shown.
function UI.toggleLayer(ctx, uuid)
  local record = recordByUuid(ctx, uuid)
  if not record then return end
  ctx.light.selected[uuid] = not ctx.light.selected[uuid] or nil
  if ctx.light.selected[uuid] and #selectedRecords(ctx) == 1 then setActive(ctx, record) end
  if not ctx.light.selected[uuid] and ctx.light.activeUuid == uuid then setActive(ctx, activeRecord(ctx)) end
  UI.regeneratePreview(ctx)
end

-- Only this layer.
function UI.soloLayer(ctx, uuid)
  local record = recordByUuid(ctx, uuid)
  if not record then return end
  ctx.light.selected = { [uuid] = true }
  setActive(ctx, record)
  UI.regeneratePreview(ctx)
end

function UI.selectAllLayers(ctx, on)
  ctx.light.selected = {}
  if on then
    for _, record in ipairs(ctx.light.records) do ctx.light.selected[record.uuid] = true end
  end
  local record = activeRecord(ctx) or (on and ctx.light.records[#ctx.light.records]) or nil
  if record then setActive(ctx, record) end
  UI.regeneratePreview(ctx)
end

-- Selects the preview frame. The editor follows, so the strip works like a
-- small timeline.
function UI.setFrame(ctx, frame)
  frame = clampFrame(ctx, frame)
  local sprite = ctx.light.sprite
  if frame ~= ctx.light.frame then
    ctx.light.frame = frame
    ctx.light.frameScroll = ctx.lightWidgets.Frames.scrollToShow(ctx.light.stripWidth or 200, frameCount(ctx), frame,
      ctx.light.frameScroll or 0, ctx.light.cellW)
    pcall(function() app.frame = sprite.frames[frame] end)
    UI.regeneratePreview(ctx)
  end
end

-- The editor's frame changed (sitechange): follow it.
function UI.syncFrame(ctx)
  if not ctx.lightDialog or not ctx.light.sprite or app.sprite ~= ctx.light.sprite then return end
  local frame = clampFrame(ctx, editorFrame())
  if frame ~= ctx.light.frame then
    ctx.light.frame = frame
    ctx.light.frameScroll = ctx.lightWidgets.Frames.scrollToShow(ctx.light.stripWidth or 200, frameCount(ctx), frame,
      ctx.light.frameScroll or 0, ctx.light.cellW)
    UI.regeneratePreview(ctx)
  end
end

-- Drops cached pixels and thumbnails (after edits, undo, Refresh, Apply).
function UI.invalidate(ctx)
  if ctx.light and ctx.lightJob then ctx.lightJob.invalidate(ctx) end
end

------------------------------------------------------------------------------
-- Light placement
------------------------------------------------------------------------------

-- First use: place the point light where the old direction/elevation pointed,
-- at a height equal to the object size, so existing settings look the same.
local function ensureLight(ctx, scene)
  local shared = ctx.light.shared
  if shared.lightX and shared.lightY and shared.lightHeight then return end
  local sprite = ctx.light.sprite
  scene = scene or { centerX = sprite.width / 2, centerY = sprite.height / 2,
    size = math.max(sprite.width, sprite.height) }
  shared.lightHeight = shared.lightHeight or math.max(4, math.floor(scene.size + 0.5))
  local lx, ly = ctx.lightEngine.pointFromDirection(shared.directionX, shared.directionY, shared.elevation,
    scene.centerX, scene.centerY, shared.lightHeight)
  shared.lightX, shared.lightY = math.floor(lx + 0.5), math.floor(ly + 0.5)
  updateDialogData(ctx, true)
end

-- Moves the light to a preview point (stored in sprite coordinates).
local function moveLightTo(ctx, sx, sy)
  local t = ctx.light.viewT
  if not t then return end
  local cx, cy = ctx.lightView.toCel(t, sx, sy)
  ctx.light.shared.lightX = math.floor(cx)
  ctx.light.shared.lightY = math.floor(cy)
  UI.regeneratePreview(ctx)
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

local function themeText()
  local ok, themed = pcall(function() return app.theme.color.text end)
  if ok and themed and themed.alpha > 0 then return themed end
  return Color { r = 40, g = 40, b = 40 }
end

local function truncate(gc, text, maxWidth)
  if gc:measureText(text).width <= maxWidth then return text end
  while #text > 1 and gc:measureText(text .. "..").width > maxWidth do text = text:sub(1, -2) end
  return text .. ".."
end

-- Layer list: header (all / none), then one row per layer, top layer first.
local function paintLayerList(ctx, gc)
  local W = ctx.lightWidgets.Layers
  local width, height = gc.width, gc.height
  ctx.light.listW, ctx.light.listH = width, height
  gc.color = Color { r = 44, g = 44, b = 48 }
  gc:fillRect(Rectangle(0, 0, width, height))
  local dim = Color { r = 150, g = 150, b = 155 }
  local text = Color { r = 225, g = 225, b = 228 }
  gc.color = dim
  gc:fillText("all", W.PAD, 1)
  gc:fillText("none", math.floor(width / 2) + W.PAD, 1)
  gc.color = Color { r = 90, g = 90, b = 96 }
  gc:fillRect(Rectangle(0, W.HEADER_H - 1, width, 1))
  local records = ctx.light.records or {}
  local count = #records
  if count == 0 then
    gc.color = dim
    gc:fillText("no layers", W.PAD, W.HEADER_H + 2)
    return
  end
  local scroll = ctx.light.layerScroll or 0
  gc:save()
  pcall(function()
    gc:beginPath()
    gc:rect(Rectangle(0, W.HEADER_H, width, height - W.HEADER_H))
    gc:clip()
  end)
  for display = 1, count do
    local y = W.rowTop(display, scroll)
    if y + W.ROW_H > W.HEADER_H and y < height then
      local record = records[count - display + 1]
      local checked = ctx.light.selected[record.uuid]
      local skipped = ctx.light.skipped and ctx.light.skipped[record.uuid]
      if record.uuid == ctx.light.activeUuid and checked then
        gc.color = Color { r = 255, g = 255, b = 255, a = 28 }
        gc:fillRect(Rectangle(0, y, width, W.ROW_H))
      end
      gc.color = Color { r = 18, g = 18, b = 22 }
      gc:fillRect(Rectangle(W.PAD, y + 2, W.BOX, W.BOX))
      gc.color = dim
      gc:strokeRect(Rectangle(W.PAD, y + 2, W.BOX, W.BOX))
      if checked then
        gc.color = Color { r = 246, g = 224, b = 109 }
        gc:fillRect(Rectangle(W.PAD + 2, y + 4, W.BOX - 4, W.BOX - 4))
      end
      local x = W.PAD + W.BOX + 4 + (record.depth or 0) * W.INDENT
      local family = ctx.light.layerFamilies and ctx.light.layerFamilies[record.uuid]
      local room = width - x - (family and (W.SWATCH + 4) or 2)
      gc.color = (checked and not skipped) and text or dim
      gc:fillText(truncate(gc, record.name or "Layer", room), x, y + 1)
      if family and checked then
        gc.color = Color { r = family.base.r, g = family.base.g, b = family.base.b }
        gc:fillRect(Rectangle(width - W.SWATCH - 3, y + 3, W.SWATCH, W.SWATCH))
        gc.color = Color { r = 0, g = 0, b = 0 }
        gc:strokeRect(Rectangle(width - W.SWATCH - 3, y + 3, W.SWATCH, W.SWATCH))
      end
    end
  end
  gc:restore()
  local maxScroll = W.maxScroll(height, count)
  if maxScroll > 0 then
    local track = height - W.HEADER_H
    local thumb = math.max(6, math.floor(track * W.visibleRows(height) / count))
    local ty = W.HEADER_H + math.floor((track - thumb) * scroll / maxScroll)
    gc.color = dim
    gc:fillRect(Rectangle(width - 2, ty, 2, thumb))
  end
end

-- Which frames have a cel on at least one checked layer (the dots).
function UI.celFrames(ctx)
  local key = table.concat(selectedUuidList(ctx), ",") .. "|" .. frameCount(ctx)
  if ctx.light.celMap and ctx.light.celMapKey == key then return ctx.light.celMap end
  local map = {}
  for _, record in ipairs(selectedRecords(ctx)) do
    for frame = 1, frameCount(ctx) do
      if not map[frame] then
        local ok, cel = pcall(function() return record.layer:cel(frame) end)
        if ok and cel then map[frame] = true end
      end
    end
  end
  ctx.light.celMap, ctx.light.celMapKey = map, key
  return map
end

-- A small round dot in pixel-art style: 5x5, filled or a hollow ring.
local DOT_ROWS = { 3, 5, 5, 5, 3 }
local DOT_HOLE = { 1, 3, 1 }
local function drawDot(gc, cx, cy, color, hollowFill)
  for row, w in ipairs(DOT_ROWS) do
    gc.color = color
    gc:fillRect(Rectangle(cx - (w - 1) // 2, cy - 2 + row - 1, w, 1))
  end
  if hollowFill then
    gc.color = hollowFill
    for row, w in ipairs(DOT_HOLE) do
      gc:fillRect(Rectangle(cx - (w - 1) // 2, cy - 1 + row - 1, w, 1))
    end
  end
end

-- Frame strip, like Aseprite's own timeline but in one row: a numbered cell
-- per frame (the chosen frame highlighted) and a dot under it that is filled
-- when a checked layer has a cel there. Cells are as narrow as the longest
-- frame number allows. Scrolled horizontally.
local function paintFrameStrip(ctx, gc)
  local F = ctx.lightWidgets.Frames
  local width, height = gc.width, gc.height
  ctx.light.stripWidth = width
  local count = frameCount(ctx)
  local widest = gc:measureText(string.rep("8", #tostring(count)))
  local w = math.max(F.MIN_CELL_W, widest.width + 5)
  ctx.light.cellW = w
  local face, light, dark = Color { r = 196, g = 196, b = 196 }, Color { r = 226, g = 226, b = 226 }, Color { r = 150, g = 150, b = 150 }
  local chosen = Color { r = 123, g = 145, b = 160 }
  gc.color = Color { r = 36, g = 36, b = 40 }
  gc:fillRect(Rectangle(0, 0, width, height))
  local scroll = ctx.light.frameScroll or 0
  local first, last = F.visibleRange(width, count, scroll, w)
  local cels = UI.celFrames(ctx)
  for frame = first, last do
    local x = F.cellX(frame, scroll, w)
    local current = frame == ctx.light.frame
    -- Number cell and dot cell, each with a light top-left and dark bottom-right edge.
    for _, cell in ipairs({ { 0, F.NUM_H }, { F.NUM_H, F.HEIGHT - F.NUM_H } }) do
      local top, h = cell[1], cell[2]
      gc.color = current and chosen or face
      gc:fillRect(Rectangle(x, top, w - 1, h - 1))
      gc.color = current and Color { r = 160, g = 178, b = 190 } or light
      gc:fillRect(Rectangle(x, top, w - 1, 1)); gc:fillRect(Rectangle(x, top, 1, h - 1))
      gc.color = current and Color { r = 90, g = 108, b = 120 } or dark
      gc:fillRect(Rectangle(x, top + h - 2, w - 1, 1)); gc:fillRect(Rectangle(x + w - 2, top, 1, h - 1))
    end
    local label = tostring(frame)
    local size = gc:measureText(label)
    gc.color = current and Color { r = 255, g = 255, b = 255 } or Color { r = 0, g = 0, b = 0 }
    gc:fillText(label, x + math.floor((w - 1 - size.width) / 2), math.max(0, math.floor((F.NUM_H - 1 - size.height) / 2)))
    local cx, cy = x + (w - 1) // 2, F.NUM_H + (F.HEIGHT - F.NUM_H - 1) // 2
    if cels[frame] then
      drawDot(gc, cx, cy, current and Color { r = 255, g = 255, b = 255 } or Color { r = 0, g = 0, b = 0 })
    else
      drawDot(gc, cx, cy, current and Color { r = 190, g = 205, b = 214 } or Color { r = 165, g = 165, b = 165 },
        current and chosen or face)
    end
  end
end

local function drawPreview(ctx, ev)
  local gc = ev.context
  local width, height = gc.width, gc.height
  ctx.light.canvasW, ctx.light.canvasH = width, height
  gc.color = Color { r = 44, g = 44, b = 48 }
  gc:fillRect(Rectangle(0, 0, width, height))
  local results = ctx.light.results
  local sprite = ctx.light.sprite
  if not results or #results == 0 or not sprite then
    gc.color = Color { r = 220, g = 220, b = 220 }
    local message = ctx.light.message or ctx.light.status or "Check a layer in the list."
    for i, line in ipairs(wrapText(gc, message, width - 20)) do
      gc:fillText(line, 10, 10 + (i - 1) * 13)
    end
    ctx.light.viewT = nil
    return
  end
  local View = ctx.lightView
  local t = View.transform(ctx.light.view, width, height, sprite.width, sprite.height)
  ctx.light.viewT = t
  local drawW, drawH = sprite.width * t.scale, sprite.height * t.scale
  -- Checkerboard over the whole sprite area, so the canvas extent is visible.
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
  -- Checked layers, bottom to top, at their cel positions.
  for _, result in ipairs(results) do
    gc:save()
    gc.opacity = clamp(tonumber(result.cel.opacity) or 255, 0, 255)
    gc:drawImage(result.image, 0, 0, result.image.width, result.image.height,
      t.originX + result.cel.position.x * t.scale, t.originY + result.cel.position.y * t.scale,
      result.image.width * t.scale, result.image.height * t.scale)
    gc:restore()
  end

  -- Light marker (a sun) with a guide line to the center of the objects.
  -- When the light is outside the view, the marker sits on the edge, hollow.
  local shared = ctx.light.shared
  if shared.lightX then
    local scene = ctx.light.scene
    local ox, oy = scene and scene.centerX or sprite.width / 2, scene and scene.centerY or sprite.height / 2
    local cx, cy = View.toScreen(t, ox, oy)
    local mx, my = View.toScreen(t, shared.lightX + 0.5, shared.lightY + 0.5)
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
  -- Family tag in the top-left corner: the colors Light will use, and a
  -- button. Click: pick the family from the preview (when it is automatic) or
  -- go back to automatic (when it was picked).
  do
    local family = ctx.light.activeFamily
    local cell = 8
    local picked = ctx.light.layer.familyRowId ~= nil
    local label = picked and "Picked - click for Auto" or (family and "Auto - click to pick" or "No family - click to pick")
    local stripW = family and #family.colors * cell or 0
    local x0, y0 = 3, 3
    local w = 4 + stripW + (family and 5 or 0) + gc:measureText(label).width + 4
    local h = cell + 4
    ctx.light.familyTag = { x = x0, y = y0, width = w, height = h }
    gc.color = ctx.light.hoverTag and Color { r = 80, g = 80, b = 90 } or Color { r = 60, g = 60, b = 68 }
    gc:fillRect(Rectangle(x0, y0, w, h))
    gc.color = Color { r = 120, g = 120, b = 130 }
    gc:strokeRect(Rectangle(x0, y0, w, h))
    if family then
      for i, c in ipairs(family.colors) do
        gc.color = Color { r = c.r, g = c.g, b = c.b }
        gc:fillRect(Rectangle(x0 + 2 + (i - 1) * cell, y0 + 2, cell, cell))
      end
      gc.color = Color { r = 0, g = 0, b = 0 }
      gc:strokeRect(Rectangle(x0 + 1, y0 + 1, stripW + 2, cell + 2))
    end
    gc.color = Color { r = 235, g = 235, b = 240 }
    gc:fillText(label, x0 + 4 + stripW + (family and 3 or 0), y0 + 1)
  end
  -- Kept colors: small chips under the family strip.
  local kept = ctx.light.layer.excludedColors or {}
  if #kept > 0 then
    gc.color = Color { r = 200, g = 200, b = 205 }
    gc:fillText("kept", 4, 20)
    local x0 = 8 + gc:measureText("kept").width
    for i, c in ipairs(kept) do
      if i > 14 then break end
      gc.color = Color { r = c.r, g = c.g, b = c.b }
      gc:fillRect(Rectangle(x0 + (i - 1) * 8, 22, 7, 7))
      gc.color = Color { r = 0, g = 0, b = 0 }
      gc:strokeRect(Rectangle(x0 + (i - 1) * 8 - 1, 21, 8, 8))
    end
  end
  gc.color = Color { r = 150, g = 150, b = 155 }
  if ctx.light.picking or ctx.light.keeping then
    gc.color = Color { r = 246, g = 224, b = 109 }
    gc:strokeRect(Rectangle(0, 0, width, height))
    gc:fillText(ctx.light.keeping and "Click colors to keep as they are" or "Click the object to pick its family", 4, height - 12)
  else
    gc:fillText("Drag: light  Wheel: zoom  Alt+drag: pan", 4, height - 12)
  end
end

------------------------------------------------------------------------------
-- Picking
------------------------------------------------------------------------------

-- The source pixel shown under a preview point (topmost layer first), plus
-- the result it belongs to.
function UI.previewPixel(ctx, x, y)
  local t, results = ctx.light.viewT, ctx.light.results
  if not t or not results then return nil end
  local sx, sy = ctx.lightView.toCel(t, x, y)
  for i = #results, 1, -1 do
    local result = results[i]
    local px, py = math.floor(sx - result.cel.position.x), math.floor(sy - result.cel.position.y)
    if px >= 0 and py >= 0 and px < result.data.width and py < result.data.height then
      local pixel = result.data.pixels[py * result.data.width + px + 1]
      if pixel and (pixel.a or 0) > 0 then return pixel, result end
    end
  end
  return nil
end

-- The family tag in the preview: toggles between Auto and picking.
function UI.onFamilyTag(ctx)
  if ctx.light.layer.familyRowId then
    ctx.light.layer.familyRowId = nil
    saveSettings(ctx)
    UI.regeneratePreview(ctx)
    setStatus(ctx, "Family is detected automatically")
  else
    ctx.light.picking = true
    ctx.light.keeping = false
    pcall(function() ctx.lightDialog:modify { id = "pick", text = "Picking..." } end)
    pcall(function() ctx.lightDialog:modify { id = "lightPreview", mousecursor = MouseCursor.CROSSHAIR } end)
    setStatus(ctx, "Click the object in the preview")
    repaintAll(ctx)
  end
end

local function inFamilyTag(ctx, x, y)
  local tag = ctx.light.familyTag
  return tag and x >= tag.x and x < tag.x + tag.width and y >= tag.y and y < tag.y + tag.height
end

-- "Keep" colors: colors Light leaves exactly as they are (outlines, eyes,
-- hand-painted highlights). Chosen by clicking them in the preview.
local function updateKeepControls(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  pcall(function()
    dlg:modify { id = "keepAdd", text = ctx.light.keeping and "Done" or "Add color" }
    dlg:modify { id = "keepClear", enabled = #(ctx.light.layer.excludedColors or {}) > 0 }
  end)
  dlg:repaint()
end

local function stopPicking(ctx)
  ctx.light.picking, ctx.light.keeping = false, false
  pcall(function() ctx.lightDialog:modify { id = "pick", text = "Pick" } end)
  pcall(function() ctx.lightDialog:modify { id = "lightPreview", mousecursor = MouseCursor.ARROW } end)
  updateKeepControls(ctx)
end

-- Click on a pixel in keep mode: keep its color, or stop keeping it.
function UI.keepAt(ctx, x, y)
  local pixel = UI.previewPixel(ctx, x, y)
  if not pixel then
    setStatus(ctx, "Click a color inside an object")
    return false
  end
  local list = ctx.light.layer.excludedColors
  for i, c in ipairs(list) do
    if c.r == pixel.r and c.g == pixel.g and c.b == pixel.b then
      table.remove(list, i)
      saveSettings(ctx)
      UI.regeneratePreview(ctx)
      setStatus(ctx, "That color is shaded again")
      updateKeepControls(ctx)
      return true
    end
  end
  list[#list + 1] = { r = pixel.r, g = pixel.g, b = pixel.b }
  saveSettings(ctx)
  UI.regeneratePreview(ctx)
  setStatus(ctx, string.format("That color is kept as it is (%d kept)", #list))
  updateKeepControls(ctx)
  return true
end

-- Eyedropper: resolves the clicked color to a family (any shade counts).
-- Nearest-color matching is used only when one family is clearly closest.
-- The picked family applies to all checked layers.
function UI.pickAt(ctx, x, y)
  stopPicking(ctx)
  local pixel = UI.previewPixel(ctx, x, y)
  if not pixel then
    setStatus(ctx, "Click inside an object to pick")
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

------------------------------------------------------------------------------
-- Preview
------------------------------------------------------------------------------

local function clearPreview(ctx)
  ctx.light.results, ctx.light.previewImage, ctx.light.scene = nil, nil, nil
  ctx.light.activeFamily, ctx.light.detection, ctx.light.viewT = nil, nil, nil
  ctx.light.layerFamilies, ctx.light.skipped = {}, {}
end

function UI.regeneratePreview(ctx)
  if not ctx.lightDialog then return false end
  local sprite = app.sprite
  if not sprite then
    clearPreview(ctx)
    setStatus(ctx, "No sprite", "Open an RGB sprite to preview lighting.")
    repaintAll(ctx)
    return false
  end
  if sprite ~= ctx.light.sprite then
    UI.reload(ctx)
    return ctx.light.results ~= nil and #ctx.light.results > 0
  end
  if not ctx.lightAseprite.isRgbSprite(sprite) then
    clearPreview(ctx)
    setStatus(ctx, "RGB sprites only", "Palette Trio Light processes RGB sprites only. Indexed and grayscale sprites are not modified.")
    repaintAll(ctx)
    return false
  end
  local records = selectedRecords(ctx)
  if #records == 0 then
    clearPreview(ctx)
    setStatus(ctx, "No layer checked", "Check one or more layers in the list. Clicking a layer's name selects only that layer.")
    repaintAll(ctx)
    return false
  end
  local families = ctx.model.shadeFamilies(ctx.model, ctx.light.shared.levels)
  if #families == 0 then
    clearPreview(ctx)
    setStatus(ctx, "No shade families", "Light shades pixels using Palette Trio's families, and there are none yet. Click Colors... to add base colors.")
    repaintAll(ctx)
    return false
  end
  ctx.light.frame = clampFrame(ctx, ctx.light.frame)
  local frameResult = ctx.lightJob.frame(ctx, records, ctx.light.frame, families, function(scene)
    ensureLight(ctx, scene)
  end)
  local skipped = {}
  for _, record in ipairs(frameResult.skipped) do skipped[record.uuid] = true end
  ctx.light.skipped = skipped
  if #frameResult.results == 0 then
    clearPreview(ctx)
    ctx.light.skipped = skipped
    setStatus(ctx, string.format("No cel on frame %d", ctx.light.frame),
      string.format("None of the checked layers has a cel on frame %d. Pick another frame in the strip below.", ctx.light.frame))
    repaintAll(ctx)
    return false
  end
  local results = frameResult.results
  ctx.light.results, ctx.light.scene = results, frameResult.scene
  ctx.light.previewImage = results[1].image
  local active = results[#results]
  for _, result in ipairs(results) do
    if result.record.uuid == ctx.light.activeUuid then active = result end
  end
  ctx.light.activeFamily, ctx.light.detection = active.family, active.detection
  ctx.light.layerFamilies = {}
  local shaded, fromOriginal = 0, false
  for _, result in ipairs(results) do
    ctx.light.layerFamilies[result.record.uuid] = result.family
    shaded = shaded + result.stats.shaded
    fromOriginal = fromOriginal or result.usingSnapshot
  end
  local suffix = (fromOriginal and " · from original" or "")
    .. (#frameResult.skipped > 0 and string.format(" · %d without a cel here", #frameResult.skipped) or "")
  if shaded == 0 then
    setStatus(ctx, "No family found · use Pick", "The checked layers have no Palette Trio colors. Click Pick and then the object to shade it with that family.")
  elseif #results > 1 then
    setStatus(ctx, string.format("%d layers · %d px shaded%s", #results, shaded, suffix))
  elseif active.chosen then
    setStatus(ctx, string.format("Picked family · %d px shaded%s", shaded, suffix))
  else
    setStatus(ctx, string.format("Auto family (%d%%) · %d px shaded%s",
      math.floor(active.detection.share * 100 + 0.5), shaded, suffix))
  end
  updateFamilyControls(ctx)
  repaintAll(ctx)
  return true
end

------------------------------------------------------------------------------
-- Apply
------------------------------------------------------------------------------

local function targetFrames(ctx)
  local frames = {}
  if ctx.light.scope == SCOPE_ALL then
    for frame = 1, frameCount(ctx) do frames[#frames + 1] = frame end
  else
    frames[1] = ctx.light.frame
  end
  return frames
end

local function buildJobs(ctx, frameResults)
  local byUuid, order = {}, {}
  for _, frameResult in ipairs(frameResults) do
    for _, result in ipairs(frameResult.results) do
      local uuid = result.record.uuid
      local job = byUuid[uuid]
      if not job then
        job = { record = result.record, settings = ctx.light.layer, frames = {} }
        byUuid[uuid], order[#order + 1] = job, job
      end
      job.frames[#job.frames + 1] = { frame = result.frame, image = result.image, cel = result.cel }
    end
  end
  return order
end

local function applyOutput(ctx)
  if not UI.regeneratePreview(ctx) then return false end
  local sprite = app.sprite
  if not sprite or sprite ~= ctx.light.sprite then
    setStatus(ctx, "The source changed before Apply. Click Apply again.")
    return false
  end
  local records = selectedRecords(ctx)
  local families = ctx.model.shadeFamilies(ctx.model, ctx.light.shared.levels)
  local frames = targetFrames(ctx)
  local frameResults = ctx.lightJob.frames(ctx, records, frames, families)
  local jobs = buildJobs(ctx, frameResults)
  local cels = 0
  for _, job in ipairs(jobs) do cels = cels + #job.frames end
  if cels == 0 then
    setStatus(ctx, "Nothing to shade")
    return false
  end
  local layerCount, frameCountText = #jobs, #frames == 1 and string.format("frame %d", frames[1]) or string.format("%d frames", #frames)

  if ctx.light.outputMode == OUTPUT_REPLACE then
    local answer = alert(ctx, {
      title = "Replace source pixels?",
      text = {
        string.format("Overwrite %s on %s (%d cels) with the shaded result?",
          layerCount == 1 and ("layer \"" .. tostring(jobs[1].record.layer.name) .. "\"") or (layerCount .. " layers"),
          frameCountText, cels),
        "Only those cels change; transparency and unmatched colors are kept. Undo restores them in one step.",
        "While Aseprite stays open, applying again re-shades the original pixels.",
        "The original is NOT saved in the file. After a restart, or if you edit the layer,",
        "the shaded pixels become the new source. Keep a copy of the unshaded layer.",
      },
      buttons = { "Replace", "Cancel" },
    })
    if answer ~= 1 then return false end
    -- Keep earlier originals: those cels were shaded from a snapshot.
    local keep = {}
    for _, frameResult in ipairs(frameResults) do
      for _, result in ipairs(frameResult.results) do
        local key = result.record.uuid .. ":" .. tostring(result.frame)
        if result.usingSnapshot and ctx.light.snapshots[key] then keep[key] = ctx.light.snapshots[key].original end
      end
    end
    local replaceJobs = {}
    for i, job in ipairs(jobs) do replaceJobs[i] = { record = job.record, frames = job.frames } end
    local success, result = ctx.lightAseprite.replaceSourceBatch(sprite, replaceJobs)
    if not success then
      alert(ctx, { title = "Palette Trio Light", text = tostring(result), buttons = "OK" })
      return false
    end
    for key, snapshot in pairs(result) do
      if keep[key] then snapshot.original = keep[key] end
      ctx.light.snapshots[key] = snapshot
    end
    UI.invalidate(ctx)
    UI.regeneratePreview(ctx)
    setStatus(ctx, string.format("%d cels replaced (Undo restores them)", cels))
    return true
  end

  local success, result = ctx.lightAseprite.applyOutputBatch(sprite, jobs, ctx.namespace)
  if not success then
    alert(ctx, { title = "Palette Trio Light", text = tostring(result), buttons = "OK" })
    return false
  end
  UI.invalidate(ctx)
  UI.regeneratePreview(ctx)
  setStatus(ctx, string.format("Output updated: %s, %s", layerCount == 1 and "1 layer" or (layerCount .. " layers"), frameCountText))
  return true
end
UI.applyOutput = applyOutput

------------------------------------------------------------------------------
-- State loading, dialog
------------------------------------------------------------------------------

-- Reads layers and stored settings for the active sprite (no UI changes).
local function loadState(ctx)
  local sprite = app.sprite
  local light = ctx.light
  light.sprite = sprite
  light.records = sprite and ctx.lightAseprite.imageLayers(sprite, ctx.namespace) or {}
  light.shared = ctx.lightAseprite.loadShared(sprite, ctx.namespace)
  local hasShared = sprite ~= nil and pcall(function()
    assert(sprite.properties(ctx.namespace).paletteTrioLightShared ~= nil)
  end)
  if not hasShared then light.shared.levels = ctx.model.shadeCount end

  -- Checked layers: the stored set, else the stored single layer, else the
  -- editor's active layer, else the first layer with a cel on this frame.
  light.frame = sprite and clampFrame(ctx, editorFrame()) or 1
  local selected = {}
  for _, uuid in ipairs(light.shared.sourceLayerUuids or {}) do
    if recordByUuid(ctx, uuid) then selected[uuid] = true end
  end
  if next(selected) == nil and recordByUuid(ctx, light.shared.sourceLayerUuid) then
    selected[light.shared.sourceLayerUuid] = true
  end
  if next(selected) == nil then
    local pick
    local siteLayer = sprite and app.layer
    for _, record in ipairs(light.records) do
      if record.layer == siteLayer then pick = record end
    end
    if not pick then
      for i = #light.records, 1, -1 do
        local ok, cel = pcall(function() return light.records[i].layer:cel(light.frame) end)
        if ok and cel then pick = light.records[i]; break end
      end
    end
    pick = pick or light.records[#light.records]
    if pick then selected[pick.uuid] = true end
  end
  light.selected = selected
  local active = recordByUuid(ctx, light.shared.sourceLayerUuid)
  if not (active and selected[active.uuid]) then
    active = nil
    for _, record in ipairs(light.records) do if selected[record.uuid] then active = record end end
  end
  light.activeUuid = active and active.uuid or nil
  light.layer = ctx.lightAseprite.loadLayerSettings(active and active.layer, ctx.namespace)
  light.layerScroll = math.min(light.layerScroll or 0, ctx.lightWidgets.Layers.maxScroll(light.listH or PREVIEW_HEIGHT, #light.records))
  light.frameScroll = ctx.lightWidgets.Frames.scrollToShow(light.stripWidth or 200, sprite and frameCount(ctx) or 1,
    light.frame, light.frameScroll or 0, light.cellW)
  ctx.lightJob.invalidate(ctx)
end

local function updateApplyButton(ctx)
  local dlg = ctx.lightDialog
  if not dlg then return end
  local replace = ctx.light.outputMode == OUTPUT_REPLACE
  dlg:modify { id = "applyLight", text = replace and "Replace source..." or "Apply to new layer" }
end

local function buildDialog(ctx)
  loadState(ctx)
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
      ctx.light.picking, ctx.light.keeping = false, false
      if ctx.ui then pcall(ctx.ui.repaint, ctx) end
    end,
  }
  if not dlg then return end
  ctx.lightDialog = dlg
  local W = ctx.lightWidgets
  local function previewChange()
    readDialogSettings(ctx)
    updateDialogData(ctx, true)
    UI.regeneratePreview(ctx)
  end
  -- Shape and Material share a row: their options explain themselves.
  dlg:combobox { id = "shape", label = "Shape", options = shapeLabels(), option = UI.shapeLabel(ctx.light.layer),
    onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "material", options = ctx.lightEngine.MATERIALS, option = ctx.light.layer.material,
    onchange = function() persistAndPreview(ctx) end }
  local formMin, formMax, formValue, formEnabled = UI.formRange(ctx.light.layer)
  dlg:slider { id = "form", label = "Form", min = formMin, max = formMax, value = formValue, enabled = formEnabled,
    onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:button { id = "pick", label = "Family", text = "Pick", onclick = function()
    local start = not ctx.light.picking
    stopPicking(ctx)
    ctx.light.picking = start
    dlg:modify { id = "pick", text = ctx.light.picking and "Picking..." or "Pick" }
    pcall(function() dlg:modify { id = "lightPreview", mousecursor = ctx.light.picking and MouseCursor.CROSSHAIR or MouseCursor.ARROW } end)
    if ctx.light.picking then setStatus(ctx, "Click the object in the preview") end
    dlg:repaint()
  end }
  dlg:button { id = "autoFamily", text = "Auto", onclick = function()
    stopPicking(ctx)
    ctx.light.layer.familyRowId = nil
    saveSettings(ctx)
    UI.regeneratePreview(ctx)
    setStatus(ctx, "Family is detected automatically")
  end }
  dlg:newrow()

  -- Layer list (left) and preview (right) share a row.
  dlg:canvas {
    id = "layerList", width = W.Layers.WIDTH, height = PREVIEW_HEIGHT, autoscaling = true, vexpand = true,
    onpaint = function(ev) paintLayerList(ctx, ev.context) end,
    onmousedown = function(ev)
      if ev.button ~= MouseButton.LEFT then return end
      local hit = W.Layers.hit(ctx.light.listW or W.Layers.WIDTH, ctx.light.listH or PREVIEW_HEIGHT,
        #ctx.light.records, ctx.light.layerScroll or 0, ev.x, ev.y)
      if not hit then return end
      if hit.kind == "all" then UI.selectAllLayers(ctx, true)
      elseif hit.kind == "none" then UI.selectAllLayers(ctx, false)
      else
        local record = ctx.light.records[#ctx.light.records - hit.index + 1]
        if record then
          if hit.kind == "box" then UI.toggleLayer(ctx, record.uuid) else UI.soloLayer(ctx, record.uuid) end
        end
      end
      dlg:repaint()
    end,
    onwheel = function(ev)
      local max = W.Layers.maxScroll(ctx.light.listH or PREVIEW_HEIGHT, #ctx.light.records)
      ctx.light.layerScroll = math.max(0, math.min(max, (ctx.light.layerScroll or 0) + ((ev.deltaY or 0) > 0 and 1 or -1)))
      dlg:repaint()
    end,
  }
  dlg:canvas {
    id = "lightPreview", width = PREVIEW_WIDTH, height = PREVIEW_HEIGHT,
    autoscaling = true, hexpand = true, vexpand = true,
    onpaint = function(ev) drawPreview(ctx, ev) end,
    onmousedown = function(ev)
      -- Pick mode (or right-click): eyedropper. Middle or Alt/Shift+drag:
      -- pan. Otherwise place / drag the light anywhere.
      if ev.button == MouseButton.LEFT and not ctx.light.keeping and not ctx.light.picking
        and inFamilyTag(ctx, ev.x, ev.y) then
        UI.onFamilyTag(ctx)
        return
      end
      if ctx.light.keeping and ev.button == MouseButton.LEFT then
        UI.keepAt(ctx, ev.x, ev.y)
        return
      end
      if (ctx.light.picking and ev.button == MouseButton.LEFT) or ev.button == MouseButton.RIGHT then
        UI.pickAt(ctx, ev.x, ev.y)
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
      local over = inFamilyTag(ctx, ev.x, ev.y) and not ctx.light.dragging and not ctx.light.panning
      if over ~= (ctx.light.hoverTag or false) then
        ctx.light.hoverTag = over
        dlg:repaint()
      end
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
      local sprite = ctx.light.sprite
      if not sprite or not ctx.light.viewT then return end
      local steps = (ev.deltaY or 0) > 0 and 1 or ((ev.deltaY or 0) < 0 and -1 or 0)
      local gcW = ctx.light.canvasW or PREVIEW_WIDTH
      local gcH = ctx.light.canvasH or PREVIEW_HEIGHT
      ctx.lightView.zoomAt(ctx.light.view, gcW, gcH, sprite.width, sprite.height, ev.x, ev.y, steps)
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
  -- Frame strip: one row of frames, under the preview.
  dlg:canvas {
    id = "frameStrip", width = 120, height = W.Frames.HEIGHT, autoscaling = true, hexpand = true,
    onpaint = function(ev) paintFrameStrip(ctx, ev.context) end,
    onmousedown = function(ev)
      if ev.button ~= MouseButton.LEFT then return end
      local frame = W.Frames.hit(ctx.light.stripWidth or 120, frameCount(ctx), ctx.light.frameScroll or 0, ev.x, ev.y,
        ctx.light.cellW)
      if frame then UI.setFrame(ctx, frame) end
    end,
    onwheel = function(ev)
      ctx.light.frameScroll = W.Frames.scrollBy(ctx.light.stripWidth or 120, frameCount(ctx),
        ctx.light.frameScroll or 0, (ev.deltaY or 0) > 0 and 1 or -1, ctx.light.cellW)
      dlg:repaint()
    end,
  }
  dlg:newrow()
  dlg:label { id = "lightStatus", text = "Preparing preview..." }
  dlg:slider { id = "lightHeight", label = "Height", min = 1, max = 256, value = math.floor((ctx.light.shared.lightHeight or 32) + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "falloff", label = "Falloff", min = 0, max = 100, value = math.floor(ctx.light.shared.falloff + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:slider { id = "lightStrength", label = "Contrast", min = 0, max = 200, value = math.floor(ctx.light.shared.strength * 100 + 0.5), onchange = previewChange, onrelease = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "levels", label = "Shades", options = { "3", "5" }, option = tostring(ctx.light.shared.levels), onchange = function() persistAndPreview(ctx) end }
  dlg:combobox { id = "dither", options = { "No dither", "Bayer 2x2", "Bayer 4x4" },
    option = ctx.light.shared.dither == "Off" and "No dither" or ctx.light.shared.dither,
    onchange = function() persistAndPreview(ctx) end }
  -- Output and Frames share a row.
  dlg:combobox { id = "output", label = "Output", options = { OUTPUT_NEW, OUTPUT_REPLACE },
    option = ctx.light.outputMode, onchange = function()
      ctx.light.outputMode = dlg.data.output == OUTPUT_REPLACE and OUTPUT_REPLACE or OUTPUT_NEW
      updateApplyButton(ctx)
    end }
  dlg:combobox { id = "scope", options = { SCOPE_THIS, SCOPE_ALL }, option = ctx.light.scope,
    onchange = function()
      ctx.light.scope = dlg.data.scope == SCOPE_ALL and SCOPE_ALL or SCOPE_THIS
    end }
  dlg:newrow()
  dlg:check { id = "preserveOutlines", text = "Keep outlines", selected = ctx.light.shared.preserveOutlines, onclick = function() persistAndPreview(ctx) end }
  dlg:check { id = "separateComponents", text = "Separate objects", selected = ctx.light.shared.separateComponents, onclick = function() persistAndPreview(ctx) end }
  -- Colors Light must not shade: click them in the preview.
  dlg:button { id = "keepAdd", label = "Keep", text = "Add color", onclick = function()
    local start = not ctx.light.keeping
    stopPicking(ctx)
    ctx.light.keeping = start
    updateKeepControls(ctx)
    if start then setStatus(ctx, "Click the colors Light should leave alone") end
  end }
  dlg:button { id = "keepClear", text = "Clear", enabled = #(ctx.light.layer.excludedColors or {}) > 0, onclick = function()
    ctx.light.layer.excludedColors = {}
    saveSettings(ctx)
    UI.regeneratePreview(ctx)
    updateKeepControls(ctx)
  end }
  dlg:separator()
  dlg:button { id = "applyLight", text = "Apply to new layer", focus = true, onclick = function() applyOutput(ctx) end }
  dlg:button { id = "refreshLayers", text = "Refresh", onclick = function() UI.reload(ctx) end }
  -- Light shades with the Palette Trio families, so this opens the choice of
  -- which palette colors are families (and makes sure the panel is open).
  -- The preview refreshes when the choice is applied.
  dlg:button { id = "openPalette", text = "Families...", onclick = function()
    ctx.ui.open(ctx)
    if ctx.currentSprite then ctx.dialogs.openChooser(ctx, "palette") end
  end }
  -- autoscrollbars: if the window does not fit the screen (or is made
  -- smaller), Aseprite adds scrollbars instead of cutting controls off.
  dlg:show { wait = false, autoscrollbars = true,
    bounds = ctx.ui.validBounds(ctx.preferences and ctx.preferences.lightBounds) }
  updateDialogData(ctx)
  updateKeepControls(ctx)
  updateApplyButton(ctx)
  UI.regeneratePreview(ctx)
end

-- Opens Light; only reachable from the Palette Trio panel.
function UI.open(ctx)
  ctx.light = ctx.light or {}
  ctx.light.cache = ctx.light.cache or { normalEntries = {} }
  ctx.light.snapshots = ctx.light.snapshots or {}
  ctx.light.outputMode = ctx.light.outputMode or OUTPUT_NEW
  ctx.light.scope = ctx.light.scope or SCOPE_THIS
  ctx.light.view = ctx.light.view or ctx.lightView.new()
  ctx.light.selected = ctx.light.selected or {}
  ctx.light.records = ctx.light.records or {}
  ctx.light.skipped, ctx.light.layerFamilies = {}, {}
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
  if not dlg then return false end
  if app.sprite ~= ctx.light.sprite then
    ctx.light.selected, ctx.light.activeUuid = {}, nil
    ctx.light.snapshots = ctx.light.snapshots or {}
  end
  loadState(ctx)
  updateDialogData(ctx)
  updateKeepControls(ctx)
  if app.sprite then
    return UI.regeneratePreview(ctx)
  end
  clearPreview(ctx)
  setStatus(ctx, "No sprite", "Open an RGB sprite to preview lighting.")
  repaintAll(ctx)
  return false
end

function UI.refresh(ctx) return UI.reload(ctx) end
function UI.onSpriteChange(ctx) return UI.reload(ctx) end
function UI.onUndo(ctx) return UI.reload(ctx) end

return UI
