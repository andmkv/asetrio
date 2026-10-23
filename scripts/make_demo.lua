-- Generates the README demo images with the real Palette Trio shade
-- generation and the real Light engine, run inside Aseprite:
--   aseprite -b --script-param out=docs/images --script scripts/make_demo.lua
-- It draws flat objects, shades them exactly as Light does (3 shades), and
-- writes docs/images/light-flat-vs-shaded.png and light-demo.gif.
local sourcePath = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = sourcePath:match("^(.*)/scripts/[^/]+$") or "."
local function load(path) return dofile(root .. "/" .. path) end
local outDir = app.params.out or app.fs.joinPath(root, "docs/images")
app.fs.makeAllDirectories(outDir)

local Color_, Model, Engine = load("src/color.lua"), load("src/model.lua"), load("src/light_engine.lua")
local pc = app.pixelColor

-- Three base colors; their shadow/light shades come from Palette Trio itself.
local model = Model.new(Color_)
local ORANGE = model.newRow(model, { r = 224, g = 122, b = 54 })
local BLUE = model.newRow(model, { r = 70, g = 112, b = 200 })
local GREEN = model.newRow(model, { r = 84, g = 168, b = 96 })
local families = model.shadeFamilies(model, 3)
local OUTLINE = { r = 38, g = 24, b = 48 }

local SIZE, SCALE = 40, 5

local function newPixels() local t = {}; for i = 1, SIZE * SIZE do t[i] = { r = 0, g = 0, b = 0, a = 0 } end; return t end
local function put(px, x, y, c) if x >= 1 and x <= SIZE and y >= 1 and y <= SIZE then px[(y - 1) * SIZE + x] = { r = c.r, g = c.g, b = c.b, a = 255 } end end

-- Draws a filled shape with a 1px outline: inside(x, y) decides membership.
local function draw(inside, fill)
  local px = newPixels()
  for y = 1, SIZE do for x = 1, SIZE do
    if inside(x, y) then
      local edge = not (inside(x - 1, y) and inside(x + 1, y) and inside(x, y - 1) and inside(x, y + 1))
      put(px, x, y, edge and OUTLINE or fill)
    end
  end end
  return px
end

local objects = {
  { name = "sphere", params = { shape = "Round / Sphere" }, fill = ORANGE.base,
    pixels = draw(function(x, y) return (x - 20.5) ^ 2 + (y - 20.5) ^ 2 <= 17 ^ 2 end, ORANGE.base) },
  { name = "box", params = { shape = "Box / Beveled rectangle", bevel = 5 }, fill = BLUE.base,
    pixels = draw(function(x, y) return x >= 5 and x <= 36 and y >= 8 and y <= 33 end, BLUE.base) },
  { name = "cylinder", params = { shape = "Cylinder", cylinderAxis = "Horizontal", curvature = 1 }, fill = GREEN.base,
    pixels = draw(function(x, y) return x >= 3 and x <= 38 and y >= 10 and y <= 31 end, GREEN.base) },
}

local function shade(object, dirX, dirY)
  local mask, key = Engine.extractSilhouette(object.pixels, SIZE, SIZE)
  local geometry = Engine.buildGeometry(mask, SIZE, SIZE, object.params, {}, key)
  local len = math.sqrt(dirX * dirX + dirY * dirY)
  local output = Engine.render(object.pixels, SIZE, SIZE, families, geometry, {
    levels = 3, directionX = dirX / len, directionY = dirY / len, elevation = 38, strength = 1.15,
    matchShades = true,
  })
  return output
end

local BG = { r = 52, g = 50, b = 62 }
-- Composes the objects (flat or shaded pixel tables) into one scaled image.
local function compose(pixelSets, cols, gap)
  local rows = math.ceil(#pixelSets / cols)
  local w = (cols * SIZE + (cols + 1) * gap) * SCALE
  local h = (rows * SIZE + (rows + 1) * gap) * SCALE
  local image = Image(w, h, ColorMode.RGB)
  image:clear(pc.rgba(BG.r, BG.g, BG.b, 255))
  for index, px in ipairs(pixelSets) do
    local col, row = (index - 1) % cols, (index - 1) // cols
    local ox = (gap + col * (SIZE + gap)) * SCALE
    local oy = (gap + row * (SIZE + gap)) * SCALE
    for y = 0, SIZE - 1 do for x = 0, SIZE - 1 do
      local p = px[y * SIZE + x + 1]
      if p.a > 0 then
        local value = pc.rgba(p.r, p.g, p.b, 255)
        for dy = 0, SCALE - 1 do for dx = 0, SCALE - 1 do image:drawPixel(ox + x * SCALE + dx, oy + y * SCALE + dy, value) end end
      end
    end end
  end
  return image
end

local function flatSets() local t = {}; for i, o in ipairs(objects) do t[i] = o.pixels end; return t end
local function shadedSets(dx, dy) local t = {}; for i, o in ipairs(objects) do t[i] = shade(o, dx, dy) end; return t end

-- 1. Flat (top row) vs shaded (bottom row), same canvas.
do
  local sets = flatSets()
  for _, px in ipairs(shadedSets(-0.7, 0.7)) do sets[#sets + 1] = px end
  local image = compose(sets, 3, 4)
  local sprite = Sprite(image.width, image.height, ColorMode.RGB)
  sprite.cels[1].image = image
  sprite:saveAs(app.fs.joinPath(outDir, "light-flat-vs-shaded.png"))
end

-- 2. GIF: flat, then the light orbits the objects.
do
  local frames = { compose(flatSets(), 3, 4), compose(flatSets(), 3, 4) }
  local steps = 24
  for i = 0, steps - 1 do
    local angle = math.rad(135 + i * 360 / steps)
    frames[#frames + 1] = compose(shadedSets(math.cos(angle), math.sin(angle)), 3, 4)
  end
  local sprite = Sprite(frames[1].width, frames[1].height, ColorMode.RGB)
  for i = 2, #frames do sprite:newEmptyFrame() end
  local layer = sprite.layers[1]
  for i, image in ipairs(frames) do
    sprite:newCel(layer, i, image, Point(0, 0))
    sprite.frames[i].duration = (i <= 2) and 0.5 or 0.09
  end
  sprite:saveAs(app.fs.joinPath(outDir, "light-demo.gif"))
end
print("demo images written to " .. outDir)
