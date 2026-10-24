-- Shading jobs for Palette Trio Light. The preview and Apply use the same
-- code: for a list of layers and frames, read each cel (re-shading from the
-- remembered original when Replace source was used), detect its family and
-- render it with one shared point light. Pure Lua over the engine; the only
-- Aseprite calls are Layer:cel and the readers in light_aseprite.
local Job = {}

-- Bounding box of the opaque pixels of a cel (cel-local), or nil if empty.
function Job.objectBounds(data)
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

-- Drops cached cel data. Call after anything that can change pixels:
-- Refresh, undo, sprite changes, frame changes, Apply.
function Job.invalidate(ctx)
  ctx.light.dataCache = {}
  ctx.light.celMap = nil
end

local function celAt(record, frame)
  local ok, cel = pcall(function() return record.layer:cel(frame) end)
  if ok and cel and cel.image then return cel end
  return nil
end

-- Pixel data of a layer on a frame (cached), or nil when it has no cel there.
function Job.read(ctx, record, frame)
  local cel = celAt(record, frame)
  if not cel then return nil end
  local light = ctx.light
  light.dataCache = light.dataCache or {}
  local key = record.uuid .. ":" .. tostring(frame)
  local image = cel.image
  local hit = light.dataCache[key]
  if hit and hit.width == image.width and hit.height == image.height
    and hit.x == cel.position.x and hit.y == cel.position.y then
    return hit.entry
  end
  local original = ctx.lightAseprite.snapshotSource((light.snapshots or {})[key], cel)
  local data, reason = ctx.lightAseprite.readCel(cel, original)
  if not data then return nil, reason end
  local entry = {
    record = record, frame = frame, cel = cel, data = data,
    usingSnapshot = original ~= nil, bounds = Job.objectBounds(data),
  }
  light.dataCache[key] = { width = image.width, height = image.height,
    x = cel.position.x, y = cel.position.y, entry = entry }
  return entry
end

-- Union of the objects of several entries, in sprite coordinates:
-- { x, y, width, height, centerX, centerY, size } or nil.
function Job.sceneBounds(entries)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for _, entry in ipairs(entries) do
    local b = entry.bounds
    if b then
      local ox, oy = entry.cel.position.x, entry.cel.position.y
      minX, minY = math.min(minX, ox + b.x), math.min(minY, oy + b.y)
      maxX, maxY = math.max(maxX, ox + b.x + b.width), math.max(maxY, oy + b.y + b.height)
    end
  end
  if minX == math.huge then return nil end
  return { x = minX, y = minY, width = maxX - minX, height = maxY - minY,
    centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2, size = math.max(maxX - minX, maxY - minY) }
end

local function familyIndexByRow(families, rowId)
  if not rowId then return nil end
  for i, family in ipairs(families) do
    if family.rowId == rowId then return i end
  end
  return nil
end

-- Shades one cel with the shared settings (ctx.light.shared / ctx.light.layer).
-- scene: { size } of the whole scene on this frame, so every layer is lit by
-- the same light with the same falloff. Returns a result table.
function Job.shade(ctx, entry, families, scene)
  local light = ctx.light
  local shared, layer = light.shared, light.layer
  local engine, data = ctx.lightEngine, entry.data
  local params = {}
  for k, v in pairs(layer) do params[k] = v end
  params.separateComponents = shared.separateComponents
  local mask, key = engine.extractSilhouette(data.pixels, data.width, data.height)
  light.cache = light.cache or { normalEntries = {} }
  local geometry = engine.buildGeometry(mask, data.width, data.height, params, light.cache, key)
  local detection = engine.detectFamily(data.pixels, families, layer.excludedColors)
  local chosen = familyIndexByRow(families, layer.familyRowId)
  local size = (scene and scene.size) or (entry.bounds and entry.bounds.size) or math.max(data.width, data.height)
  local output, stats = engine.render(data.pixels, data.width, data.height, families, geometry, {
    matchShades = true,
    fallbackFamily = chosen,
    material = layer.material,
    levels = shared.levels,
    directionX = shared.directionX,
    directionY = shared.directionY,
    elevation = shared.elevation,
    strength = shared.strength,
    dither = shared.dither,
    preserveOutlines = shared.preserveOutlines,
    excludedColors = layer.excludedColors,
    offsetX = entry.cel.position.x,
    offsetY = entry.cel.position.y,
    pointLight = {
      x = shared.lightX - entry.cel.position.x,
      y = shared.lightY - entry.cel.position.y,
      z = shared.lightHeight,
      falloff = shared.falloff / 100,
      size = size,
    },
  })
  return {
    record = entry.record, frame = entry.frame, cel = entry.cel, data = data,
    bounds = entry.bounds, usingSnapshot = entry.usingSnapshot,
    output = output, stats = stats, detection = detection, chosen = chosen,
    family = families[chosen or detection.index or 0],
    image = ctx.lightAseprite.makeImage(data.width, data.height, output),
  }
end

-- Shades `records` (bottom-to-top) on one frame. Returns { results, skipped,
-- scene }: skipped lists records without a cel on that frame.
function Job.frame(ctx, records, frame, families, prepare)
  local entries, skipped = {}, {}
  for _, record in ipairs(records) do
    local entry = Job.read(ctx, record, frame)
    if entry then entries[#entries + 1] = entry else skipped[#skipped + 1] = record end
  end
  local scene = Job.sceneBounds(entries)
  -- Lets the caller place the light before the first shading, once the
  -- scene (the objects' bounds) is known.
  if prepare then prepare(scene) end
  local results = {}
  for _, entry in ipairs(entries) do results[#results + 1] = Job.shade(ctx, entry, families, scene) end
  return { results = results, skipped = skipped, scene = scene, frame = frame }
end

-- Shades records on several frames. Returns the list of Job.frame results.
function Job.frames(ctx, records, frames, families, prepare)
  local output = {}
  for _, frame in ipairs(frames) do output[#output + 1] = Job.frame(ctx, records, frame, families, prepare) end
  return output
end

return Job
