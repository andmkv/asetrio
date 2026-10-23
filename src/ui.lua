-- Main Palette Trio panel: a narrow floating palette made of one canvas.
--   toolbar:  two icons, Light (sun) and "..." (menu with everything else)
--   grid:     one row per base color, SHADOW | BASE | LIGHT (or 5 shades),
--             dense square cells like Aseprite's own palette
-- Click = paint color, right-click = background color, double-click = edit.
--
-- Window policy: the window is never resized by the extension after it is
-- shown. Its bounds are restored once, at creation, and saved on close.
local UI = {}

local LONG = {
  deepShadow = "Deep", shadow = "Shadow", base = "Base",
  highlight = "Light", brightHighlight = "Bright",
}
UI.SLOT_NAMES = LONG

local function hex(rgb)
  return string.format("#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
end
UI.hex = hex

local function aseColor(rgb, alpha)
  return Color { r = rgb.r, g = rgb.g, b = rgb.b, a = alpha or 255 }
end

local function themeColor(name, fallback)
  local ok, value = pcall(function() return app.theme.color[name] end)
  -- Themes without this color (and headless runs) return a transparent color.
  if ok and value and value.alpha > 0 then return value end
  return fallback
end

local TEXT = Color { r = 220, g = 220, b = 220 }
local DIM = Color { r = 150, g = 150, b = 150 }
local ACCENT = Color { r = 255, g = 205, b = 70 }
local WARN = Color { r = 230, g = 140, b = 40 }

local function sameRgb(color, rgb)
  return color and color.alpha > 0 and color.red == rgb.r and color.green == rgb.g and color.blue == rgb.b
end

local function isLight(rgb)
  return (0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b) > 150
end

function UI.swatchColor(row, key)
  if key == "base" then return row.base end
  return row.shades[key].color
end

function UI.selectedRgb(ctx)
  local row = ctx.model.rows[ctx.selectedRow]
  if not row then return nil end
  return UI.swatchColor(row, ctx.selectedSlot)
end

-- Alerts go through ctx.alert when provided (headless tests answer them).
function UI.alert(ctx, options)
  return (ctx.alert or app.alert)(options)
end

local function repaint(ctx)
  if ctx.dialog then ctx.dialog:repaint() end
end
UI.repaint = repaint

-- Stores the model as one undo step and reports failures instead of hiding them.
function UI.persist(ctx, label, extra)
  local ok, message = ctx.session.commit(ctx, label, extra)
  if not ok then
    ctx.saveError = tostring(message)
    if not ctx.saveFailureAlerted then
      ctx.saveFailureAlerted = true
      UI.alert(ctx, {
        title = "Palette Trio",
        text = { "Palette Trio could not store its families in this sprite.", tostring(message),
          "Changes stay visible until you switch documents, but they are not saved." },
        buttons = "OK",
      })
    end
  else
    ctx.saveError = nil
    if message then ctx.flatWarning = message end
  end
  if ctx.lightDialog and ctx.lightUI then pcall(ctx.lightUI.regeneratePreview, ctx) end
  repaint(ctx)
  return ok
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

local function slots(ctx)
  return ctx.model.visibleSlots(ctx.model.shadeCount)
end

local function gridTop(ctx)
  return ctx.grid.TOOLBAR_H
end
UI.gridTop = gridTop

-- Native palette metrics: color_bar.box_size and entries_separator, read
-- live so Palette Trio follows the user's palette preferences.
function UI.boxMetrics()
  local box, line = 11, 1
  pcall(function()
    local bar = app.preferences.color_bar
    local size = tonumber(bar.box_size)
    if size and size >= 4 and size <= 64 then box = math.floor(size) end
    if bar.entries_separator == false then line = 0 end
  end)
  return box, line
end

function UI.layout(ctx, width)
  local box, line = UI.boxMetrics()
  return ctx.grid.layout(width or ctx.canvasWidth or ctx.grid.WIDTH, ctx.model.shadeCount, box, line)
end

local function triangle(gc, x1, y1, x2, y2, x3, y3)
  gc:beginPath()
  gc:moveTo(x1, y1)
  gc:lineTo(x2, y2)
  gc:lineTo(x3, y3)
  gc:closePath()
  gc:fill()
end

local function wrap(gc, text, maxWidth, maxLines)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if line ~= "" and gc:measureText(candidate).width > maxWidth then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  while #lines > maxLines do table.remove(lines) end
  return lines
end
UI.wrap = wrap

local function paintIcon(gc, item, id, color)
  local cx, cy = item.x + math.floor(item.width / 2), item.y + math.floor(item.height / 2)
  gc.color = color
  if id == "light" then
    -- Small sun: 3x3 core and four short rays.
    gc:fillRect(Rectangle(cx - 1, cy - 1, 3, 3))
    gc:fillRect(Rectangle(cx, cy - 4, 1, 2)); gc:fillRect(Rectangle(cx, cy + 3, 1, 2))
    gc:fillRect(Rectangle(cx - 4, cy, 2, 1)); gc:fillRect(Rectangle(cx + 3, cy, 2, 1))
  elseif id == "menu" then
    for i = -1, 1 do gc:fillRect(Rectangle(cx + i * 3, cy, 2, 2)) end
  end
end

-- Toolbar icons align with the right edge of the swatch block (centered in
-- a wider window), so the toolbar and grid read as one compact unit.
function UI.toolbarItems(ctx, width)
  width = width or ctx.canvasWidth or ctx.grid.WIDTH
  local edge = width
  if #ctx.model.rows > 0 then edge = math.min(width, UI.layout(ctx, width).right + 1) end
  return ctx.grid.toolbar(edge)
end

local function toolbarHit(ctx, x, y)
  for _, item in ipairs(UI.toolbarItems(ctx)) do
    if x >= item.x and x < item.x + item.width and y >= item.y and y < item.y + item.height then return item.id end
  end
  return nil
end

local function paintToolbar(ctx, gc)
  local textColor = themeColor("text", TEXT)
  for _, item in ipairs(UI.toolbarItems(ctx, gc.width)) do
    local active = (item.id == "light" and ctx.lightDialog ~= nil)
      or (item.id == "menu" and ctx.menuDialog ~= nil)
      or ctx.hoverTool == item.id
    if active then
      gc.color = Color { r = 255, g = 255, b = 255, a = 40 }
      gc:fillRect(Rectangle(item.x, item.y, item.width, item.height))
    end
    paintIcon(gc, item, item.id, active and ACCENT or textColor)
    if item.id == "menu" and ctx.session.notice(ctx) then
      -- Attention badge: details are the first line of the menu.
      gc.color = ctx.saveError and Color { r = 230, g = 70, b = 60 } or WARN
      gc:fillRect(Rectangle(item.x + item.width - 3, item.y, 3, 3))
    end
  end
end

local function paintEmpty(ctx, gc, top)
  local text
  if not ctx.currentSprite then
    text = "Open a sprite"
  elseif ctx.loadStatus == "invalid" then
    text = "Saved data left untouched"
  elseif #ctx.model.rows == 0 then
    text = "No palette colors"
  end
  if not text then return end
  gc.color = themeColor("disabled", DIM)
  for i, line in ipairs(wrap(gc, text, gc.width - 6, 6)) do
    gc:fillText(line, 3, top + 4 + (i - 1) * 11)
  end
end

local BLACK = Color { r = 0, g = 0, b = 0 }
local WHITE = Color { r = 255, g = 255, b = 255 }

function UI.paint(ctx, gc)
  local grid = ctx.grid
  ctx.canvasWidth, ctx.canvasHeight = gc.width, gc.height
  paintToolbar(ctx, gc)
  local top = gridTop(ctx)
  local rows = ctx.model.rows
  if #rows == 0 then return paintEmpty(ctx, gc, top) end

  local visible = slots(ctx)
  local layout = UI.layout(ctx, gc.width)
  local cell = layout.cell
  ctx.scroll = math.max(0, math.min(ctx.scroll or 0, grid.maxScroll(layout, gc.height, #rows, top)))

  local fg, bg = app.fgColor, app.bgColor
  local first, last = grid.visibleRange(layout, gc.height, #rows, ctx.scroll, top)
  local mark = math.max(3, math.floor(cell / 3))
  local selected = nil
  gc:save()
  pcall(function()
    gc:beginPath()
    gc:rect(Rectangle(0, top, gc.width, gc.height - top))
    gc:clip()
  end)
  -- Dark block behind the cells: the 1px gaps read as separator lines, as in
  -- Aseprite's palette.
  if layout.line > 0 then
    local blockTop = grid.rowTop(layout, first, ctx.scroll, top) - layout.line
    local blockBottom = grid.rowTop(layout, last, ctx.scroll, top) + cell + layout.line
    gc.color = BLACK
    gc:fillRect(Rectangle(layout.left, blockTop, layout.blockWidth, blockBottom - blockTop))
  end
  for rowIndex = first, last do
    local row = rows[rowIndex]
    local y = grid.rowTop(layout, rowIndex, ctx.scroll, top)
    local missingRow = row.missing
    for i, slot in ipairs(visible) do
      local column = layout.columns[i]
      local x = column.x
      local rgb = UI.swatchColor(row, slot.key)
      gc.color = aseColor(rgb)
      gc:fillRect(Rectangle(x, y, cell, cell))
      local ink = isLight(rgb) and BLACK or WHITE
      if slot.key ~= "base" then
        local shade = row.shades[slot.key]
        if shade.override then
          -- Manual color: small filled corner square.
          gc.color = ink
          gc:fillRect(Rectangle(x + cell - 3, y + 1, 2, 2))
        elseif shade.locked then
          -- Pinned automatic color: single corner pixel.
          gc.color = ink
          gc:fillRect(Rectangle(x + cell - 2, y + 1, 1, 1))
        end
      elseif row.baseEdited or not row.link then
        -- Base edited here, or custom color not from the palette: bottom tick.
        gc.color = ink
        gc:fillRect(Rectangle(x + 1, y + cell - 2, math.max(2, math.floor(cell / 3)), 1))
      end
      if sameRgb(fg, rgb) then
        gc.color = ink
        triangle(gc, x, y, x + mark, y, x, y + mark)
      end
      if sameRgb(bg, rgb) then
        gc.color = ink
        triangle(gc, x + cell, y + cell, x + cell - mark, y + cell, x + cell, y + cell - mark)
      end
      if missingRow and i == 1 then
        -- Family whose palette color was removed: orange edge on the row.
        gc.color = WARN
        gc:fillRect(Rectangle(x, y, 2, cell))
      end
      if rowIndex == ctx.selectedRow and slot.key == ctx.selectedSlot then selected = { x = x, y = y } end
    end
  end
  if selected then
    -- Two-tone selection frame inside the cell, readable on any color.
    gc.strokeWidth = 1
    gc.color = WHITE
    gc:strokeRect(Rectangle(selected.x, selected.y, cell, cell))
    gc.color = BLACK
    gc:strokeRect(Rectangle(selected.x + 1, selected.y + 1, cell - 2, cell - 2))
  end
  gc:restore()

  local maxScroll = grid.maxScroll(layout, gc.height, #rows, top)
  if maxScroll > 0 then
    local track = gc.height - top
    local thumb = math.max(8, math.floor(track * track / (track + maxScroll)))
    local ty = top + math.floor((track - thumb) * ctx.scroll / maxScroll)
    gc.color = themeColor("disabled", DIM)
    gc:fillRect(Rectangle(math.min(gc.width - 2, layout.right + 1), ty, 2, thumb))
  end
end

------------------------------------------------------------------------------
-- Interaction
------------------------------------------------------------------------------

local function hitSlot(ctx, x, y)
  local visible = slots(ctx)
  local layout = UI.layout(ctx)
  local rowIndex, column = ctx.grid.hit(layout, #ctx.model.rows, ctx.scroll or 0, x, y, gridTop(ctx))
  if not rowIndex then return nil end
  return rowIndex, visible[column].key
end
UI.hitSlot = hitSlot

function UI.select(ctx, rowIndex, key)
  ctx.selectedRow, ctx.selectedSlot = rowIndex, key
  if ctx.dialogs then ctx.dialogs.syncEditor(ctx) end
end

-- Refreshes contents. Never changes window bounds.
function UI.refresh(ctx)
  if ctx.session then ctx.session.clampSelection(ctx) end
  repaint(ctx)
  if ctx.dialogs then
    ctx.dialogs.syncEditor(ctx)
    ctx.dialogs.syncOptions(ctx)
  end
  if ctx.menu then ctx.menu.sync(ctx) end
end

function UI.setShadeCount(ctx, count)
  if ctx.model.shadeCount == count then return end
  ctx.model.setShadeCount(ctx.model, count)
  ctx.session.clampSelection(ctx)
  UI.persist(ctx, "Palette Trio: " .. count .. " shades")
  UI.refresh(ctx)
end

function UI.onToolbar(ctx, id)
  if id == "light" then ctx.lightUI.open(ctx); repaint(ctx)
  elseif id == "menu" then ctx.menu.toggle(ctx) end
end

function UI.onMouseDown(ctx, ev)
  if ev.y < ctx.grid.TOOLBAR_H then
    if ev.button == MouseButton.LEFT or ev.button == MouseButton.RIGHT then
      local id = toolbarHit(ctx, ev.x, ev.y)
      if id then UI.onToolbar(ctx, id) end
    end
    return
  end
  if #ctx.model.rows == 0 then
    if ev.button == MouseButton.LEFT and ctx.currentSprite then ctx.menu.toggle(ctx) end
    return
  end
  local rowIndex, key = hitSlot(ctx, ev.x, ev.y)
  if not rowIndex then return end
  local rgb = UI.swatchColor(ctx.model.rows[rowIndex], key)
  if ev.button == MouseButton.LEFT then
    app.fgColor = aseColor(rgb)
    UI.select(ctx, rowIndex, key)
  elseif ev.button == MouseButton.RIGHT then
    app.bgColor = aseColor(rgb)
  else
    return
  end
  repaint(ctx)
end

function UI.onMouseMove(ctx, ev)
  local id = ev.y < ctx.grid.TOOLBAR_H and toolbarHit(ctx, ev.x, ev.y) or nil
  if id ~= ctx.hoverTool then
    ctx.hoverTool = id
    repaint(ctx)
  end
end

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------

-- Saved bounds are applied once, at creation, and only if they are sane and
-- (when Aseprite reports it) inside the main window.
function UI.validBounds(saved)
  if type(saved) ~= "table" then return nil end
  local x, y, w, h = tonumber(saved.x), tonumber(saved.y), tonumber(saved.width), tonumber(saved.height)
  if not (x and y and w and h) or w < 60 or h < 60 then return nil end
  local okWindow, area = pcall(function() return app.window.bounds end)
  if okWindow and area and area.width > 0 then
    w, h = math.min(w, area.width), math.min(h, area.height)
    x = math.max(area.x, math.min(x, area.x + area.width - w))
    y = math.max(area.y, math.min(y, area.y + area.height - h))
  end
  return Rectangle(math.floor(x), math.floor(y), math.floor(w), math.floor(h))
end

function UI.savedBounds(ctx)
  return UI.validBounds(ctx.preferences and ctx.preferences.bounds)
end

function UI.rememberBounds(ctx)
  if not ctx.dialog or not ctx.preferences then return end
  pcall(function()
    local b = ctx.dialog.bounds
    if b.width >= 60 and b.height >= 60 then
      ctx.preferences.bounds = { x = b.x, y = b.y, width = b.width, height = b.height }
    end
  end)
end

function UI.open(ctx)
  if ctx.dialog then
    -- Already open: never create a second window.
    pcall(function() ctx.dialog:show { wait = false } end)
    repaint(ctx)
    return
  end

  local dlg = Dialog {
    -- Short title: the title bar sets the window's minimum width, and the
    -- swatch grid itself is only ~40px wide.
    title = "Trio",
    resizeable = true,
    onclose = function()
      UI.rememberBounds(ctx)
      ctx.dialog = nil
      if ctx.menu then ctx.menu.close(ctx) end
      if ctx.dialogs then ctx.dialogs.closeAll(ctx) end
    end,
  }
  if not dlg then return end
  ctx.dialog = dlg
  ctx.scroll = 0

  local box, line = UI.boxMetrics()
  dlg:canvas {
    id = "grid",
    width = ctx.grid.naturalWidth(ctx.model.shadeCount, box, line),
    height = ctx.grid.initialHeight(#ctx.model.rows, ctx.model.shadeCount, box, line),
    autoscaling = true,
    hexpand = true,
    vexpand = true,
    onpaint = function(ev) UI.paint(ctx, ev.context) end,
    onwheel = function(ev)
      local layout = UI.layout(ctx)
      local maxScroll = ctx.grid.maxScroll(layout, ctx.canvasHeight or 0, #ctx.model.rows, gridTop(ctx))
      ctx.scroll = math.max(0, math.min(maxScroll, (ctx.scroll or 0) + ev.deltaY * layout.rowH))
      repaint(ctx)
    end,
    onmousedown = function(ev) UI.onMouseDown(ctx, ev) end,
    onmousemove = function(ev) UI.onMouseMove(ctx, ev) end,
    ondblclick = function(ev)
      local rowIndex, key = hitSlot(ctx, ev.x, ev.y)
      if rowIndex then
        UI.select(ctx, rowIndex, key)
        ctx.dialogs.openEditor(ctx)
      end
    end,
  }

  dlg:show { wait = false, bounds = UI.savedBounds(ctx) }
end

return UI
