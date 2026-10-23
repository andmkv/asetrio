-- Aseprite-facing integration. The geometry and color logic lives in light_engine.lua.
local Aseprite = {}

local function copyColor(color)
  return { r = color.r, g = color.g, b = color.b }
end

local function copyColors(colors)
  local result = {}
  if type(colors) == "table" then
    for _, color in ipairs(colors) do
      if type(color) == "table" and color.r and color.g and color.b then
        result[#result + 1] = { r = color.r, g = color.g, b = color.b }
      end
    end
  end
  return result
end

function Aseprite.defaultShared()
  return {
    directionX = -0.65,
    directionY = -0.45,
    elevation = 45,
    strength = 1,
    levels = 3,
    dither = "Off",
    preserveOutlines = false,
    separateComponents = true,
    sourceLayerUuid = "",
  }
end

function Aseprite.defaultLayer()
  return {
    shape = "Round / Sphere",
    cylinderAxis = "Horizontal",
    bevel = 4,
    curvature = 1,
    excludedColors = {},
    lightProfile = "default",
  }
end

local function bound(value, low, high, fallback)
  value = tonumber(value)
  if not value then return fallback end
  return math.max(low, math.min(high, value))
end

function Aseprite.normalizeShared(value)
  local result = Aseprite.defaultShared()
  if type(value) ~= "table" then return result end
  result.directionX = bound(value.directionX, -1, 1, result.directionX)
  result.directionY = bound(value.directionY, -1, 1, result.directionY)
  local length = math.sqrt(result.directionX * result.directionX + result.directionY * result.directionY)
  if length < 1e-8 then result.directionX, result.directionY = -0.65, -0.45
  else result.directionX, result.directionY = result.directionX / length, result.directionY / length end
  result.elevation = bound(value.elevation, 1, 89, result.elevation)
  result.strength = bound(value.strength, 0, 2, result.strength)
  result.levels = value.levels == 5 and 5 or 3
  if value.dither == "Bayer 2x2" or value.dither == "Bayer 4x4" then result.dither = value.dither end
  result.preserveOutlines = value.preserveOutlines == true
  result.separateComponents = value.separateComponents ~= false
  result.sourceLayerUuid = type(value.sourceLayerUuid) == "string" and value.sourceLayerUuid or ""
  return result
end

function Aseprite.normalizeLayer(value)
  local result = Aseprite.defaultLayer()
  if type(value) ~= "table" then return result end
  local shapes = {
    ["Round / Sphere"] = true,
    ["Box / Beveled rectangle"] = true,
    ["Cylinder"] = true,
    ["Contour / Auto Relief"] = true,
  }
  if shapes[value.shape] then result.shape = value.shape end
  if value.cylinderAxis == "Vertical" then result.cylinderAxis = "Vertical" end
  result.bevel = bound(value.bevel, 1, 64, result.bevel)
  result.curvature = bound(value.curvature, 0.25, 3, result.curvature)
  result.excludedColors = copyColors(value.excludedColors)
  if type(value.lightProfile) == "string" and value.lightProfile ~= "" then result.lightProfile = value.lightProfile end
  -- Explicitly picked Palette Trio family (row id); nil means automatic.
  local rowId = tonumber(value.familyRowId)
  if rowId and rowId >= 1 then result.familyRowId = math.floor(rowId) end
  return result
end

function Aseprite.loadShared(sprite, namespace)
  if not sprite then return Aseprite.defaultShared() end
  local ok, value = pcall(function() return sprite.properties(namespace).paletteTrioLightShared end)
  return Aseprite.normalizeShared(ok and value or nil)
end

function Aseprite.saveShared(sprite, namespace, settings)
  if not sprite then return false end
  local ok = pcall(function()
    sprite.properties(namespace).paletteTrioLightShared = Aseprite.normalizeShared(settings)
  end)
  return ok
end

function Aseprite.loadLayerSettings(layer, namespace)
  if not layer then return Aseprite.defaultLayer() end
  local ok, value = pcall(function() return layer.properties(namespace).paletteTrioLight end)
  return Aseprite.normalizeLayer(ok and value or nil)
end

function Aseprite.saveLayerSettings(layer, namespace, settings)
  if not layer then return false end
  local ok = pcall(function()
    layer.properties(namespace).paletteTrioLight = Aseprite.normalizeLayer(settings)
  end)
  return ok
end

function Aseprite.isGeneratedLayer(layer, namespace)
  local ok, value = pcall(function() return layer.properties(namespace).paletteTrioLightOutput end)
  return ok and type(value) == "table" and value.generated == true
end

local function effectivelyVisible(layer, parentVisible)
  if not parentVisible or not layer.isVisible then return false end
  -- Top-level layers have the Sprite as parent, which has no isGroup field
  -- (indexing it raises an error), so stop at the first non-group parent.
  local parent = layer.parent
  while parent do
    local ok, isGroup = pcall(function() return parent.isGroup end)
    if not ok or not isGroup then break end
    if not parent.isVisible then return false end
    parent = parent.parent
  end
  return true
end

local function walkLayers(layers, namespace, frameNumber, parentVisible, depth, output)
  for _, layer in ipairs(layers or {}) do
    local visible = parentVisible and layer.isVisible
    if layer.isGroup then
      walkLayers(layer.layers, namespace, frameNumber, visible, depth + 1, output)
    elseif layer.isImage and not layer.isTilemap and not layer.isReference
      and visible and not Aseprite.isGeneratedLayer(layer, namespace) then
      local ok, cel = pcall(function() return layer:cel(frameNumber) end)
      if ok and cel and cel.image and effectivelyVisible(layer, parentVisible) then
        local uuid = tostring(layer.uuid)
        local name = layer.name or "Layer"
        output[#output + 1] = {
          layer = layer,
          cel = cel,
          uuid = uuid,
          name = name,
          label = string.rep("  ", depth) .. name,
        }
      end
    end
  end
end

function Aseprite.sourceLayers(sprite, frameNumber, namespace)
  local output = {}
  if not sprite then return output end
  walkLayers(sprite.layers, namespace, frameNumber, true, 0, output)
  -- Labels must be unique for the combobox; disambiguate repeated names only.
  local seen = {}
  for _, record in ipairs(output) do seen[record.label] = (seen[record.label] or 0) + 1 end
  for _, record in ipairs(output) do
    if seen[record.label] > 1 then record.label = record.label .. " [" .. record.uuid:sub(-4) .. "]" end
  end
  return output
end

function Aseprite.findSource(layers, uuid)
  for _, record in ipairs(layers or {}) do
    if record.uuid == uuid then return record end
  end
  return nil
end

function Aseprite.isRgbSprite(sprite)
  return sprite ~= nil and sprite.colorMode == ColorMode.RGB
end

-- imageOverride: read these pixels instead of the cel's current image (used to
-- re-shade from the original snapshot after a source replacement).
function Aseprite.readCel(cel, imageOverride)
  if not cel or not cel.image then return nil, "The selected layer has no cel in the active frame." end
  local image = imageOverride or cel.image
  if image.colorMode ~= ColorMode.RGB then
    return nil, "Palette Trio Light processes RGB cels only. Indexed, grayscale, and tilemap pixels are left untouched."
  end
  local pc = app.pixelColor
  local pixels = {}
  for y = 0, image.height - 1 do
    for x = 0, image.width - 1 do
      local value = image:getPixel(x, y)
      pixels[y * image.width + x + 1] = {
        r = pc.rgbaR(value),
        g = pc.rgbaG(value),
        b = pc.rgbaB(value),
        a = pc.rgbaA(value),
      }
    end
  end
  return {
    width = image.width,
    height = image.height,
    pixels = pixels,
    position = { x = cel.position.x, y = cel.position.y },
    opacity = cel.opacity,
    zIndex = cel.zIndex,
    imageId = image.id,
    imageVersion = image.version,
  }
