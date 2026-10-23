local Aseprite = {}

local function sameOpaqueRgb(a, b)
  return a.r == b.r and a.g == b.g and a.b == b.b and (a.a or 255) == 255
end

function Aseprite.rgb(color)
  return { r = color.red, g = color.green, b = color.blue }
end

function Aseprite.color(rgb)
  return Color { r = rgb.r, g = rgb.g, b = rgb.b, a = 255 }
end

function Aseprite.paletteColors(palette)
  local colors = {}
  for index = 0, #palette - 1 do
    colors[#colors + 1] = Aseprite.rgb(palette:getColor(index))
  end
  return colors
end

function Aseprite.paletteEntries(palette)
  local colors = {}
  for index = 0, #palette - 1 do
    local color = palette:getColor(index)
    colors[#colors + 1] = {
      r = color.red,
      g = color.green,
      b = color.blue,
      a = color.alpha,
    }
  end
  return colors
end

function Aseprite.indexedPlan(existingColors, desiredColors, maxEntries)
  maxEntries = maxEntries or 256
  local existingCount = #existingColors
  if existingCount > maxEntries then
    return nil, "The existing indexed palette exceeds the supported 256-color limit."
  end
  local additions = {}
  for _, desired in ipairs(desiredColors) do
    local found = false
    for _, current in ipairs(existingColors) do
      if sameOpaqueRgb(current, desired) then found = true; break end
    end
    if not found then
      for _, current in ipairs(additions) do
        if current.r == desired.r and current.g == desired.g and current.b == desired.b then
          found = true
          break
        end
      end
    end
    if not found then additions[#additions + 1] = desired end
  end
  if existingCount + #additions > maxEntries then
    return nil, string.format(
      "This indexed sprite has %d palette entries and needs %d more; the 256-color limit would be exceeded. Existing entries were left untouched.",
      existingCount, #additions)
  end
  return { firstIndex = existingCount, additions = additions, finalCount = existingCount + #additions }
end

-- Reads a palette file as raw entries for the color chooser.
function Aseprite.readPaletteFile(filename)
  local ok, palette = pcall(function() return Palette { fromFile = filename } end)
  if not ok or not palette then return nil, "Could not read palette file: " .. tostring(palette) end
  local raw = {}
  for index = 0, #palette - 1 do
    local c = palette:getColor(index)
    raw[#raw + 1] = { r = c.red, g = c.green, b = c.blue, a = c.alpha, index = index }
  end
  return raw
end

-- Writes generated colors into the sprite palette. mode is "append" (default:
-- only missing colors are added after the existing entries) or "replace"
-- (RGB sprites only). Pixels are never modified. One undoable transaction;
-- `inTransaction` (optional) runs inside it, e.g. to record provenance.
function Aseprite.apply(sprite, colors, mode, inTransaction)
  mode = mode == "replace" and "replace" or "append"
  if not sprite then return false, "Open a sprite before writing to its palette." end
  if #colors == 0 then return false, "There are no families to write." end
  if #colors > 256 then return false, "The generated palette exceeds Aseprite's 256-color palette limit." end
  if sprite.colorMode ~= ColorMode.RGB and sprite.colorMode ~= ColorMode.INDEXED then
    return false, "Writing palettes is supported for RGB and indexed sprites. Grayscale sprites are not changed."
  end
  if #sprite.palettes ~= 1 or not sprite.palettes[1] then
    return false, "This sprite has palette changes across frames. Palette Trio only writes single-palette sprites."
  end

  if mode == "replace" then
    if sprite.colorMode ~= ColorMode.RGB then
      return false, "Indexed palettes are never replaced, because that would recolor the artwork."
    end
    local palette = Palette(#colors)
    for i, rgb in ipairs(colors) do palette:setColor(i - 1, Aseprite.color(rgb)) end
    app.transaction("Palette Trio: replace sprite palette", function()
      sprite:setPalette(palette)
      if inTransaction then inTransaction() end
    end)
    return true, string.format("Sprite palette replaced with %d colors.", #colors)
  end

  local original = sprite.palettes[1]
  local plan, reason = Aseprite.indexedPlan(Aseprite.paletteEntries(original), colors, 256)
  if not plan then return false, reason end
  if #plan.additions == 0 then return true, "All colors are already in the sprite palette." end

  local palette = Palette(original)
  palette:resize(plan.finalCount)
  for i, rgb in ipairs(plan.additions) do
    palette:setColor(plan.firstIndex + i - 1, Aseprite.color(rgb))
  end
  app.transaction("Palette Trio: append colors to palette", function()
    sprite:setPalette(palette)
    if inTransaction then inTransaction() end
  end)
  return true, string.format("Appended %d colors after entry %d.", #plan.additions, plan.firstIndex - 1)
end

function Aseprite.export(colors, filename)
  if #colors == 0 then return false, "Add at least one base color before exporting." end
  if #colors > 256 then return false, "The generated palette exceeds Aseprite's 256-color palette limit." end
  local palette = Palette(#colors)
  for i, rgb in ipairs(colors) do palette:setColor(i - 1, Aseprite.color(rgb)) end
  palette:saveAs(filename)
  return true
end

return Aseprite
