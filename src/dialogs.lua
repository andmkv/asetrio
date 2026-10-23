-- Secondary Palette Trio dialogs, opened on demand (mostly from the "..."
-- menu) so the main panel stays a small palette: swatch editor, shade
-- settings, and the color chooser. None of them resizes or rebuilds another
-- window.
local Dialogs = {}

local function parseHex(value)
  if type(value) ~= "string" then return nil end
  local text = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
  if #text ~= 6 or not text:match("^%x%x%x%x%x%x$") then return nil end
  return {
    r = tonumber(text:sub(1, 2), 16),
    g = tonumber(text:sub(3, 4), 16),
    b = tonumber(text:sub(5, 6), 16),
  }
end
Dialogs.parseHex = parseHex

local function aseColor(rgb)
  return Color { r = rgb.r, g = rgb.g, b = rgb.b, a = 255 }
end

local function sameRgb(a, b)
  return a and b and a.r == b.r and a.g == b.g and a.b == b.b
end

-- Coalesces rapid edits (color picker drags, typing) into one undo step.
local function schedulePersist(ctx, label)
  ctx.pendingPersistLabel = label
  local ok = pcall(function()
    if not ctx.persistTimer then
      ctx.persistTimer = Timer {
        interval = 0.6,
        ontick = function()
          ctx.persistTimer:stop()
          if ctx.pendingPersistLabel then
            local pending = ctx.pendingPersistLabel
            ctx.pendingPersistLabel = nil
            ctx.ui.persist(ctx, pending)
          end
        end,
      }
    end
    ctx.persistTimer:stop()
    ctx.persistTimer:start()
  end)
  if not ok then
    ctx.pendingPersistLabel = nil
    ctx.ui.persist(ctx, label)
  end
end

function Dialogs.flushPending(ctx)
  if ctx.pendingPersistLabel then
    local label = ctx.pendingPersistLabel
    ctx.pendingPersistLabel = nil
    pcall(function() ctx.persistTimer:stop() end)
    ctx.ui.persist(ctx, label)
  end
end

------------------------------------------------------------------------------
-- Swatch editor
------------------------------------------------------------------------------

local function editorTitle(ctx)
  local row = ctx.model.rows[ctx.selectedRow]
  if not row then return "No swatch selected" end
  local name = row.name ~= "" and row.name or ("Family " .. ctx.selectedRow)
  return name .. " · " .. ctx.ui.SLOT_NAMES[ctx.selectedSlot]
end

local function editorState(ctx)
  local row = ctx.model.rows[ctx.selectedRow]
  if not row then return " " end
  if ctx.selectedSlot == "base" then
    if row.missing then return "Base · removed from the palette" end
    if not row.link then return "Base · custom color (not in palette)" end
    if row.baseEdited then return "Base · changed here; palette edits won't override" end
    return "Base · editing it regenerates auto shades"
  end
  local shade = row.shades[ctx.selectedSlot]
  if shade.override then return "Pinned · manual color" end
  if shade.locked then return "Pinned · kept when the base changes" end
  return "Auto · follows the base color"
end

