-- Reads candidate base colors. The native sprite palette is THE default source:
-- every eligible (non-transparent, de-duplicated) entry becomes a family, in
-- palette order. Artwork pixels and palette files are optional import sources.
-- Reading never modifies the sprite.
local Source = {}

-- Artwork scanning (optional import only) stops after this many colors.
Source.ARTWORK_LIMIT = 1024

local function key(rgb)
  return string.format("%d,%d,%d", rgb.r, rgb.g, rgb.b)
end

local function plural(count, word)
  if count == 1 then return string.format("%d %s", count, word) end
  if word:sub(-1) == "y" then return string.format("%d %sies", count, word:sub(1, -2)) end
  return string.format("%d %ss", count, word)
end
Source.plural = plural

-- raw: list of { r, g, b, a, index }. Drops fully transparent entries, the
-- indexed transparent index, and exact RGB duplicates (the first palette slot
-- wins, so slot identity is preserved for the first occurrence).
function Source.dedupe(raw, transparentIndex)
  local entries, seen = {}, {}
  local info = { total = #raw, transparent = 0, duplicates = 0 }
  for _, item in ipairs(raw) do
    if (item.a or 255) == 0 or (transparentIndex ~= nil and item.index == transparentIndex) then
      info.transparent = info.transparent + 1
    else
      local color = { r = item.r, g = item.g, b = item.b }
      local k = key(color)
      if seen[k] then
        info.duplicates = info.duplicates + 1
      else
        seen[k] = true
        entries[#entries + 1] = { color = color, index = item.index, count = item.count }
      end
    end
  end
  return entries, info
end

-- Removes entries Palette Trio itself wrote into the palette as shades
-- (recorded provenance), unless the color is also a family base. No guessing:
-- an authored color that merely resembles a shade is always kept.
function Source.removeGenerated(entries, model)
  if not model or not model.generated or next(model.generated) == nil then return entries, 0 end
  local bases = {}
  for _, row in ipairs(model.rows) do bases[key(row.base)] = true end
  local kept, removed = {}, 0
  for _, entry in ipairs(entries) do
    local k = key(entry.color)
    if model.generated[k] and not bases[k] then removed = removed + 1 else kept[#kept + 1] = entry end
  end
  return kept, removed
end

-- Counts RGBA pixels from an Image.bytes string. Integer keys keep it fast.
-- Returns false when more than `limit` distinct colors exist.
function Source.countRgbaBytes(bytes, counts, state, limit)
  local byte = string.byte
  for i = 1, #bytes - 3, 4 do
    local r, g, b, a = byte(bytes, i, i + 3)
    if a > 0 then
      local k = (r * 256 + g) * 256 + b
      local c = counts[k]
      if c then
        counts[k] = c + 1
      else
        state.distinct = state.distinct + 1
        if state.distinct > limit then return false end
        counts[k] = 1
      end
    end
  end
  return true
end

local function intKeyToRgb(k)
  return { r = k // 65536, g = (k // 256) % 256, b = k % 256 }
end

-- Sorts artwork colors by usage (most used first).
function Source.orderArtwork(counts)
  local list = {}
  for k, count in pairs(counts) do list[#list + 1] = { color = intKeyToRgb(k), count = count } end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return key(a.color) < key(b.color)
  end)
  return list
end

-- Artwork import candidates exclude current family bases and their exact
-- generated shades (colors painted with Palette Trio itself).
function Source.removeKnown(entries, model)
  if not model then return entries, 0 end
  local known = model.derivedColorKeys(model)
  for _, row in ipairs(model.rows) do known[key(row.base)] = true end
  local kept, removed = {}, 0
  for _, entry in ipairs(entries) do
    if known[key(entry.color)] then removed = removed + 1 else kept[#kept + 1] = entry end
  end
  return kept, removed
end

------------------------------------------------------------------------------
-- Aseprite-facing readers
------------------------------------------------------------------------------

local function indexedTransparent(sprite)
  if sprite.colorMode == ColorMode.INDEXED then return sprite.transparentColor end
  return nil
end

-- All eligible native palette colors, in palette order.
function Source.readPalette(sprite, model)
  if not sprite or not sprite.palettes or not sprite.palettes[1] then return nil end
  local palette = sprite.palettes[1]
  local raw = {}
  for index = 0, #palette - 1 do
    local c = palette:getColor(index)
    raw[#raw + 1] = { r = c.red, g = c.green, b = c.blue, a = c.alpha, index = index }
  end
  local entries, info = Source.dedupe(raw, indexedTransparent(sprite))
  entries, info.generated = Source.removeGenerated(entries, model)
  info.entries = entries
  return info
end

function Source.paletteSignature(sprite)
  if not sprite or not sprite.palettes or not sprite.palettes[1] then return "" end
  local palette = sprite.palettes[1]
  local parts = { tostring(#palette) }
  for index = 0, #palette - 1 do
    local c = palette:getColor(index)
    parts[#parts + 1] = string.format("%02x%02x%02x%02x", c.red, c.green, c.blue, c.alpha)
  end
  return table.concat(parts)
end

local function isGenerated(layer, namespace)
  local ok, value = pcall(function() return layer.properties(namespace).paletteTrioLightOutput end)
  return ok and type(value) == "table" and value.generated == true
end

local function celImageBytes(image)
  local ok, bytes = pcall(function() return image.bytes end)
  if ok and type(bytes) == "string" then return bytes end
  return nil
end

-- Optional import source: unique colors used in image cels (all frames),
-- excluding tilemap, reference, and Palette Trio Light output layers.
function Source.readArtwork(sprite, namespace, model, limit)
  if not sprite then return nil end
  limit = limit or Source.ARTWORK_LIMIT
  local counts, state = {}, { distinct = 0 }
  local seenImages = {}
  local tooMany = false
  local mode = sprite.colorMode
  local palette = sprite.palettes[1]
  local transparent = indexedTransparent(sprite)
  local pc = app.pixelColor

  local function add(r, g, b)
    local k = (r * 256 + g) * 256 + b
    local c = counts[k]
    if c then counts[k] = c + 1; return true end
    state.distinct = state.distinct + 1
    if state.distinct > limit then return false end
    counts[k] = 1
    return true
  end

  for _, cel in ipairs(sprite.cels) do
    local layer = cel.layer
    local image = cel.image
    if image and layer.isImage and not layer.isTilemap and not layer.isReference
      and not isGenerated(layer, namespace) then
      local id = image.id
      if not seenImages[id] then
        seenImages[id] = true
        local bytes = mode == ColorMode.RGB and celImageBytes(image) or nil
        if bytes then
          if not Source.countRgbaBytes(bytes, counts, state, limit) then tooMany = true; break end
        else
          for it in image:pixels() do
            local v = it()
            local ok = true
            if mode == ColorMode.RGB then
              if pc.rgbaA(v) > 0 then ok = add(pc.rgbaR(v), pc.rgbaG(v), pc.rgbaB(v)) end
            elseif mode == ColorMode.INDEXED then
              if v ~= transparent and v < #palette then
                local c = palette:getColor(v)
                if c.alpha > 0 then ok = add(c.red, c.green, c.blue) end
              end
            elseif mode == ColorMode.GRAY then
              if pc.grayaA(v) > 0 then local g = pc.grayaV(v); ok = add(g, g, g) end
            end
            if not ok then tooMany = true; break end
          end
          if tooMany then break end
        end
      end
    end
  end

  local entries, known = Source.removeKnown(Source.orderArtwork(counts), model)
  return { entries = entries, tooMany = tooMany, known = known, distinct = state.distinct }
end

return Source
