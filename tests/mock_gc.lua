-- Mock GraphicsContext that paints into an Image, so custom canvases can be
-- rendered headlessly. Text is drawn as placeholder dots. Shared by
-- tests/render_preview.lua and tests/render_light.lua.
local MockGc = {}

function MockGc.new(scale)
  local SCALE = scale or 2
local GLYPH_W, GLYPH_H = 5, 8

local function mockGc(width, height)
  local image = Image(width * SCALE, height * SCALE, ColorMode.RGB)
  image:clear(app.pixelColor.rgba(48, 48, 52, 255))
  local gc = { width = width, height = height, color = Color { r = 255, g = 255, b = 255 }, strokeWidth = 1 }
  local clip = nil
  local stack = {}
  local path = {}
  local function plot(x, y, c)
    if clip and (x < clip.x or y < clip.y or x >= clip.x + clip.width or y >= clip.y + clip.height) then return end
    if x < 0 or y < 0 or x >= width or y >= height then return end
    local a = c.alpha / 255
    for dy = 0, SCALE - 1 do
      for dx = 0, SCALE - 1 do
        local px, py = x * SCALE + dx, y * SCALE + dy
        local old = image:getPixel(px, py)
        local pc = app.pixelColor
        local r = math.floor(pc.rgbaR(old) * (1 - a) + c.red * a + 0.5)
        local g = math.floor(pc.rgbaG(old) * (1 - a) + c.green * a + 0.5)
        local b = math.floor(pc.rgbaB(old) * (1 - a) + c.blue * a + 0.5)
        image:drawPixel(px, py, pc.rgba(r, g, b, 255))
      end
    end
  end
  function gc:fillRect(r)
    for y = math.floor(r.y), math.floor(r.y + r.height) - 1 do
      for x = math.floor(r.x), math.floor(r.x + r.width) - 1 do plot(x, y, self.color) end
    end
  end
  function gc:strokeRect(r)
    local x0, y0 = math.floor(r.x), math.floor(r.y)
    local x1, y1 = math.floor(r.x + r.width) - 1, math.floor(r.y + r.height) - 1
    for x = x0, x1 do plot(x, y0, self.color); plot(x, y1, self.color) end
    for y = y0, y1 do plot(x0, y, self.color); plot(x1, y, self.color) end
  end
  function gc:measureText(text) return { width = #text * GLYPH_W, height = GLYPH_H } end
  function gc:fillText(text, x, y)
    -- Text is approximated by a dotted baseline block per glyph.
    for i = 1, #text do
      if text:sub(i, i) ~= " " then
        for gy = 1, GLYPH_H - 2, 2 do plot(x + (i - 1) * GLYPH_W + 1, y + gy, self.color); plot(x + (i - 1) * GLYPH_W + 3, y + gy, self.color) end
      end
    end
  end
  -- Nearest-neighbour scaled copy of an Image into the target rectangle.
  function gc:drawImage(source, sx, sy, sw, sh, dx, dy, dw, dh)
    if not dw then return end
    for y = 0, math.max(0, math.ceil(dh) - 1) do
      for x = 0, math.max(0, math.ceil(dw) - 1) do
        local ix, iy = sx + math.floor(x * sw / dw), sy + math.floor(y * sh / dh)
        if ix >= 0 and iy >= 0 and ix < source.width and iy < source.height then
          local value = source:getPixel(ix, iy)
          local pc = app.pixelColor
          if pc.rgbaA(value) > 0 then
            plot(math.floor(dx) + x, math.floor(dy) + y,
              Color { r = pc.rgbaR(value), g = pc.rgbaG(value), b = pc.rgbaB(value), a = pc.rgbaA(value) })
          end
        end
      end
    end
  end
  function gc:beginPath() path = {} end
  function gc:moveTo(x, y) path[#path + 1] = { x, y } end
  function gc:lineTo(x, y) path[#path + 1] = { x, y } end
  function gc:closePath() end
  function gc:rect(r) path = { rect = r } end
  function gc:clip() if path.rect then clip = path.rect end end
  function gc:save() stack[#stack + 1] = clip end
  function gc:restore() clip = table.remove(stack) end
  function gc:fill()
    if #path < 3 then return end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(path) do
      minX, maxX = math.min(minX, p[1]), math.max(maxX, p[1])
      minY, maxY = math.min(minY, p[2]), math.max(maxY, p[2])
    end
    local function sign(p1, p2, x, y) return (x - p2[1]) * (p1[2] - p2[2]) - (p1[1] - p2[1]) * (y - p2[2]) end
    for y = math.floor(minY), math.ceil(maxY) - 1 do
      for x = math.floor(minX), math.ceil(maxX) - 1 do
        local px, py = x + 0.5, y + 0.5
        local d1, d2, d3 = sign(path[1], path[2], px, py), sign(path[2], path[3], px, py), sign(path[3], path[1], px, py)
        local neg = d1 < 0 or d2 < 0 or d3 < 0
        local pos = d1 > 0 or d2 > 0 or d3 > 0
        if not (neg and pos) then plot(x, y, self.color) end
      end
    end
  end
  function gc:stroke() end
  return gc, image
end


  return mockGc
end

return MockGc
