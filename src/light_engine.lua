-- Pure-Lua, palette-family-driven stylized lighting.
-- This module deliberately has no dependency on Aseprite or the OKLCH model.
local Engine = {}

local SQRT2 = 1.4142135623730951
local INF = 1e20
local BAYER = {
  ["Bayer 2x2"] = { size = 2, values = { 0, 2, 3, 1 } },
  ["Bayer 4x4"] = {
    size = 4,
    values = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 },
  },
}

local function rgbKey(color)
  return string.format("%d,%d,%d", color.r, color.g, color.b)
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function normalize(x, y, z)
  local length = math.sqrt(x * x + y * y + z * z)
  if length < 1e-12 then return 0, 0, 1 end
  return x / length, y / length, z / length
end

function Engine.extractSilhouette(pixels, width, height)
  assert(type(pixels) == "table", "pixels must be an array")
  assert(width > 0 and height > 0 and #pixels >= width * height, "invalid image dimensions")
  local mask = {}
  local occupied, hashA, hashB = 0, 2166136261, 5381
  local n = width * height
  for i = 1, n do
    local pixel = pixels[i]
    local solid = pixel and (pixel.a or 0) > 0 and 1 or 0
    mask[i] = solid
    if solid == 1 then occupied = occupied + 1 end
    hashA = (hashA * 65599 + solid + 1) % 4294967291
    hashB = (hashB * 131 + solid + (i % 251)) % 4294967279
  end
  return mask, string.format("%dx%d:%.0f:%.0f:%d", width, height, hashA, hashB, occupied)
end

function Engine.silhouetteKey(pixels, width, height)
  local occupied, hashA, hashB = 0, 2166136261, 5381
  for i = 1, width * height do
    local pixel = pixels[i]
    local solid = pixel and (pixel.a or 0) > 0 and 1 or 0
    if solid == 1 then occupied = occupied + 1 end
    hashA = (hashA * 65599 + solid + 1) % 4294967291
    hashB = (hashB * 131 + solid + (i % 251)) % 4294967279
  end
  return string.format("%dx%d:%.0f:%.0f:%d", width, height, hashA, hashB, occupied)
end

function Engine.connectedComponents(mask, width, height)
  local labels, components = {}, {}
  local count = width * height
  for i = 1, count do labels[i] = 0 end
  local queue = {}
  local nextId = 0
  for seed = 1, count do
    if mask[seed] == 1 and labels[seed] == 0 then
      nextId = nextId + 1
      local component = { id = nextId, area = 0, minX = width, minY = height, maxX = 0, maxY = 0 }
      components[#components + 1] = component
      local head, tail = 1, 1
      queue[1], labels[seed] = seed, nextId
      while head <= tail do
        local index = queue[head]
        head = head + 1
        local zero = index - 1
        local x = zero % width + 1
        local y = math.floor(zero / width) + 1
        component.area = component.area + 1
        component.minX = math.min(component.minX, x)
        component.minY = math.min(component.minY, y)
        component.maxX = math.max(component.maxX, x)
        component.maxY = math.max(component.maxY, y)

        if x > 1 then
          local neighbor = index - 1
          if mask[neighbor] == 1 and labels[neighbor] == 0 then labels[neighbor] = nextId; tail = tail + 1; queue[tail] = neighbor end
        end
        if x < width then
          local neighbor = index + 1
          if mask[neighbor] == 1 and labels[neighbor] == 0 then labels[neighbor] = nextId; tail = tail + 1; queue[tail] = neighbor end
        end
        if y > 1 then
          local neighbor = index - width
          if mask[neighbor] == 1 and labels[neighbor] == 0 then labels[neighbor] = nextId; tail = tail + 1; queue[tail] = neighbor end
        end
        if y < height then
          local neighbor = index + width
          if mask[neighbor] == 1 and labels[neighbor] == 0 then labels[neighbor] = nextId; tail = tail + 1; queue[tail] = neighbor end
        end
      end
      for i = 1, tail do queue[i] = nil end
    end
  end
  return labels, components
end

local function outlineMask(mask, width, height)
  local outline = {}
  for i = 1, width * height do
    if mask[i] == 1 then
      local x = (i - 1) % width + 1
      local y = math.floor((i - 1) / width) + 1
      if x == 1 or x == width or y == 1 or y == height
        or mask[i - 1] ~= 1 or mask[i + 1] ~= 1
        or mask[i - width] ~= 1 or mask[i + width] ~= 1 then
        outline[i] = true
      end
    end
  end
  return outline
end

local function makeDistanceField(mask, width, height, labels, component, groupId)
  local left, top, right, bottom = component.minX, component.minY, component.maxX, component.maxY
  local localWidth, localHeight = right - left + 1, bottom - top + 1
  local distances = {}
  local maximum = 0
  for ly = 1, localHeight do
    local y = top + ly - 1
    for lx = 1, localWidth do
      local x = left + lx - 1
      local index = (y - 1) * width + x
      local localIndex = (ly - 1) * localWidth + lx
      if mask[index] == 1 and (groupId == 0 or labels[index] == groupId) then
        local boundary = false
        for dy = -1, 1 do
          for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local nx, ny = x + dx, y + dy
              local neighbor = (nx < 1 or nx > width or ny < 1 or ny > height)
                and 0 or ((mask[(ny - 1) * width + nx] == 1
                  and (groupId == 0 or labels[(ny - 1) * width + nx] == groupId)) and 1 or 0)
              if neighbor == 0 then boundary = true end
            end
          end
        end
        distances[localIndex] = boundary and 1 or INF
      else
        distances[localIndex] = 0
      end
    end
  end
  local function relax(index, neighbor, cost)
    if neighbor and distances[neighbor] + cost < distances[index] then
      distances[index] = distances[neighbor] + cost
    end
  end
  for y = 1, localHeight do
    for x = 1, localWidth do
      local i = (y - 1) * localWidth + x
      if distances[i] > 0 then
        relax(i, x > 1 and i - 1 or nil, 1)
        relax(i, y > 1 and i - localWidth or nil, 1)
        relax(i, x > 1 and y > 1 and i - localWidth - 1 or nil, SQRT2)
        relax(i, x < localWidth and y > 1 and i - localWidth + 1 or nil, SQRT2)
      end
    end
  end
  for y = localHeight, 1, -1 do
    for x = localWidth, 1, -1 do
      local i = (y - 1) * localWidth + x
      if distances[i] > 0 then
        relax(i, x < localWidth and i + 1 or nil, 1)
        relax(i, y < localHeight and i + localWidth or nil, 1)
        relax(i, x < localWidth and y < localHeight and i + localWidth + 1 or nil, SQRT2)
        relax(i, x > 1 and y < localHeight and i + localWidth - 1 or nil, SQRT2)
      end
      if distances[i] > maximum and distances[i] < INF then maximum = distances[i] end
    end
  end
  return { left = left, top = top, width = localWidth, height = localHeight, values = distances, maximum = maximum }
end

local function localDistance(field, x, y)
  if x < 1 or x > field.width or y < 1 or y > field.height then return 0 end
  return field.values[(y - 1) * field.width + x] or 0
end

local function setNormal(normals, index, x, y, z)
  local nx, ny, nz = normalize(x, y, z)
  normals.x[index], normals.y[index], normals.z[index] = nx, ny, nz
end

local function groupFromLabels(labels, components, width, height, separate)
  if separate then return components end
  local all = { id = 0, area = 0, minX = width, minY = height, maxX = 0, maxY = 0 }
  for i, id in ipairs(labels) do
    if id > 0 then
      local x = (i - 1) % width + 1
      local y = math.floor((i - 1) / width) + 1
      all.area = all.area + 1
      all.minX, all.minY = math.min(all.minX, x), math.min(all.minY, y)
      all.maxX, all.maxY = math.max(all.maxX, x), math.max(all.maxY, y)
    end
  end
  return all.area > 0 and { all } or {}
end

local function geometryCacheKey(maskKey, params)
  return table.concat({
    maskKey,
    params.shape or "Sphere",
    params.separateComponents == false and "all" or "separate",
    tostring(params.cylinderAxis or "Horizontal"),
    tostring(params.bevel or 4),
    tostring(params.curvature or 1),
  }, "|")
end

function Engine.buildGeometry(mask, width, height, params, cache, maskKey)
  params = params or {}
  cache = cache or {}
  local key = geometryCacheKey(maskKey or "uncached", params)
  cache.normalEntries = cache.normalEntries or {}
  local cached = cache.normalEntries[key]
  if cached then return cached, true end

  local labels, components = Engine.connectedComponents(mask, width, height)
  local geometry = {
    width = width,
    height = height,
    labels = labels,
    components = components,
    outline = outlineMask(mask, width, height),
    normals = { x = {}, y = {}, z = {} },
    maskKey = maskKey,
    key = key,
  }
  local groups = groupFromLabels(labels, components, width, height, params.separateComponents ~= false)
  local shape = params.shape or "Sphere"
  local bevel = clamp(tonumber(params.bevel) or 4, 1, 64)
  local curvature = clamp(tonumber(params.curvature) or 1, 0.25, 3)

  for _, group in ipairs(groups) do
    local field = makeDistanceField(mask, width, height, labels, group, group.id)
    local left, top, right, bottom = group.minX, group.minY, group.maxX, group.maxY
    local rx = math.max(0.5, (right - left + 1) / 2)
    local ry = math.max(0.5, (bottom - top + 1) / 2)
    local cx, cy = (left + right) / 2, (top + bottom) / 2
    for y = top, bottom do
      for x = left, right do
        local index = (y - 1) * width + x
        if labels[index] > 0 and (params.separateComponents == false or labels[index] == group.id) then
          local nx, ny, nz
          if shape == "Box / Beveled rectangle" then
            local lx = x - field.left + 1
            local ly = y - field.top + 1
            local distance = localDistance(field, lx, ly)
            local gx = (localDistance(field, lx + 1, ly) - localDistance(field, lx - 1, ly)) * 0.5
            local gy = (localDistance(field, lx, ly + 1) - localDistance(field, lx, ly - 1)) * 0.5
            local gl = math.sqrt(gx * gx + gy * gy)
            if distance <= bevel + 1 and gl > 1e-8 then
              local bevelPosition = clamp((distance - 1) / bevel, 0, 1)
              local angle = (1 - bevelPosition) * math.pi / 2
              nx, ny, nz = -gx / gl * math.sin(angle), gy / gl * math.sin(angle), math.cos(angle)
            else
              nx, ny, nz = 0, 0, 1
            end
          elseif shape == "Cylinder" then
            if params.cylinderAxis == "Vertical" then
              local t = clamp((x - cx) / rx, -1, 1)
              t = (t < 0 and -1 or 1) * math.abs(t) ^ curvature
              nx, ny, nz = t, 0, math.sqrt(math.max(0, 1 - t * t))
            else
              local t = clamp((cy - y) / ry, -1, 1)
              t = (t < 0 and -1 or 1) * math.abs(t) ^ curvature
              nx, ny, nz = 0, t, math.sqrt(math.max(0, 1 - t * t))
            end
          elseif shape == "Contour / Auto Relief" then
            local lx = x - field.left + 1
            local ly = y - field.top + 1
            local maxDistance = math.max(1, field.maximum)
            local function h(dx, dy)
              local value = localDistance(field, lx + dx, ly + dy)
              if value <= 0 then return 0 end
              return (value / maxDistance) ^ curvature
            end
            local gx = (h(1, 0) - h(-1, 0)) * 2.5
            local gy = (h(0, 1) - h(0, -1)) * 2.5
            nx, ny, nz = -gx, gy, 1
          else -- Round / Sphere; geometry is clipped by the alpha silhouette.
            local sx, sy = (x - cx) / rx, (cy - y) / ry
            local radius2 = sx * sx + sy * sy
            if radius2 > 1 then
              local radius = math.sqrt(radius2)
              sx, sy = sx / radius, sy / radius
              nx, ny, nz = sx, sy, 0
            else
              nx, ny, nz = sx, sy, math.sqrt(math.max(0, 1 - radius2))
            end
          end
          setNormal(geometry.normals, index, nx, ny, nz)
        end
      end
    end
  end
  cache.normalEntries[key] = geometry
  cache.normalOrder = cache.normalOrder or {}
  cache.normalOrder[#cache.normalOrder + 1] = key
  if #cache.normalOrder > 8 then
    local expired = table.remove(cache.normalOrder, 1)
    cache.normalEntries[expired] = nil
  end
  return geometry, false
end

function Engine.lightVector(directionX, directionY, elevationDegrees)
  local dx, dy = tonumber(directionX) or -0.6, tonumber(directionY) or -0.4
  local length = math.sqrt(dx * dx + dy * dy)
  if length < 1e-12 then dx, dy, length = -0.6, -0.4, math.sqrt(0.52) end
  dx, dy = dx / length, dy / length
  local elevation = math.rad(clamp(tonumber(elevationDegrees) or 45, 1, 89))
  local planar = math.cos(elevation)
  return dx * planar, dy * planar, math.sin(elevation)
end

function Engine.quantize(intensity, levels, dither, x, y)
  levels = levels == 5 and 5 or 3
  local scaled = clamp(intensity, 0, 1) * (levels - 1)
  local low = math.floor(scaled)
  if low >= levels - 1 then return levels end
  local fraction = scaled - low
  local matrix = BAYER[dither]
  if matrix then
    local size = matrix.size
    local px, py = ((x or 0) % size), ((y or 0) % size)
    local value = matrix.values[py * size + px + 1]
    local threshold = (value + 0.5) / (size * size)
    return (fraction >= threshold) and (low + 2) or (low + 1)
  end
  return (fraction >= 0.5) and (low + 2) or (low + 1)
end

-- Maps color keys to families. Bases win over shades; earlier families win
-- over later ones. With matchShades, every shade of a family (family.allColors
-- or family.colors) also identifies it, so art painted with Palette Trio
-- shadows/highlights is recognized, not only flat base colors.
function Engine.familyIndex(families, matchShades)
  local map, duplicateBases = {}, 0
  for i, family in ipairs(families or {}) do
    local key = rgbKey(family.base)
    if map[key] then duplicateBases = duplicateBases + 1 else map[key] = i end
  end
  if matchShades then
    for i, family in ipairs(families or {}) do
      for _, color in ipairs(family.allColors or family.colors or {}) do
        local key = rgbKey(color)
        if not map[key] then map[key] = i end
      end
    end
  end
  return map, duplicateBases
end

-- Counts which family the opaque pixels belong to. Returns
-- { index, count, matched, opaque, share, counts } where index is the dominant
-- family (nil when no pixel matches any family) and share = count / opaque.
function Engine.detectFamily(pixels, families, excludedColors)
  local map = Engine.familyIndex(families, true)
  local excluded = {}
  for _, color in ipairs(excludedColors or {}) do excluded[rgbKey(color)] = true end
  local counts, matched, opaque = {}, 0, 0
  for _, p in ipairs(pixels) do
    if (p.a or 0) > 0 then
      local key = rgbKey(p)
      if not excluded[key] then
        opaque = opaque + 1
        local i = map[key]
        if i then counts[i] = (counts[i] or 0) + 1; matched = matched + 1 end
      end
    end
  end
  local best, bestCount = nil, 0
  for i, count in pairs(counts) do
    if count > bestCount or (count == bestCount and best and i < best) then best, bestCount = i, count end
  end
  return {
    index = best, count = bestCount, matched = matched, opaque = opaque,
    share = opaque > 0 and bestCount / opaque or 0, counts = counts,
  }
end

-- Resolves one color to a family: exact match against any family color, or,
-- when `toLab` is given, a nearest match that is only accepted when it is
-- clearly closer to one family than to any other (reliable).
-- Returns index, "exact"|"near"|nil, distance.
function Engine.resolveColor(color, families, toLab, maxDistance)
  local map = Engine.familyIndex(families, true)
  local exact = map[rgbKey(color)]
  if exact then return exact, "exact", 0 end
  if not toLab then return nil end
  maxDistance = maxDistance or 0.035
  local lab = toLab(color)
  local bestByFamily = {}
  for i, family in ipairs(families or {}) do
    for _, c in ipairs(family.allColors or family.colors or {}) do
      local other = toLab(c)
      local d = math.sqrt((lab.L - other.L) ^ 2 + (lab.a - other.a) ^ 2 + (lab.b - other.b) ^ 2)
      if not bestByFamily[i] or d < bestByFamily[i] then bestByFamily[i] = d end
    end
  end
  local first, firstD, secondD = nil, math.huge, math.huge
  for i, d in pairs(bestByFamily) do
    if d < firstD then first, secondD, firstD = i, firstD, d
    elseif d < secondD then secondD = d end
  end
  if first and firstD <= maxDistance and secondD >= firstD * 1.6 then return first, "near", firstD end
  return nil, nil, firstD
end

-- options.matchShades: shade colors identify their family (see familyIndex).
-- options.fallbackFamily: index of the family used for opaque pixels that
-- match no family (an explicit artist choice); nil leaves them unchanged.
function Engine.render(pixels, width, height, families, geometry, options)
  options = options or {}
  local levels = options.levels == 5 and 5 or 3
  local lightX, lightY, lightZ = Engine.lightVector(options.directionX, options.directionY, options.elevation)
  local contrast = clamp(tonumber(options.strength) or 1, 0, 2)
  local offsetX, offsetY = tonumber(options.offsetX) or 0, tonumber(options.offsetY) or 0
  local excluded = {}
  for _, color in ipairs(options.excludedColors or {}) do excluded[rgbKey(color)] = true end
  local map, duplicateBases = Engine.familyIndex(families, options.matchShades)
  local fallback = options.fallbackFamily and families[options.fallbackFamily] or nil
  local output = {}
  local stats = { shaded = 0, unchanged = 0, unknown = 0, excluded = 0, outlines = 0, duplicateBases = duplicateBases }
  for y = 1, height do
    for x = 1, width do
      local index = (y - 1) * width + x
      local source = pixels[index]
      local alpha = source and (source.a or 0) or 0
      local original = { r = source.r, g = source.g, b = source.b, a = alpha }
      local family = nil
      if alpha > 0 then
        local i = map[rgbKey(source)]
        family = i and families[i] or fallback
      end
      if not family then
        output[index] = original
        stats.unchanged = stats.unchanged + 1
        if alpha > 0 then stats.unknown = stats.unknown + 1 end
      elseif excluded[rgbKey(source)] then
        output[index] = original
        stats.excluded = stats.excluded + 1
      elseif options.preserveOutlines and geometry.outline[index] then
        output[index] = original
        stats.outlines = stats.outlines + 1
      else
        local nx = geometry.normals.x[index] or 0
        local ny = geometry.normals.y[index] or 0
        local nz = geometry.normals.z[index] or 1
        local dot = math.max(0, nx * lightX + ny * lightY + nz * lightZ)
        local diffuse = 0.18 + 0.82 * dot
        local intensity = clamp(0.5 + (diffuse - 0.5) * contrast, 0, 1)
        local paletteIndex = Engine.quantize(intensity, levels, options.dither, x - 1 + offsetX, y - 1 + offsetY)
        local selected = family.colors[paletteIndex]
        if selected then
          output[index] = { r = selected.r, g = selected.g, b = selected.b, a = alpha }
          stats.shaded = stats.shaded + 1
        else
          output[index] = original
          stats.unchanged = stats.unchanged + 1
        end
      end
    end
  end
  return output, stats
end

Engine.rgbKey = rgbKey
return Engine
