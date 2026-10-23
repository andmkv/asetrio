local Model = {}

Model.SCHEMA_VERSION = 2
Model.SOURCE_KINDS = { palette = true, artwork = true, manual = true, file = true, legacy = true }
Model.DEFAULTS = {
  shadeCount = 3,
  settings = {
    shadowStrength = 0.30,
    highlightStrength = 0.25,
    shadowHueShift = 10,
    highlightHueShift = 10,
    coolShadows = true,
    warmHighlights = true,
  },
}

local SLOT_ORDER = {
  { key = "deepShadow", label = "Deep Shadow" },
  { key = "shadow", label = "Shadow" },
  { key = "base", label = "Base" },
  { key = "highlight", label = "Light" },
  { key = "brightHighlight", label = "Bright" },
}

local function copyMap(source)
  local result = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      if type(value) == "table" then
        result[key] = copyMap(value)
      else
        result[key] = value
      end
    end
  end
  return result
end

local function validColor(color, colorOps)
  if not colorOps.validRgb(color) then return nil end
  return {
    r = math.floor(color.r + 0.5),
    g = math.floor(color.g + 0.5),
    b = math.floor(color.b + 0.5),
  }
end

local function normalizeSettings(input)
  local settings = copyMap(Model.DEFAULTS.settings)
  if type(input) ~= "table" then return settings end
  local function boundedNumber(name, minValue, maxValue)
    local value = tonumber(input[name])
    if value then
      settings[name] = math.max(minValue, math.min(maxValue, value))
    end
  end
  boundedNumber("shadowStrength", 0, 1)
  boundedNumber("highlightStrength", 0, 1)
  boundedNumber("shadowHueShift", -90, 90)
  boundedNumber("highlightHueShift", -90, 90)
  if type(input.coolShadows) == "boolean" then settings.coolShadows = input.coolShadows end
  if type(input.warmHighlights) == "boolean" then settings.warmHighlights = input.warmHighlights end
  return settings
end

local function newShade()
  return {
    color = { r = 0, g = 0, b = 0 },
    manualColor = nil,
    override = false,
    locked = false,
  }
end

local function colorKey(rgb)
  return string.format("%d,%d,%d", rgb.r, rgb.g, rgb.b)
end
Model.colorKey = colorKey

local function makeRow(id, base, name)
  return {
    id = id,
    name = type(name) == "string" and name or "",
    base = base,
    link = nil,
    baseEdited = false,
    missing = false,
    shades = {
      deepShadow = newShade(),
      shadow = newShade(),
      highlight = newShade(),
      brightHighlight = newShade(),
    },
  }
end

function Model.new(colorOps)
  assert(colorOps, "color operations are required")
  local self = {
    version = Model.SCHEMA_VERSION,
    shadeCount = Model.DEFAULTS.shadeCount,
    settings = copyMap(Model.DEFAULTS.settings),
    rows = {},
    nextId = 1,
    source = { kind = "manual", label = "" },
    -- Native palette colors the artist deliberately excluded (color keys).
    ignored = {},
    -- Colors Palette Trio itself wrote into the native palette as shades
    -- (provenance), so they are not mistaken for authored base colors.
    generated = {},
    -- True once the artist reorders families; otherwise palette order is kept.
    manualOrder = false,
  }
  self._color = colorOps
  return setmetatable(self, { __index = Model })
end

function Model.visibleSlots(shadeCount)
  if shadeCount == 5 then return copyMap(SLOT_ORDER) end
  return {
    { key = "shadow", label = "Shadow" },
    { key = "base", label = "Base" },
    { key = "highlight", label = "Light" },
  }
end