end

local function imageBytes(image)
  local ok, bytes = pcall(function() return image.bytes end)
  if ok and type(bytes) == "string" then return bytes end
  return nil
end
Aseprite.imageBytes = imageBytes

-- Replaces the source cel's pixels in the active frame with the shaded image,
-- as one undoable transaction. Position, opacity, z-index, other cels, other
-- layers and frames are untouched. Returns ok, snapshot-or-reason.
-- The snapshot keeps the original pixels so a later Apply re-shades from the
-- original instead of compounding (see Aseprite.snapshotSource).
function Aseprite.replaceSource(sprite, sourceRecord, frameNumber, image)
  if not sprite or not sourceRecord then return false, "Choose a source layer first." end
  if not Aseprite.isRgbSprite(sprite) then
    return false, "Palette Trio Light supports RGB sprites only. The sprite was not changed."
  end
  local layer = sourceRecord.layer
  if layer.isGroup or layer.isTilemap or layer.isReference then
    return false, "Choose an editable RGB image layer."
  end
  if not layer.isEditable then return false, "The source layer is locked. Unlock it to replace its pixels." end
  local cel = layer:cel(frameNumber)
  if not cel or not cel.image then return false, "The source layer has no cel in the active frame." end
  if cel.image.width ~= image.width or cel.image.height ~= image.height then
    return false, "The source cel changed size. Refresh the preview and try again."
  end
  local original = Image(cel.image)
  local ok, reason = pcall(function()
    app.transaction("Palette Trio Light: replace source", function()
      cel.image = image
    end)
  end)
  if not ok then return false, tostring(reason) end
  return true, {
    original = original,
    appliedBytes = imageBytes(cel.image),
    width = image.width,
    height = image.height,
  }
