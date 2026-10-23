local Color = {}

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function srgbToLinear(value)
  if value <= 0.04045 then return value / 12.92 end
  return ((value + 0.055) / 1.055) ^ 2.4
end

local function linearToSrgb(value)
  if value <= 0.0031308 then return value * 12.92 end
  return 1.055 * (value ^ (1 / 2.4)) - 0.055
end

local atan2 = math.atan2 or function(y, x)
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi * 0.5 end
  if x == 0 and y < 0 then return -math.pi * 0.5 end
  return 0
end

function Color.rgbToOklab(rgb)
  local r = srgbToLinear(clamp((rgb.r or 0) / 255, 0, 1))
  local g = srgbToLinear(clamp((rgb.g or 0) / 255, 0, 1))
  local b = srgbToLinear(clamp((rgb.b or 0) / 255, 0, 1))

  local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

  l, m, s = l ^ (1 / 3), m ^ (1 / 3), s ^ (1 / 3)
  return {
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  }
end

function Color.oklabToLinearRgb(lab)
  local l = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
  local m = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
  local s = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b
  l, m, s = l * l * l, m * m * m, s * s * s
  return {
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  }
end

function Color.oklabToRgb(lab)
  local linear = Color.oklabToLinearRgb(lab)
  return {
    r = clamp(linearToSrgb(linear.r), 0, 1) * 255,
    g = clamp(linearToSrgb(linear.g), 0, 1) * 255,
    b = clamp(linearToSrgb(linear.b), 0, 1) * 255,
  }
end

function Color.rgbToOklch(rgb)
  local lab = Color.rgbToOklab(rgb)
  local chroma = math.sqrt(lab.a * lab.a + lab.b * lab.b)
  local hue = 0
  if chroma > 1e-9 then
    hue = math.deg(atan2(lab.b, lab.a)) % 360
  end
  return { L = lab.L, C = chroma, h = hue }
end

local function inGamut(rgb)
  return rgb.r >= 0 and rgb.r <= 1
    and rgb.g >= 0 and rgb.g <= 1
    and rgb.b >= 0 and rgb.b <= 1
end

local function oklchLinearRgb(L, C, hue)
  local angle = math.rad(hue)
  return Color.oklabToLinearRgb({
    L = L,
    a = C * math.cos(angle),
    b = C * math.sin(angle),
  })
end

function Color.oklchToRgb(lch, gamutMap)
  local L = clamp(lch.L or 0, 0, 1)
  local C = math.max(0, lch.C or 0)
  local hue = (lch.h or 0) % 360
  local linear = oklchLinearRgb(L, C, hue)

  if gamutMap ~= false and not inGamut(linear) then
    local low, high = 0, C
    for _ = 1, 32 do
      local mid = (low + high) * 0.5
      if inGamut(oklchLinearRgb(L, mid, hue)) then
        low = mid
      else
        high = mid
      end
    end
    C = low
    linear = oklchLinearRgb(L, C, hue)
  end

  return {
    r = math.floor(clamp(linearToSrgb(clamp(linear.r, 0, 1)), 0, 1) * 255 + 0.5),
    g = math.floor(clamp(linearToSrgb(clamp(linear.g, 0, 1)), 0, 1) * 255 + 0.5),
    b = math.floor(clamp(linearToSrgb(clamp(linear.b, 0, 1)), 0, 1) * 255 + 0.5),
  }
end

function Color.shade(base, targetLightness, hueShift)
  local lch = Color.rgbToOklch(base)
  lch.L = clamp(targetLightness, 0, 1)
  if lch.C > 0.004 then
    lch.h = (lch.h + (hueShift or 0)) % 360
  end
  return Color.oklchToRgb(lch, true)
end

function Color.copy(rgb)
  return { r = rgb.r, g = rgb.g, b = rgb.b }
end

function Color.validRgb(rgb)
  return type(rgb) == "table"
    and type(rgb.r) == "number" and rgb.r >= 0 and rgb.r <= 255
    and type(rgb.g) == "number" and rgb.g >= 0 and rgb.g <= 255
    and type(rgb.b) == "number" and rgb.b >= 0 and rgb.b <= 255
end

return Color
