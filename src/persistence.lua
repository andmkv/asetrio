local Persistence = {}

-- Returns model, status where status is one of:
--   "none"     nothing stored (or no sprite)
--   "ok"       stored families loaded (v1 data is migrated in memory)
--   "invalid"  stored data exists but is unreadable or from a newer version
--   "error"    the property could not be read
function Persistence.load(sprite, namespace, modelModule, colorOps)
  if not sprite then return modelModule.new(colorOps), "none" end
  local ok, stored = pcall(function()
    return sprite.properties(namespace).paletteTrio
  end)
  if not ok then return modelModule.new(colorOps), "error", tostring(stored) end
  if stored == nil then return modelModule.new(colorOps), "none" end
  local model, valid = modelModule.fromTable(colorOps, stored)
  if not valid then
    local version = type(stored) == "table" and stored.version or nil
    return model, "invalid", version and ("Stored Palette Trio data has unsupported version " .. tostring(version) .. ".")
      or "Stored Palette Trio data is unreadable."
  end
  return model, "ok"
end

-- Returns true, or false plus a human-readable reason.
function Persistence.save(sprite, namespace, paletteModel)
  if not sprite then return false, "No sprite is open." end
  local ok, reason = pcall(function()
    sprite.properties(namespace).paletteTrio = paletteModel.toTable(paletteModel)
  end)
  if not ok then return false, tostring(reason) end
  return true
end

-- Formats that cannot carry extension properties. Families stored in a sprite
-- saved only as one of these are lost when the file is reopened.
local FLAT_FORMATS = {
  png = true, gif = true, jpg = true, jpeg = true, bmp = true, tga = true,
  pcx = true, webp = true, ico = true, flc = true, fli = true, qoi = true, svg = true,
}

function Persistence.storesProperties(filename)
  if type(filename) ~= "string" or filename == "" then return true end
  local ext = filename:match("%.([%w]+)$")
  if not ext then return true end
  return not FLAT_FORMATS[ext:lower()]
end

return Persistence
