-- Document-level state for Palette Trio.
--
-- Ownership:
--   native palette  -> artist-authored base colors (the default source)
--   Palette Trio    -> derived shade families + the artist's overrides
--   artwork pixels  -> image data; only an optional, explicit import source
--
-- Families that follow the native palette ("palette" source) are re-synced in
-- memory whenever the document is loaded or its palette changes. That sync is
-- deterministic and non-destructive, so it is never written by itself; the
-- document only stores Palette Trio data when the artist changes something.
local Session = {}

local function clampSelection(ctx)
  local count = #ctx.model.rows
  if count == 0 then
    ctx.selectedRow = 0
  else
    ctx.selectedRow = math.max(1, math.min(ctx.selectedRow or 1, count))
  end
  ctx.selectedSlot = ctx.selectedSlot or "base"
  if ctx.model.shadeCount == 3 and (ctx.selectedSlot == "deepShadow" or ctx.selectedSlot == "brightHighlight") then
    ctx.selectedSlot = "base"
  end
end
Session.clampSelection = clampSelection

-- True when the families follow the native palette automatically.
function Session.followsPalette(ctx)
  return ctx.model.source.kind == "palette"
end

-- Merges the current native palette into the families (in memory).
function Session.syncNow(ctx)
  local sprite = ctx.currentSprite
  local palette = sprite and ctx.source.readPalette(sprite, ctx.model)
  if not palette then return nil end
  local report = ctx.model.syncSource(ctx.model, palette.entries)
  if ctx.provisional then
    -- Nothing stored yet, so nothing of the artist's can be lost: drop
    -- families whose color left the palette instead of flagging them.
    local kept = {}
    for _, row in ipairs(ctx.model.rows) do if not row.missing then kept[#kept + 1] = row end end
    ctx.model.rows = kept
    report.missing = 0
  end
  ctx.model.sortByLink(ctx.model)
  ctx.paletteInfo = palette
  ctx.syncReport = report
  ctx.paletteSignature = ctx.source.paletteSignature(sprite)
  ctx.paletteChanged = false
  clampSelection(ctx)
  return report
end

-- Loads the active sprite's families. Nothing is written.
function Session.load(ctx, sprite)
  ctx.currentSprite = sprite
  local model, status, message = ctx.persistence.load(sprite, ctx.namespace, ctx.modelModule, ctx.color)
  ctx.model, ctx.loadStatus, ctx.loadMessage = model, status, message
  ctx.provisional, ctx.paletteChanged, ctx.syncReport, ctx.paletteInfo = false, false, nil, nil
  ctx.paletteSignature = sprite and ctx.source.paletteSignature(sprite) or ""
  if sprite and status == "none" then
    -- Default: every eligible native palette color becomes a family.
    model.setSource(model, "palette", "Document palette")
    ctx.provisional = true
    Session.syncNow(ctx)
  elseif sprite and status == "ok" and Session.followsPalette(ctx) then
    Session.syncNow(ctx)
  end
  ctx.scroll = 0
  clampSelection(ctx)
  return status
end

-- Stores the families in the sprite as one undoable step.
-- Returns ok, message (message is a warning on success, a reason on failure).
function Session.commit(ctx, label, extra)
  local sprite = ctx.currentSprite
  if not sprite then return false, "No sprite open; changes are not stored." end
  if ctx.loadStatus == "invalid" then
    return false, "Stored Palette Trio data is from an unknown version and was left untouched."
  end
  local saved, reason = false, nil
  local ok, err = pcall(function()
    app.transaction(label or "Update Palette Trio", function()
      if extra then extra() end
      saved, reason = ctx.persistence.save(sprite, ctx.namespace, ctx.model)
    end)
  end)
  if not ok then saved, reason = false, tostring(err) end
  if not saved then return false, reason or "Unknown error." end
  ctx.provisional = false
  ctx.loadStatus = "ok"
  ctx.paletteSignature = ctx.source.paletteSignature(sprite)
  local warning = nil
  local filenameOk, filename = pcall(function() return sprite.filename end)
  if filenameOk and not ctx.persistence.storesProperties(filename) then
    ctx.flatWarned = ctx.flatWarned or {}
    if not ctx.flatWarned[filename] then
      ctx.flatWarned[filename] = true
      warning = "PNG can't keep Palette Trio data. Save as .aseprite."
    end
  end
  return true, warning
end

-- Called on every sprite change while a panel is open. Cheap unless the
-- palette actually changed. Returns true when the families changed.
function Session.onSpriteChanged(ctx)
  local sprite = ctx.currentSprite
  if not sprite then return false end
  local ok, signature = pcall(ctx.source.paletteSignature, sprite)
  if not ok or signature == ctx.paletteSignature then return false end
  ctx.paletteSignature = signature
  if ctx.loadStatus == "invalid" then return false end
  if ctx.provisional or ctx.loadStatus == "none" then
    Session.load(ctx, sprite)
    return true
  end
  if Session.followsPalette(ctx) then
    Session.syncNow(ctx)
    return true
  end
  ctx.paletteChanged = true
  return true
end

-- Switches the families back to following the whole native palette:
-- clears exclusions, keeps custom families and every edit.
function Session.useFullPalette(ctx)
  ctx.model.setIgnored(ctx.model, {})
  ctx.model.setSource(ctx.model, "palette", "Document palette")
  return Session.syncNow(ctx)
end

-- Applies a palette subset: `included` is a set of color keys among the
-- current palette entries. Returns the rows that will be removed (dry run)
-- or performs the change.
function Session.applyPaletteSubset(ctx, included, dryRun)
  local palette = ctx.currentSprite and ctx.source.readPalette(ctx.currentSprite, ctx.model)
  if not palette then return {} end
  local excluded = {}
  for _, entry in ipairs(palette.entries) do
    local k = ctx.modelModule.colorKey(entry.color)
    if not included[k] then excluded[k] = true end
  end
  local removing, keep = {}, {}
  for _, row in ipairs(ctx.model.rows) do
    local k = row.link and ctx.modelModule.colorKey(row.link.color)
    if k and excluded[k] then removing[#removing + 1] = row else keep[#keep + 1] = row end
  end
  if dryRun then return removing end
  ctx.model.rows = keep
  local keys = {}
  for k in pairs(excluded) do keys[#keys + 1] = k end
  ctx.model.setIgnored(ctx.model, keys)
  ctx.model.setSource(ctx.model, "palette", "Document palette")
  Session.syncNow(ctx)
  return removing
end

function Session.removeMissing(ctx)
  local kept, removed = {}, 0
  for _, row in ipairs(ctx.model.rows) do
    if row.missing then removed = removed + 1 else kept[#kept + 1] = row end
  end
  ctx.model.rows = kept
  clampSelection(ctx)
  return removed
end

local KIND_TEXT = {
  palette = "Document palette",
  artwork = "Artwork colors",
  manual = "Custom colors",
  file = "Palette file",
  legacy = "Saved families",
}

function Session.sourceText(ctx)
  if not ctx.currentSprite then return "No sprite open" end
  if ctx.loadStatus == "invalid" then return "Stored data not readable" end
  local count = #ctx.model.rows
  local text = (KIND_TEXT[ctx.model.source.kind] or "Colors") .. " · " .. ctx.source.plural(count, "family")
  local hidden = 0
  for _ in pairs(ctx.model.ignored) do hidden = hidden + 1 end
  if Session.followsPalette(ctx) and hidden > 0 then text = text .. " · " .. hidden .. " hidden" end
  return text
end

-- Short notice drawn at the top of the grid, or nil when all is well.
function Session.notice(ctx)
  if not ctx.currentSprite then return nil end
  if ctx.loadStatus == "invalid" then return ctx.loadMessage or "Stored data not readable" end
  if ctx.saveError then return "Not saved: " .. ctx.saveError end
  if ctx.flatWarning then return ctx.flatWarning end
  local missing = ctx.model.countMissing(ctx.model)
  if missing > 0 then return ctx.source.plural(missing, "family") .. " not in palette" end
  if ctx.paletteChanged then return "Palette changed · click to use it" end
  return nil
end

return Session