function Dialogs.syncEditor(ctx)
  local dlg = ctx.editorDialog
  if not dlg then return end
  local row = ctx.model.rows[ctx.selectedRow]
  local rgb = ctx.ui.selectedRgb(ctx) or { r = 0, g = 0, b = 0 }
  ctx.syncingEditor = true
  local data = dlg.data
  data.color = aseColor(rgb)
  data.hex = ctx.ui.hex(rgb)
  data.name = row and row.name or ""
  dlg.data = data
  ctx.syncingEditor = false
  local isBase = ctx.selectedSlot == "base"
  local shade = row and not isBase and row.shades[ctx.selectedSlot] or nil
  local pinned = shade and (shade.locked or shade.override)
  dlg:modify { id = "title", text = editorTitle(ctx) }
  dlg:modify { id = "state", text = editorState(ctx) }
  -- Only enabled/text change here: toggling visibility forces a relayout,
  -- which Aseprite 1.3.17 may not fully redraw.
  dlg:modify { id = "pin", enabled = shade ~= nil, text = pinned and "Unpin" or "Pin" }
  dlg:modify { id = "auto", enabled = pinned and true or false }
  dlg:modify { id = "revert", enabled = isBase and row ~= nil and row.baseEdited and row.link ~= nil }
  for _, id in ipairs({ "color", "hex", "useFg", "name", "remove" }) do
    dlg:modify { id = id, enabled = row ~= nil }
  end
  dlg:modify { id = "up", enabled = row ~= nil and ctx.selectedRow > 1 }
  dlg:modify { id = "down", enabled = row ~= nil and ctx.selectedRow < #ctx.model.rows }
end

local function editSelected(ctx, rgb)
  local row = ctx.model.rows[ctx.selectedRow]
  if not row or not rgb then return end
  if sameRgb(ctx.ui.selectedRgb(ctx), rgb) then return end
  if ctx.selectedSlot == "base" then
    ctx.model.setBase(ctx.model, ctx.selectedRow, rgb)
  else
    ctx.model.editShade(ctx.model, ctx.selectedRow, ctx.selectedSlot, rgb)
  end
  ctx.ui.repaint(ctx)
  schedulePersist(ctx, "Palette Trio: edit color")
end

local function structuralChange(ctx, label)
  Dialogs.flushPending(ctx)
  ctx.ui.persist(ctx, label)
  ctx.ui.refresh(ctx)
end

function Dialogs.openEditor(ctx)
  if #ctx.model.rows == 0 then return end
  if ctx.editorDialog then
    ctx.editorDialog:show { wait = false }
    Dialogs.syncEditor(ctx)
    return
  end
  local dlg = Dialog {
    title = "Edit Swatch",
    onclose = function()
      Dialogs.flushPending(ctx)
      ctx.editorDialog = nil
    end,
  }
  ctx.editorDialog = dlg
  dlg:label { id = "title", text = editorTitle(ctx) }
  dlg:newrow()
  dlg:color { id = "color", color = aseColor(ctx.ui.selectedRgb(ctx) or { r = 0, g = 0, b = 0 }),
    onchange = function()
      if ctx.syncingEditor then return end
      local value = dlg.data.color
      if value then
        editSelected(ctx, ctx.aseprite.rgb(value))
        ctx.syncingEditor = true
        local data = dlg.data
        data.hex = ctx.ui.hex(ctx.aseprite.rgb(value))
        dlg.data = data
        ctx.syncingEditor = false
        dlg:modify { id = "state", text = editorState(ctx) }
      end
    end }
  dlg:entry { id = "hex", text = "", onchange = function()
    if ctx.syncingEditor then return end
    local rgb = parseHex(dlg.data.hex)
    if rgb then
      editSelected(ctx, rgb)
      ctx.syncingEditor = true
      local data = dlg.data
      data.color = aseColor(rgb)
      dlg.data = data
      ctx.syncingEditor = false
      dlg:modify { id = "state", text = editorState(ctx) }
    end
  end }
  dlg:button { id = "useFg", text = "Use current color", onclick = function()
    editSelected(ctx, ctx.aseprite.rgb(app.fgColor))
    Dialogs.flushPending(ctx)
    Dialogs.syncEditor(ctx)
  end }
  dlg:newrow()
  dlg:label { id = "state", text = editorState(ctx) }
  dlg:newrow()
  dlg:button { id = "pin", text = "Pin", onclick = function()
    local row = ctx.model.rows[ctx.selectedRow]
    local shade = row and row.shades[ctx.selectedSlot]
    if not shade then return end
    local pinned = shade.locked or shade.override
    ctx.model.setLocked(ctx.model, ctx.selectedRow, ctx.selectedSlot, not pinned)
    structuralChange(ctx, pinned and "Palette Trio: unpin shade" or "Palette Trio: pin shade")
  end }
  dlg:button { id = "auto", text = "Restore auto", onclick = function()
    if ctx.model.resetShade(ctx.model, ctx.selectedRow, ctx.selectedSlot) then
      structuralChange(ctx, "Palette Trio: restore auto shade")
    end
  end }
  dlg:button { id = "revert", text = "Revert base", onclick = function()
    local row = ctx.model.rows[ctx.selectedRow]
    if row and row.link then
      ctx.model.setBase(ctx.model, ctx.selectedRow, row.link.color)
      row.baseEdited = false
      structuralChange(ctx, "Palette Trio: revert base")
    end
  end }
  dlg:separator { text = "Family" }
  dlg:entry { id = "name", label = "Name", text = "", onchange = function()
    if ctx.syncingEditor or not ctx.model.rows[ctx.selectedRow] then return end
    ctx.model.setName(ctx.model, ctx.selectedRow, dlg.data.name or "")
    schedulePersist(ctx, "Palette Trio: rename family")
  end }
  dlg:newrow()
  dlg:button { id = "up", text = "Move up", onclick = function()
    if ctx.model.moveRow(ctx.model, ctx.selectedRow, -1) then
      ctx.selectedRow = ctx.selectedRow - 1
      structuralChange(ctx, "Palette Trio: reorder families")
    end
  end }
  dlg:button { id = "down", text = "Move down", onclick = function()
    if ctx.model.moveRow(ctx.model, ctx.selectedRow, 1) then
      ctx.selectedRow = ctx.selectedRow + 1
      structuralChange(ctx, "Palette Trio: reorder families")
    end
  end }
  dlg:button { id = "remove", text = "Remove", onclick = function()
    local row = ctx.model.rows[ctx.selectedRow]
    if not row then return end
    if ctx.model.hasUserEdits(row) then
      local answer = ctx.ui.alert(ctx, {
        title = "Remove family?",
        text = "This family has pinned shades, a name, or an edited base. Remove it?",
        buttons = { "Remove", "Cancel" },
      })
      if answer ~= 1 then return end
    end
    ctx.model.removeRow(ctx.model, ctx.selectedRow)
    ctx.selectedSlot = "base"
    structuralChange(ctx, "Palette Trio: remove family")
    if #ctx.model.rows == 0 then dlg:close() end
  end }
  dlg:separator()
  dlg:button { id = "done", text = "Done", focus = true, onclick = function() dlg:close() end }
  dlg:show { wait = false }
  Dialogs.syncEditor(ctx)
end

------------------------------------------------------------------------------
-- Shade settings
------------------------------------------------------------------------------

local function settingsFromOptions(ctx)
  local data = ctx.optionsDialog.data
  ctx.model.setSettings(ctx.model, {
    shadowStrength = (tonumber(data.shadowStrength) or 30) / 100,
    highlightStrength = (tonumber(data.highlightStrength) or 25) / 100,
    shadowHueShift = tonumber(data.shadowHueShift) or 10,
    highlightHueShift = tonumber(data.highlightHueShift) or 10,
    coolShadows = data.coolShadows == true,
    warmHighlights = data.warmHighlights == true,
  })
  ctx.ui.repaint(ctx)
end

local function storageNote(ctx)
  local sprite = ctx.currentSprite
  if not sprite then return "No sprite open." end
  local ok, filename = pcall(function() return sprite.filename end)
  if ok and not ctx.persistence.storesProperties(filename) then
    return "This file format can't store families; save as .aseprite."
  end
  if ctx.provisional then return "Families follow the palette; edits are saved in the sprite." end
  return "Families are saved in this sprite (.aseprite)."
end

function Dialogs.syncOptions(ctx)
  local dlg = ctx.optionsDialog
  if not dlg then return end
  local settings = ctx.model.settings
  ctx.syncingOptions = true
  local data = dlg.data
  data.shadowStrength = math.floor(settings.shadowStrength * 100 + 0.5)
  data.highlightStrength = math.floor(settings.highlightStrength * 100 + 0.5)
  data.shadowHueShift = math.floor(settings.shadowHueShift + 0.5)
  data.highlightHueShift = math.floor(settings.highlightHueShift + 0.5)
  data.coolShadows = settings.coolShadows
  data.warmHighlights = settings.warmHighlights
  dlg.data = data
  ctx.syncingOptions = false
  dlg:modify { id = "note", text = storageNote(ctx) }
end

-- The only command that changes the native palette. Provenance of the written
-- shades is stored in the same undo step, so they are never mistaken for
-- authored base colors later.
function Dialogs.writePalette(ctx)
  local sprite = ctx.currentSprite
  if not sprite then return end
  local colors = ctx.model.allColors(ctx.model)
  local mode
  if sprite.colorMode == ColorMode.RGB then
    local answer = ctx.ui.alert(ctx, {
      title = "Write to sprite palette",
      text = {
        string.format("Write Palette Trio's %d colors (%d shades per family) into the sprite palette?",
          #colors, ctx.model.shadeCount),
        "Append: add only the missing colors after the existing entries.",
        "Replace: the palette becomes exactly these colors.",
        "Artwork pixels never change. Undo reverts either option.",
      },
      buttons = { "Append", "Replace", "Cancel" },
    })
    if answer == 1 then mode = "append" elseif answer == 2 then mode = "replace" else return end
  else
    local answer = ctx.ui.alert(ctx, {
      title = "Write to sprite palette",
      text = {
        string.format("Append the missing colors of Palette Trio's %d colors to this palette?", #colors),
        "Existing entries and the transparent index are never changed or reordered.",
      },
      buttons = { "Append", "Cancel" },
    })
    if answer ~= 1 then return end
    mode = "append"
  end
  local saveError
  local record = function()
    ctx.model.recordGenerated(ctx.model, colors)
    local ok, reason = ctx.persistence.save(sprite, ctx.namespace, ctx.model)
    if not ok then saveError = reason end
  end
  local ok, result, reason = pcall(ctx.aseprite.apply, sprite, colors, mode, record)
  if not ok then
    ctx.ui.alert(ctx, { title = "Palette Trio", text = "Writing the palette failed: " .. tostring(result), buttons = "OK" })
  elseif not result then
    ctx.ui.alert(ctx, { title = "Palette Trio", text = reason, buttons = "OK" })
  else
    if saveError then ctx.saveError = saveError else ctx.provisional = false; ctx.loadStatus = "ok" end
    ctx.session.syncNow(ctx)
    ctx.ui.refresh(ctx)
  end
end

function Dialogs.openExport(ctx)
  local dlg = Dialog { title = "Export Palette" }
  dlg:file { id = "filename", label = "File", title = "Export Palette Trio colors",
    filename = "Palette-Trio.gpl", filetypes = { "gpl", "pal", "png", "aseprite" }, save = true, entry = true }
  dlg:button { id = "ok", text = "Export", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  dlg:show()
  if not dlg.data.ok then return end
  local path = dlg.data.filename
  if type(path) ~= "string" or path == "" then return end
  local ok, result, reason = pcall(ctx.aseprite.export, ctx.model.allColors(ctx.model), path)
  if not ok or not result then
    ctx.ui.alert(ctx, { title = "Palette Trio", text = "Export failed: " .. tostring(ok and reason or result), buttons = "OK" })
  end
end

function Dialogs.openOptions(ctx)
  if ctx.optionsDialog then
    pcall(function() ctx.optionsDialog:show { wait = false } end)
    Dialogs.syncOptions(ctx)
    return
  end
  local dlg = Dialog {
    title = "Shade Settings",
    onclose = function() ctx.optionsDialog = nil end,
  }
  ctx.optionsDialog = dlg
  local function live()
    if not ctx.syncingOptions then settingsFromOptions(ctx) end
  end
  local function commit()
    if ctx.syncingOptions then return end
    settingsFromOptions(ctx)
    ctx.ui.persist(ctx, "Palette Trio: shade settings")
    ctx.ui.refresh(ctx)
  end

  dlg:separator { text = "Shade generation" }
  dlg:slider { id = "shadowStrength", label = "Shadow depth", min = 0, max = 100, value = 30,
    onchange = live, onrelease = commit }
  dlg:slider { id = "highlightStrength", label = "Highlight lift", min = 0, max = 100, value = 25,
    onchange = live, onrelease = commit }
  dlg:check { id = "coolShadows", label = "Hue shift", text = "Cool shadows", onclick = commit }
  dlg:slider { id = "shadowHueShift", min = -90, max = 90, value = 10, onchange = live, onrelease = commit }
  dlg:newrow()
  dlg:check { id = "warmHighlights", text = "Warm highlights", onclick = commit }
  dlg:slider { id = "highlightHueShift", min = -90, max = 90, value = 10, onchange = live, onrelease = commit }
  dlg:newrow()
  dlg:button { id = "defaults", text = "Default settings", onclick = function()
    ctx.model.setSettings(ctx.model, ctx.modelModule.DEFAULTS.settings)
    ctx.ui.persist(ctx, "Palette Trio: default shade settings")
    ctx.ui.refresh(ctx)
  end }
  dlg:separator()
  dlg:label { id = "note", text = storageNote(ctx) }
  dlg:separator()
  dlg:button { id = "close", text = "Close", onclick = function() dlg:close() end }
  dlg:show { wait = false }
  Dialogs.syncOptions(ctx)
end

------------------------------------------------------------------------------
-- Color source actions (reached from the "..." menu)
------------------------------------------------------------------------------

local function rgbKey(rgb)
  return string.format("%d,%d,%d", rgb.r, rgb.g, rgb.b)
end

function Dialogs.useFullPalette(ctx)
  local report = ctx.session.useFullPalette(ctx)
  ctx.ui.persist(ctx, "Palette Trio: use full document palette")
  ctx.ui.refresh(ctx)
  return report
end

function Dialogs.addCustom(ctx, rgb)
  local row = ctx.model.addCustom(ctx.model, rgb)
  if not row then return false end
  ctx.selectedRow, ctx.selectedSlot = #ctx.model.rows, "base"
  ctx.ui.persist(ctx, "Palette Trio: add custom color")
  ctx.ui.refresh(ctx)
  return true
end

function Dialogs.removeMissing(ctx)
  local edited = 0
  for _, row in ipairs(ctx.model.rows) do
    if row.missing and ctx.model.hasUserEdits(row) then edited = edited + 1 end
  end
  if edited > 0 then
    local answer = ctx.ui.alert(ctx, {
      title = "Palette Trio",
      text = string.format("%s with pinned shades or names will be removed.", ctx.source.plural(edited, "family")),
      buttons = { "Remove", "Cancel" },
    })
    if answer ~= 1 then return end
  end
  ctx.session.removeMissing(ctx)
  ctx.ui.persist(ctx, "Palette Trio: remove families not in palette")
  ctx.ui.refresh(ctx)
end

function Dialogs.openImportFile(ctx)
  local dlg = Dialog { title = "Import Palette File" }
  dlg:file { id = "filename", label = "File", title = "Choose a palette file",
    filetypes = { "gpl", "pal", "act", "col", "hex", "png", "aseprite", "ase" }, open = true, entry = true }
  dlg:button { id = "ok", text = "Choose colors...", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  dlg:show()
  if not dlg.data.ok then return end
  local path = dlg.data.filename
  if type(path) ~= "string" or path == "" then return end
  local raw, reason = ctx.aseprite.readPaletteFile(path)
  if not raw then ctx.ui.alert(ctx, { title = "Palette Trio", text = reason, buttons = "OK" }); return end
  local entries = ctx.source.dedupe(raw)
  for _, entry in ipairs(entries) do entry.index = nil end
  entries = ctx.source.removeKnown(entries, ctx.model)
  Dialogs.openChooser(ctx, "file", entries, path:match("([^/\\]+)$") or path)
end

------------------------------------------------------------------------------
-- Color chooser (modal)
--   palette: include/exclude native palette colors (exclusions persist)
--   artwork / file: pick colors to ADD as custom families
------------------------------------------------------------------------------

local CHOOSER_COLS, CHOOSER_CELL, CHOOSER_MAX_ROWS = 16, 14, 12
local CHOOSER_SHOW_LIMIT = 256

-- Pure: which candidates start selected.
function Dialogs.initialSelection(kind, entries, model)
  local selected = {}
  if kind == "palette" then
    for _, entry in ipairs(entries) do
      local key = rgbKey(entry.color)
      if not model.ignored[key] then selected[key] = true end
    end
  end
  return selected
end

function Dialogs.openChooser(ctx, kind, fileEntries, fileLabel)
  local sprite = ctx.currentSprite
  if kind ~= "file" and not sprite then return end
  Dialogs.flushPending(ctx)

  local entries, note = {}, ""
  if kind == "palette" then
    local info = ctx.source.readPalette(sprite, ctx.model)
    entries = info and info.entries or {}
    if info and (info.generated or 0) > 0 then
      note = ctx.source.plural(info.generated, "written shade") .. " not shown"
    end
  elseif kind == "artwork" then
    local info = ctx.source.readArtwork(sprite, ctx.namespace, ctx.model)
    entries = info and info.entries or {}
    if info and info.tooMany then note = string.format("art has %d+ colors", ctx.source.ARTWORK_LIMIT) end
  else
    entries = fileEntries or {}
  end
  if #entries > CHOOSER_SHOW_LIMIT then
    local cut = {}
    for i = 1, CHOOSER_SHOW_LIMIT do cut[i] = entries[i] end
    entries = cut
    note = (note ~= "" and note .. " · " or "") .. "showing " .. CHOOSER_SHOW_LIMIT .. " most used"
  end
  local state = { selected = Dialogs.initialSelection(kind, entries, ctx.model), scroll = 0 }
  local titles = { palette = "Choose Palette Colors", artwork = "Add Colors From Artwork",
    file = "Add Colors From " .. tostring(fileLabel or "File") }
  local dlg = Dialog { title = titles[kind] }

  local function count()
    local n = 0
    for _, entry in ipairs(entries) do if state.selected[rgbKey(entry.color)] then n = n + 1 end end
    return n
  end
  local function update()
    local n = count()
    local text = kind == "palette"
      and string.format("%d of %d palette colors shown as families", n, #entries)
      or string.format("%d selected to add", n)
    dlg:modify { id = "count", text = text }
    dlg:modify { id = "note", text = note ~= "" and note or "Click colors to include or exclude them." }
    dlg:repaint()
  end
  local rows = math.max(1, math.min(CHOOSER_MAX_ROWS, math.ceil(math.max(1, #entries) / CHOOSER_COLS)))
  dlg:canvas {
    id = "colors", width = CHOOSER_COLS * CHOOSER_CELL, height = rows * CHOOSER_CELL, autoscaling = true,
    onpaint = function(ev)
      local gc = ev.context
      if #entries == 0 then
        gc.color = Color { r = 160, g = 160, b = 160 }
        gc:fillText(kind == "palette" and "The palette has no colors." or "No new colors found.", 4, 4)
        return
      end
      for i, entry in ipairs(entries) do
        local row = (i - 1) // CHOOSER_COLS - state.scroll
        if row >= 0 and row < CHOOSER_MAX_ROWS then
          local x, y = ((i - 1) % CHOOSER_COLS) * CHOOSER_CELL, row * CHOOSER_CELL
          gc.color = aseColor(entry.color)
          gc:fillRect(Rectangle(x, y, CHOOSER_CELL - 1, CHOOSER_CELL - 1))
          local light = (0.2126 * entry.color.r + 0.7152 * entry.color.g + 0.0722 * entry.color.b) > 150
          if state.selected[rgbKey(entry.color)] then
            gc.color = light and Color { r = 0, g = 0, b = 0 } or Color { r = 255, g = 255, b = 255 }
            gc.strokeWidth = 1
            gc:strokeRect(Rectangle(x + 1, y + 1, CHOOSER_CELL - 3, CHOOSER_CELL - 3))
          else
            gc.color = Color { r = 0, g = 0, b = 0, a = 160 }
            gc:fillRect(Rectangle(x, y, CHOOSER_CELL - 1, CHOOSER_CELL - 1))
          end
        end
      end
    end,
    onmousedown = function(ev)
      local col, row = ev.x // CHOOSER_CELL, ev.y // CHOOSER_CELL + state.scroll
      if col < 0 or col >= CHOOSER_COLS then return end
      local entry = entries[row * CHOOSER_COLS + col + 1]
      if not entry then return end
      local key = rgbKey(entry.color)
      state.selected[key] = not state.selected[key] or nil
      update()
    end,
    onmousemove = function(ev)
      local col, row = ev.x // CHOOSER_CELL, ev.y // CHOOSER_CELL + state.scroll
      local entry = col >= 0 and col < CHOOSER_COLS and entries[row * CHOOSER_COLS + col + 1]
      if entry then
        local text = ctx.ui.hex(entry.color)
        if entry.count then text = text .. " · " .. entry.count .. " px" end
        if entry.index then text = text .. " · index " .. entry.index end
        dlg:modify { id = "note", text = text }
      end
    end,
    onwheel = function(ev)
      local total = math.ceil(#entries / CHOOSER_COLS)
      state.scroll = math.max(0, math.min(math.max(0, total - CHOOSER_MAX_ROWS), state.scroll + (ev.deltaY > 0 and 1 or -1)))
      dlg:repaint()
    end,
  }
  dlg:newrow()
  dlg:label { id = "note", text = " " }
  dlg:newrow()
  dlg:button { id = "all", text = "All", onclick = function()
    for _, entry in ipairs(entries) do state.selected[rgbKey(entry.color)] = true end
    update()
  end }
  dlg:button { id = "none", text = "None", onclick = function() state.selected = {}; update() end }
  dlg:newrow()
  dlg:label { id = "count", text = " " }
  dlg:separator()
  dlg:button { id = "ok", text = kind == "palette" and "Apply" or "Add", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  update()
  dlg:show()
  if not dlg.data.ok then return end
  if kind == "palette" then
    Dialogs.applyPaletteSubset(ctx, state.selected)
  else
    local added = 0
    for _, entry in ipairs(entries) do
      if state.selected[rgbKey(entry.color)] and ctx.model.addCustom(ctx.model, entry.color) then added = added + 1 end
    end
    if added > 0 then
      ctx.ui.persist(ctx, "Palette Trio: add colors")
      ctx.ui.refresh(ctx)
    end
  end
end

-- Applies an include set for the native palette, confirming before edited
-- families are removed. Returns false when cancelled.
function Dialogs.applyPaletteSubset(ctx, included)
  local removing = ctx.session.applyPaletteSubset(ctx, included, true)
  local edited = 0
  for _, row in ipairs(removing) do if ctx.model.hasUserEdits(row) then edited = edited + 1 end end
  if edited > 0 then
    local answer = ctx.ui.alert(ctx, {
      title = "Palette Trio",
      text = {
        string.format("%s you excluded %s pinned shades, names or edited bases.",
          ctx.source.plural(edited, "family"), edited == 1 and "has" or "have"),
        "Remove them anyway?",
      },
      buttons = { "Remove", "Cancel" },
    })
    if answer ~= 1 then return false end
  end
  ctx.session.applyPaletteSubset(ctx, included)
  ctx.ui.persist(ctx, "Palette Trio: choose palette colors")
  ctx.ui.refresh(ctx)
  return true
end

function Dialogs.closeAll(ctx)
  Dialogs.flushPending(ctx)
  for _, key in ipairs({ "editorDialog", "optionsDialog" }) do
    local dlg = ctx[key]
    ctx[key] = nil
    if dlg then pcall(function() dlg:close() end) end
  end
end

return Dialogs
