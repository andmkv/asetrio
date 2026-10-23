local runtime = nil

local MINIMUM_VERSION = Version("1.3.15")
local PUBLISHER_NAME = "palette-trio/palette-trio"
-- View menu, first section (next to "Duplicate View"), as defined by the
-- "view_new" group in Aseprite 1.3.17's data/gui.xml.
local MENU_GROUP = "view_new"

local function loadModule(root, path)
  return dofile(app.fs.joinPath(root, path))
end

local function refreshViews(ctx)
  if ctx.dialog then ctx.ui.refresh(ctx) end
  if ctx.lightDialog then ctx.lightUI.onSpriteChange(ctx) end
end

local function unbindSprite(ctx)
  if ctx.spriteEventSource and ctx.spriteEventCode then
    pcall(function() ctx.spriteEventSource:off(ctx.spriteEventCode) end)
  end
  ctx.spriteEventSource, ctx.spriteEventCode = nil, nil
end

local function bindSpriteChanges(ctx, sprite)
  unbindSprite(ctx)
  if not sprite then return end
  local handler = function(ev)
    if ctx.currentSprite ~= sprite then return end
    if ev and ev.fromUndo then
      -- Undo/redo may have restored older families: reload from the document.
      ctx.session.load(ctx, sprite)
      refreshViews(ctx)
      return
    end
    if (ctx.dialog or ctx.lightDialog) and ctx.session.onSpriteChanged(ctx) then
      if ctx.dialog then ctx.ui.refresh(ctx) end
      if ctx.lightDialog then pcall(ctx.lightUI.regeneratePreview, ctx) end
    end
  end
  local ok, code = pcall(function() return sprite.events:on("change", handler) end)
  if ok then
    ctx.spriteEventSource, ctx.spriteEventCode = sprite.events, code
  end
end

local function switchSprite(ctx, sprite)
  if ctx.dialogs then ctx.dialogs.flushPending(ctx) end
  bindSpriteChanges(ctx, sprite)
  ctx.session.load(ctx, sprite)
  refreshViews(ctx)
end

function init(plugin)
  if app.version < MINIMUM_VERSION then
    app.alert {
      title = "Palette Trio needs a newer Aseprite",
      text = "Palette Trio requires Aseprite 1.3.15 or newer.",
      buttons = "OK",
    }
    return
  end

  local root = plugin.path
  local color = loadModule(root, "src/color.lua")
  local model = loadModule(root, "src/model.lua")

  runtime = {
    plugin = plugin,
    color = color,
    modelModule = model,
    persistence = loadModule(root, "src/persistence.lua"),
    aseprite = loadModule(root, "src/aseprite.lua"),
    source = loadModule(root, "src/source.lua"),
    session = loadModule(root, "src/session.lua"),
    grid = loadModule(root, "src/grid.lua"),
    ui = loadModule(root, "src/ui.lua"),
    dialogs = loadModule(root, "src/dialogs.lua"),
    menu = loadModule(root, "src/menu.lua"),
    about = loadModule(root, "src/about.lua"),
    lightEngine = loadModule(root, "src/light_engine.lua"),
    lightAseprite = loadModule(root, "src/light_aseprite.lua"),
    lightUI = loadModule(root, "src/light_ui.lua"),
    namespace = PUBLISHER_NAME,
    preferences = plugin.preferences,
    selectedRow = 0,
    selectedSlot = "base",
    scroll = 0,
  }
  runtime.model = model.new(color)
  runtime.loaded = false

  runtime.siteChangeCode = app.events:on("sitechange", function()
    if not runtime then return end
    local sprite = app.sprite
    if sprite ~= runtime.currentSprite then
      if runtime.dialog or runtime.lightDialog then
        switchSprite(runtime, sprite)
      else
        -- Panel closed: load lazily on next open.
        runtime.loaded = false
        unbindSprite(runtime)
        runtime.currentSprite = nil
      end
    end
  end)

  local function repaintPanel()
    if runtime and runtime.dialog then runtime.dialog:repaint() end
  end
  local okFg, fgCode = pcall(function() return app.events:on("fgcolorchange", repaintPanel) end)
  local okBg, bgCode = pcall(function() return app.events:on("bgcolorchange", repaintPanel) end)
  runtime.colorEventCodes = { okFg and fgCode or nil, okBg and bgCode or nil }

  local function ensureLoaded()
    if not runtime.loaded or app.sprite ~= runtime.currentSprite then
      switchSprite(runtime, app.sprite)
      runtime.loaded = true
    end
  end

  -- One user-visible command. Palette Trio Light opens from inside the panel.
  -- The id is unchanged from 1.x/2.0 so existing keyboard shortcuts still work.
  plugin:newCommand {
    id = "PaletteTrio",
    title = "Palette Trio",
    group = MENU_GROUP,
    onclick = function()
      if not runtime then return end
      ensureLoaded()
      runtime.ui.open(runtime)
    end,
  }
end

function exit(plugin)
  if not runtime then return end
  local ctx = runtime
  pcall(ctx.dialogs.flushPending, ctx)
  pcall(function() if ctx.persistTimer then ctx.persistTimer:stop() end end)
  if ctx.dialog then
    pcall(ctx.ui.rememberBounds, ctx)
    pcall(function() ctx.dialog:close() end)
  end
  pcall(ctx.menu.close, ctx)
  if ctx.aboutDialog then pcall(function() ctx.aboutDialog:close() end) end
  pcall(ctx.dialogs.closeAll, ctx)
  if ctx.lightDialog then
    pcall(function() ctx.lightDialog:close() end)
  end
  unbindSprite(ctx)
  if ctx.siteChangeCode then
    pcall(function() app.events:off(ctx.siteChangeCode) end)
  end
  for _, code in pairs(ctx.colorEventCodes or {}) do
    pcall(function() app.events:off(code) end)
  end
  runtime = nil
end