end

-- Returns the snapshot's original image when the cel still holds exactly the
-- pixels Palette Trio wrote; otherwise (undo, repaint, new art) nil.
function Aseprite.snapshotSource(snapshot, cel)
  if not snapshot or not cel or not cel.image or not snapshot.appliedBytes then return nil end
  if cel.image.width ~= snapshot.width or cel.image.height ~= snapshot.height then return nil end
  if imageBytes(cel.image) ~= snapshot.appliedBytes then return nil end
  return snapshot.original
end

function Aseprite.makeImage(width, height, pixels)
  local image = Image(width, height, ColorMode.RGB)
  local pc = app.pixelColor
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local pixel = pixels[y * width + x + 1]
      image:drawPixel(x, y, pc.rgba(pixel.r, pixel.g, pixel.b, pixel.a))
    end
  end
  return image
end

local function walkGenerated(layers, namespace, sourceUuid)
  for _, layer in ipairs(layers or {}) do
    if layer.isGroup then
      local found = walkGenerated(layer.layers, namespace, sourceUuid)
      if found then return found end
    else
      local ok, metadata = pcall(function() return layer.properties(namespace).paletteTrioLightOutput end)
      if ok and type(metadata) == "table" and metadata.generated == true
        and metadata.sourceLayerUuid == sourceUuid then
        return layer
      end
    end
  end
  return nil
end

function Aseprite.applyOutput(sprite, sourceRecord, frameNumber, image, sourceCel, settings, namespace)
  if not sprite or not sourceRecord or not sourceCel then return false, "Choose a source layer with a cel in the active frame." end
  if not Aseprite.isRgbSprite(sprite) then
    return false, "Palette Trio Light supports RGB sprites only. Indexed and grayscale sprites were not changed."
  end
  if sourceRecord.layer.isGroup or sourceRecord.layer.isTilemap or sourceRecord.layer.isReference then
    return false, "Choose an editable RGB image layer. Groups, tilemaps, and reference layers are unsupported."
  end
  local outputLayer = walkGenerated(sprite.layers, namespace, sourceRecord.uuid)
  local oldCel = outputLayer and outputLayer:cel(frameNumber) or nil
  if outputLayer and not outputLayer.isEditable then
    return false, "The existing Palette Trio Light output layer is locked. Unlock it to regenerate."
  end

  local ok, reason = pcall(function()
    app.transaction("Apply Palette Trio Light", function()
      if not outputLayer then
        outputLayer = sprite:newLayer()
        outputLayer.name = "Palette Trio Light - " .. (sourceRecord.layer.name or "Source")
        if sourceRecord.layer.parent ~= sprite then outputLayer.parent = sourceRecord.layer.parent end
        outputLayer.stackIndex = sourceRecord.layer.stackIndex + 1
      end
      if oldCel then sprite:deleteCel(oldCel) end
      local newCel = sprite:newCel(outputLayer, frameNumber, image, Point(sourceCel.position.x, sourceCel.position.y))
      newCel.opacity = sourceCel.opacity
      newCel.zIndex = sourceCel.zIndex
      outputLayer.opacity = sourceRecord.layer.opacity
      outputLayer.blendMode = sourceRecord.layer.blendMode
      outputLayer.isVisible = true
      outputLayer.properties(namespace).paletteTrioLightOutput = {
        generated = true,
        sourceLayerUuid = sourceRecord.uuid,
        sourceName = sourceRecord.layer.name or "Source",
        frameNumber = frameNumber,
        settings = Aseprite.normalizeLayer(settings),
      }
    end)
  end)
  if not ok then return false, tostring(reason) end
  return true, outputLayer
end

return Aseprite
