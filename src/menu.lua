-- The "..." overflow menu. Aseprite 1.3.17's script API has no popup menus,
-- so this is a small window with one painted canvas, placed beside the
-- palette once at creation (show{bounds}) and closed after any action, on
-- Esc, or when "..." is clicked again. It never moves or resizes afterwards.
local Menu = {}

Menu.WIDTH = 176
Menu.ITEM_H = 15
Menu.SEPARATOR_H = 5

-- Pure: the menu entries for the current state.
function Menu.items(ctx)
  local hasSprite = ctx.currentSprite ~= nil and ctx.loadStatus ~= "invalid"
  local rows = #ctx.model.rows
  local hidden = 0
  for _ in pairs(ctx.model.ignored) do hidden = hidden + 1 end
  local missing = ctx.model.countMissing(ctx.model)
  local follows = ctx.session.followsPalette(ctx)
  local items = {}
  local notice = ctx.session.notice(ctx)
  if notice then items[#items + 1] = { id = "notice", text = notice, kind = "notice" } end
  items[#items + 1] = { id = "info", text = ctx.session.sourceText(ctx), kind = "info" }
  items[#items + 1] = { kind = "separator" }
  items[#items + 1] = { id = "shades3", text = "3 shades", checked = ctx.model.shadeCount == 3 }
  items[#items + 1] = { id = "shades5", text = "5 shades", checked = ctx.model.shadeCount == 5 }
  items[#items + 1] = { kind = "separator" }
  items[#items + 1] = { id = "choose", text = "Choose palette colors...", enabled = hasSprite }
  items[#items + 1] = { id = "full", text = "Use full document palette",
    enabled = hasSprite and (not follows or hidden > 0) }
  items[#items + 1] = { id = "missing", text = missing > 0 and ("Remove missing colors (" .. missing .. ")") or "Remove missing colors",
    enabled = hasSprite and missing > 0 }
  items[#items + 1] = { kind = "separator" }
  items[#items + 1] = { id = "addCurrent", text = "Add current color", enabled = hasSprite }
  items[#items + 1] = { id = "artwork", text = "Import colors from artwork...", enabled = hasSprite }
  items[#items + 1] = { id = "file", text = "Import palette file...", enabled = hasSprite }
  items[#items + 1] = { kind = "separator" }
  items[#items + 1] = { id = "edit", text = "Edit selected swatch...", enabled = rows > 0 }
  items[#items + 1] = { id = "settings", text = "Shade settings..." }
  items[#items + 1] = { id = "write", text = "Write to sprite palette...", enabled = hasSprite and rows > 0 }
  items[#items + 1] = { id = "export", text = "Export palette...", enabled = rows > 0 }
  items[#items + 1] = { kind = "separator" }
  items[#items + 1] = { id = "light", text = "Light..." }
  items[#items + 1] = { id = "about", text = "About Palette Trio..." }
  for _, item in ipairs(items) do
    if item.enabled == nil then item.enabled = item.kind == nil or item.kind == "notice" end
  end
  return items
end

function Menu.layout(items)
  local y, result = 2, {}
  for i, item in ipairs(items) do
    local h = item.kind == "separator" and Menu.SEPARATOR_H or Menu.ITEM_H
    result[i] = { y = y, height = h }
    y = y + h
  end
  return result, y + 2
end

function Menu.hit(items, y)
  local positions = Menu.layout(items)
  for i, pos in ipairs(positions) do
    if y >= pos.y and y < pos.y + pos.height then
      local item = items[i]
      if item.kind ~= "separator" and item.kind ~= "info" and item.enabled then return item, i end
      return nil
    end
  end
  return nil
end

-- Performs a menu action. The menu closes first so that modal dialogs opened
-- by the action are never stacked behind it.
function Menu.run(ctx, id)
  Menu.close(ctx)
  local d, ui = ctx.dialogs, ctx.ui
  if id == "notice" then
    if ctx.saveError then ctx.saveError = nil
    elseif ctx.flatWarning then ctx.flatWarning = nil
    elseif ctx.model.countMissing(ctx.model) > 0 then d.removeMissing(ctx) end
    ui.repaint(ctx)
  elseif id == "shades3" then ui.setShadeCount(ctx, 3)
  elseif id == "shades5" then ui.setShadeCount(ctx, 5)
  elseif id == "choose" then d.openChooser(ctx, "palette")
  elseif id == "full" then d.useFullPalette(ctx)
  elseif id == "missing" then d.removeMissing(ctx)
  elseif id == "addCurrent" then
    if not d.addCustom(ctx, ctx.aseprite.rgb(app.fgColor)) then
      ui.alert(ctx, { title = "Palette Trio", text = "The current color is already a family.", buttons = "OK" })
    end
  elseif id == "artwork" then d.openChooser(ctx, "artwork")
  elseif id == "file" then d.openImportFile(ctx)
  elseif id == "edit" then d.openEditor(ctx)
  elseif id == "settings" then d.openOptions(ctx)
  elseif id == "write" then d.writePalette(ctx)
  elseif id == "export" then d.openExport(ctx)
  elseif id == "light" then ctx.lightUI.open(ctx); ui.repaint(ctx)
  elseif id == "about" then ctx.about.open(ctx)
  end
end

local function themeColor(name, fallback)
  local ok, value = pcall(function() return app.theme.color[name] end)
  if ok and value and value.alpha > 0 then return value end
  return fallback
end

function Menu.paint(ctx, gc)
  local items = ctx.menuItems or Menu.items(ctx)
  local positions = Menu.layout(items)
  local text = themeColor("text", Color { r = 220, g = 220, b = 220 })
  local dim = themeColor("disabled", Color { r = 130, g = 130, b = 130 })
  for i, item in ipairs(items) do
    local pos = positions[i]
    if item.kind == "separator" then
      gc.color = Color { r = 128, g = 128, b = 128, a = 90 }
      gc:fillRect(Rectangle(6, pos.y + 2, gc.width - 12, 1))
    else
      if i == ctx.menuHover and item.enabled and item.kind ~= "info" then
        gc.color = Color { r = 255, g = 255, b = 255, a = 40 }
        gc:fillRect(Rectangle(1, pos.y, gc.width - 2, pos.height))
      end
      if item.kind == "notice" then
        gc.color = ctx.saveError and Color { r = 230, g = 70, b = 60 } or Color { r = 230, g = 140, b = 40 }
        gc:fillRect(Rectangle(4, pos.y + 5, 4, 4))
      end
      if item.checked then
        gc.color = text
        gc:fillRect(Rectangle(5, pos.y + 6, 3, 3))
      end
      gc.color = (item.enabled and item.kind ~= "info") and text or dim
      gc:fillText(item.text, 12, pos.y + 2)
    end
  end
end

function Menu.sync(ctx)
  if not ctx.menuDialog then return end
  ctx.menuItems = Menu.items(ctx)
  ctx.menuDialog:repaint()
end

function Menu.close(ctx)
  local dlg = ctx.menuDialog
  ctx.menuDialog, ctx.menuItems, ctx.menuHover = nil, nil, nil
  if dlg then pcall(function() dlg:close() end) end
  if ctx.ui then ctx.ui.repaint(ctx) end
end

local function uiScale()
  local ok, value = pcall(function() return app.uiScale end)
  return (ok and tonumber(value)) or 1
end

-- Where the menu window goes: right of the palette, or left of it when the
-- Aseprite window has no room on the right. Sized generously from the canvas
-- (the canvas fills any extra space, so nothing is clipped).
function Menu.bounds(ctx, height)
  local scale = uiScale()
  local w = math.floor((Menu.WIDTH + 16) * scale)
  local h = math.floor((height + 34) * scale)
  local okMain, main = pcall(function() return ctx.dialog.bounds end)
  if not okMain or not main then return nil end
  local x, y = main.x + main.width + 2, main.y
  local okWindow, area = pcall(function() return app.window.bounds end)
  if okWindow and area and area.width > 0 then
    if x + w > area.x + area.width then x = main.x - w - 2 end
    x = math.max(area.x, math.min(x, area.x + area.width - w))
    y = math.max(area.y, math.min(y, area.y + area.height - h))
  end
  return Rectangle(x, y, w, h)
end

function Menu.open(ctx)
  if ctx.menuDialog then return end
  ctx.menuItems = Menu.items(ctx)
  local _, height = Menu.layout(ctx.menuItems)
  local dlg = Dialog {
    title = "Palette Trio",
    resizeable = false,
    onclose = function()
      ctx.menuDialog, ctx.menuItems, ctx.menuHover = nil, nil, nil
      if ctx.ui then ctx.ui.repaint(ctx) end
    end,
  }
  if not dlg then return end
  ctx.menuDialog = dlg
  dlg:canvas {
    id = "menu", width = Menu.WIDTH, height = height, autoscaling = true, hexpand = true, vexpand = true,
    onpaint = function(ev) Menu.paint(ctx, ev.context) end,
    onmousemove = function(ev)
      local _, index = Menu.hit(ctx.menuItems or {}, ev.y)
      if index ~= ctx.menuHover then
        ctx.menuHover = index
        dlg:repaint()
      end
    end,
    onmousedown = function(ev)
      if ev.button ~= MouseButton.LEFT then return end
      local item = Menu.hit(ctx.menuItems or {}, ev.y)
      if item then Menu.run(ctx, item.id) end
    end,
    onkeydown = function(ev)
      local key = ev and (ev.code or ev.key)
      if key == "Escape" or key == "Esc" then Menu.close(ctx) end
    end,
  }
  dlg:show { wait = false, bounds = Menu.bounds(ctx, height) }
  if ctx.ui then ctx.ui.repaint(ctx) end
end

function Menu.toggle(ctx)
  if ctx.menuDialog then Menu.close(ctx) else Menu.open(ctx) end
end

return Menu