function Model.newRow(self, base, name, link)
  local rgb = validColor(base, self._color) or { r = 128, g = 128, b = 128 }
  local row = makeRow(self.nextId, rgb, name)
  if type(link) == "table" then
    row.link = { color = self._color.copy(rgb), index = tonumber(link.index) }
  end
  self.nextId = self.nextId + 1
  self.rows[#self.rows + 1] = row
  self.regenerate(self, row)
  return row
end

function Model.removeRow(self, index)
  if index < 1 or index > #self.rows then return false end
  local row = table.remove(self.rows, index)
  -- A removed source color must not come back on the next sync.
  if row.link then self.ignored[colorKey(row.link.color)] = true end
  return true
end

function Model.setIgnored(self, keys)
  self.ignored = {}
  for _, key in ipairs(keys or {}) do self.ignored[key] = true end
end

function Model.moveRow(self, index, delta)
  local target = index + delta
  if index < 1 or index > #self.rows or target < 1 or target > #self.rows then return false end
  self.rows[index], self.rows[target] = self.rows[target], self.rows[index]
  self.manualOrder = true
  return true
end

-- Keeps families in native palette order (unless the artist reordered them).
-- Families without a palette link (custom colors) follow in their own order.
function Model.sortByLink(self)
  if self.manualOrder then return end
  local decorated = {}
  for i, row in ipairs(self.rows) do decorated[i] = { row = row, pos = i } end
  table.sort(decorated, function(a, b)
    local ai = a.row.link and a.row.link.index
    local bi = b.row.link and b.row.link.index
    if ai and bi and ai ~= bi then return ai < bi end
    if (ai ~= nil) ~= (bi ~= nil) then return ai ~= nil end
    return a.pos < b.pos
  end)
  for i, item in ipairs(decorated) do self.rows[i] = item.row end
end

-- Adds a custom (non-palette) family. Returns nil if the color is already a base.
function Model.addCustom(self, rgb)
  local color = validColor(rgb, self._color)
  if not color then return nil end
  for _, row in ipairs(self.rows) do
    if colorKey(row.base) == colorKey(color) then return nil end
  end
  return self.newRow(self, color, "")
end

-- Records shade colors Palette Trio wrote into the native palette.
function Model.recordGenerated(self, colors)
  local bases = {}
  for _, row in ipairs(self.rows) do bases[colorKey(row.base)] = true end
  for _, color in ipairs(colors) do
    local key = colorKey(color)
    if not bases[key] then self.generated[key] = true end
  end
end

function Model.countMissing(self)
  local count = 0
  for _, row in ipairs(self.rows) do if row.missing then count = count + 1 end end
  return count
end

function Model.setShadeCount(self, count)
  if count ~= 3 and count ~= 5 then return false end
  self.shadeCount = count
  return true
end

local function generateShade(self, row, key)
  local shade = row.shades[key]
  if shade.locked then return end
  local settings = self.settings
  local lightness = self._color.rgbToOklch(row.base).L
  local shadowHue = settings.coolShadows and -settings.shadowHueShift or 0
  local highlightHue = settings.warmHighlights and settings.highlightHueShift or 0
  local definitions = {
    { key = "deepShadow", target = lightness * (1 - math.min(1, settings.shadowStrength * 1.65)), hue = shadowHue * 1.5 },
    { key = "shadow", target = lightness * (1 - settings.shadowStrength), hue = shadowHue },
    { key = "highlight", target = lightness + (1 - lightness) * settings.highlightStrength, hue = highlightHue },
    { key = "brightHighlight", target = lightness + (1 - lightness) * math.min(1, settings.highlightStrength * 1.65), hue = highlightHue * 1.5 },
  }
  for _, definition in ipairs(definitions) do
    if definition.key == key then
      shade.color = self._color.shade(row.base, definition.target, definition.hue)
      return
    end
  end
end

function Model.regenerate(self, row)
  if not row then
    for _, item in ipairs(self.rows) do self.regenerate(self, item) end
    return
  end
  for _, slot in ipairs(SLOT_ORDER) do
    if slot.key ~= "base" then generateShade(self, row, slot.key) end
  end
end

-- Changes a family's base color from inside Palette Trio. Linked families
-- remember the edit so a later source sync does not overwrite it.
function Model.setBase(self, rowIndex, rgb)
  local row = self.rows[rowIndex]
  local color = validColor(rgb, self._color)
  if not row or not color then return false end
  row.base = color
  if row.link then row.baseEdited = colorKey(row.link.color) ~= colorKey(color) end
  self.regenerate(self, row)
  return true
end

function Model.editShade(self, rowIndex, key, rgb)
  local row = self.rows[rowIndex]
  local shade = row and row.shades[key]
  local color = validColor(rgb, self._color)
  if not shade or not color then return false end
  shade.color = self._color.copy(color)
  shade.manualColor = self._color.copy(color)
  shade.override = true
  -- A manual edit is pinned so base or settings changes never discard it.
  shade.locked = true
  return true
end

function Model.setLocked(self, rowIndex, key, value)
  local row = self.rows[rowIndex]
  local shade = row and row.shades[key]
  if not shade or type(value) ~= "boolean" then return false end
  shade.locked = value
  if not value then
    -- Unpinning returns the shade to automatic generation.
    shade.override = false
    self.regenerate(self, row)
  end
  return true
end

function Model.resetShade(self, rowIndex, key)
  local row = self.rows[rowIndex]
  local shade = row and row.shades[key]
  if not shade then return false end
  shade.override = false
  shade.manualColor = nil
  shade.locked = false
  self.regenerate(self, row)
  return true
end

function Model.setName(self, rowIndex, name)
  local row = self.rows[rowIndex]
  if not row or type(name) ~= "string" then return false end
  row.name = name:sub(1, 48)
  return true
end

function Model.setSettings(self, changes)
  self.settings = normalizeSettings(changes)
  self.regenerate(self)
end

function Model.replaceRows(self, colors)
  self.rows = {}
  self.nextId = 1
  for _, color in ipairs(colors) do
    self.newRow(self, color, "")
  end
end

function Model.setSource(self, kind, label)
  self.source = {
    kind = Model.SOURCE_KINDS[kind] and kind or "manual",
    label = type(label) == "string" and label or "",
  }
end

function Model.hasUserEdits(row)
  if row.name ~= "" or row.baseEdited then return true end
  for _, shade in pairs(row.shades) do
    if shade.override or shade.locked then return true end
  end
  return false
end

-- Colors that are generated (non-base) shades of the current families. Used so
-- shades the artist painted with are not mistaken for new base colors.
function Model.derivedColorKeys(self)
  local keys = {}
  for _, row in ipairs(self.rows) do
    for key, shade in pairs(row.shades) do
      keys[colorKey(shade.color)] = key
    end
  end
  for _, row in ipairs(self.rows) do keys[colorKey(row.base)] = nil end
  return keys
end

-- Generated shades of an arbitrary color with the current settings, without
-- adding a row. Returned as a set of color keys.
function Model.shadeKeysFor(self, base)
  local probe = makeRow(0, validColor(base, self._color), "")
  self.regenerate(self, probe)
  local keys = {}
  for _, shade in pairs(probe.shades) do keys[colorKey(shade.color)] = true end
  keys[colorKey(probe.base)] = nil
  return keys
end

-- Non-destructive merge of source entries ({ color, index }) into the families.
-- Row identity, names, order, pins, and in-Trio base edits are preserved.
-- Families whose source color disappeared are kept and flagged as missing.
function Model.syncSource(self, entries)
  local report = { added = 0, updated = 0, kept = 0, missing = 0, missingRows = {} }
  local byKey, byIndex, used = {}, {}, {}
  for position, entry in ipairs(entries) do
    local key = colorKey(entry.color)
    if not byKey[key] then byKey[key] = position end
    if entry.index ~= nil and byIndex[entry.index] == nil then byIndex[entry.index] = position end
  end
  local unmatched = {}
  -- 1. Rows whose remembered source color still exists.
  for _, row in ipairs(self.rows) do
    local position = row.link and byKey[colorKey(row.link.color)]
    if position and not used[position] then
      used[position] = true
      row.link.index = entries[position].index
      row.missing = false
      report.kept = report.kept + 1
    else
      unmatched[#unmatched + 1] = row
    end
  end
  -- 2. Linked rows whose palette slot now holds a new color: follow the slot.
  local stillUnmatched = {}
  for _, row in ipairs(unmatched) do
    local position = row.link and row.link.index ~= nil and byIndex[row.link.index]
    if position and not used[position] and not byKey[colorKey(row.base)] then
      used[position] = true
      local color = self._color.copy(entries[position].color)
      row.link.color = color
      row.missing = false
      if not row.baseEdited then
        row.base = self._color.copy(color)
        self.regenerate(self, row)
      end
      report.updated = report.updated + 1
    else
      stillUnmatched[#stillUnmatched + 1] = row
    end
  end
  -- 3. Rows whose current base matches an unused entry adopt that entry.
  for _, row in ipairs(stillUnmatched) do
    local position = byKey[colorKey(row.base)]
    if position and not used[position] then
      used[position] = true
      row.link = { color = self._color.copy(entries[position].color), index = entries[position].index }
      row.missing = false
      report.kept = report.kept + 1
    elseif row.link then
      row.missing = true
      report.missing = report.missing + 1
      report.missingRows[#report.missingRows + 1] = row
    end
  end
  -- 4. New source colors become new families, in source order.
  for position, entry in ipairs(entries) do
    local key = colorKey(entry.color)
    if not used[position] and byKey[key] == position and self.ignored[key] then
      report.ignored = (report.ignored or 0) + 1
    elseif not used[position] and byKey[key] == position then
      self.newRow(self, entry.color, "", { index = entry.index })
      report.added = report.added + 1
    end
  end
  return report
end

-- Makes the families exactly match a chosen color list while keeping existing
-- rows (and their edits) whose base or source color is chosen again.
-- Returns the rows that would be removed when dryRun is true.
function Model.chooseColors(self, entries, dryRun)
  local wanted, order = {}, {}
  for _, entry in ipairs(entries) do
    local key = colorKey(entry.color)
    if not wanted[key] then wanted[key] = entry; order[#order + 1] = key end
  end
  local keptByKey, removed = {}, {}
  for _, row in ipairs(self.rows) do
    local key = colorKey(row.base)
    local linkKey = row.link and colorKey(row.link.color)
    local match = (wanted[key] and key) or (linkKey and wanted[linkKey] and linkKey)
    if match and not keptByKey[match] then
      keptByKey[match] = row
    else
      removed[#removed + 1] = row
    end
  end
  if dryRun then return removed end
  for _, key in ipairs(order) do self.ignored[key] = nil end
  local rows = {}
  for _, key in ipairs(order) do
    local row = keptByKey[key]
    local entry = wanted[key]
    if row then
      if not row.link then row.link = { color = self._color.copy(entry.color), index = entry.index } end
      row.missing = false
      rows[#rows + 1] = row
    else
      row = makeRow(self.nextId, validColor(entry.color, self._color), "")
      row.link = { color = self._color.copy(row.base), index = entry.index }
      self.nextId = self.nextId + 1
      self.regenerate(self, row)
      rows[#rows + 1] = row
    end
  end
  self.rows = rows
  return removed
end

function Model.colorsForRow(self, row)
  local output = {}
  local keys
  if self.shadeCount == 5 then
    keys = { "deepShadow", "shadow", "base", "highlight", "brightHighlight" }
  else
    keys = { "shadow", "base", "highlight" }
  end
  for _, key in ipairs(keys) do
    if key == "base" then
      output[#output + 1] = self._color.copy(row.base)
    else
      output[#output + 1] = self._color.copy(row.shades[key].color)
    end
  end
  return output
end

-- Stable read-only interface for consumers such as Palette Trio Light.
-- This does not change the palette manager's active shade-count setting.
function Model.shadeFamilies(self, count)
  count = count == 5 and 5 or (count == 3 and 3 or self.shadeCount)
  local families = {}
  local keys = count == 5
    and { "deepShadow", "shadow", "base", "highlight", "brightHighlight" }
    or { "shadow", "base", "highlight" }
  for _, row in ipairs(self.rows) do
    local colors = {}
    for _, key in ipairs(keys) do
      colors[#colors + 1] = key == "base"
        and self._color.copy(row.base)
        or self._color.copy(row.shades[key].color)
    end
    local all = {}
    for _, key in ipairs({ "deepShadow", "shadow", "base", "highlight", "brightHighlight" }) do
      all[#all + 1] = key == "base" and self._color.copy(row.base) or self._color.copy(row.shades[key].color)
    end
    families[#families + 1] = {
      rowId = row.id,
      name = row.name,
      base = self._color.copy(row.base),
      colors = colors,
      allColors = all,
    }
  end
  return families
end

function Model.allColors(self)
  local output = {}
  for _, row in ipairs(self.rows) do
    for _, color in ipairs(self.colorsForRow(self, row)) do
      output[#output + 1] = color
    end
  end
  return output
end

function Model.toTable(self)
  local output = {
    version = Model.SCHEMA_VERSION,
    shadeCount = self.shadeCount,
    nextId = self.nextId,
    settings = copyMap(self.settings),
    source = { kind = self.source.kind, label = self.source.label },
    ignored = {},
    generated = {},
    manualOrder = self.manualOrder or nil,
    rows = {},
  }
  for key in pairs(self.ignored) do output.ignored[#output.ignored + 1] = key end
  table.sort(output.ignored)
  for key in pairs(self.generated) do output.generated[#output.generated + 1] = key end
  table.sort(output.generated)
  for i, row in ipairs(self.rows) do
    local copy = { id = row.id, name = row.name, base = self._color.copy(row.base), shades = {} }
    if row.link then
      copy.link = { color = self._color.copy(row.link.color), index = row.link.index }
    end
    copy.baseEdited = row.baseEdited or nil
    copy.missing = row.missing or nil
    for _, slot in ipairs(SLOT_ORDER) do
      if slot.key ~= "base" then
        local shade = row.shades[slot.key]
        copy.shades[slot.key] = {
          color = self._color.copy(shade.color),
          manualColor = shade.manualColor and self._color.copy(shade.manualColor) or nil,
          override = shade.override,
          locked = shade.locked,
        }
      end
    end
    output.rows[i] = copy
  end
  return output
end

function Model.fromTable(colorOps, data)
  local result = Model.new(colorOps)
  if type(data) ~= "table" or type(data.rows) ~= "table"
    or (data.version ~= 1 and data.version ~= Model.SCHEMA_VERSION) then
    return result, false
  end
  result.shadeCount = data.shadeCount == 5 and 5 or 3
  result.settings = normalizeSettings(data.settings)
  if data.version == 1 then
    -- v1 had no source tracking; its rows usually came from "Import sprite palette".
    result.source = { kind = "legacy", label = "Saved families" }
  elseif type(data.source) == "table" and Model.SOURCE_KINDS[data.source.kind] then
    result.source = { kind = data.source.kind, label = type(data.source.label) == "string" and data.source.label or "" }
  end
  for _, field in ipairs({ "ignored", "generated" }) do
    if type(data[field]) == "table" then
      for _, key in ipairs(data[field]) do
        if type(key) == "string" and key:match("^%d+,%d+,%d+$") then result[field][key] = true end
      end
    end
  end
  result.manualOrder = data.manualOrder == true
  local usedIds = {}
  for _, savedRow in ipairs(data.rows) do
    if type(savedRow) == "table" and colorOps.validRgb(savedRow.base) then
      local row = makeRow(0, validColor(savedRow.base, colorOps), savedRow.name)
      if type(savedRow.link) == "table" and validColor(savedRow.link.color, colorOps) then
        row.link = { color = validColor(savedRow.link.color, colorOps), index = tonumber(savedRow.link.index) }
      end
      row.baseEdited = savedRow.baseEdited == true
      row.missing = savedRow.missing == true
      local missing = {}
      for _, slot in ipairs(SLOT_ORDER) do
        if slot.key ~= "base" then
          local savedShade = type(savedRow.shades) == "table" and savedRow.shades[slot.key] or nil
          if type(savedShade) == "table" then
            local current = validColor(savedShade.color, colorOps)
            if current then
              row.shades[slot.key].color = current
            else
              missing[slot.key] = true
            end
            local manual = validColor(savedShade.manualColor, colorOps)
            row.shades[slot.key].manualColor = manual
            row.shades[slot.key].override = savedShade.override == true
            row.shades[slot.key].locked = current ~= nil and savedShade.locked == true
          else
            missing[slot.key] = true
          end
        end
      end
      local id = tonumber(savedRow.id)
      if not id or id < 1 or usedIds[id] then id = result.nextId end
      row.id = math.floor(id)
      usedIds[row.id] = true
      result.nextId = math.max(result.nextId, row.id + 1)
      for _, slot in ipairs(SLOT_ORDER) do
        if missing[slot.key] then generateShade(result, row, slot.key) end
      end
      result.rows[#result.rows + 1] = row
    end
  end
  local requestedNext = tonumber(data.nextId)
  if requestedNext and requestedNext > result.nextId then result.nextId = math.floor(requestedNext) end
  return result, true
end

return Model
