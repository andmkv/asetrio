-- "About Palette Trio" dialog (opened from the ... menu).
local About = {}

About.WEBSITE_URL = "https://smallhall.net"
About.WEBSITE_TEXT = "Smallhall.net - More apps and games"
About.GITHUB_URL = "https://github.com/andmkv/asetrio"
About.GITHUB_TEXT = "GitHub - source, issues, releases"
About.AUTHOR = "Andrey Makeev"

-- Kept in code on purpose: reading package.json at runtime would make Aseprite
-- show a script-security prompt. scripts/build.py and the tests fail if this
-- differs from the "version" in package.json.
About.VERSION = "0.4.1"

function About.versionText(ctx)
  return "Version " .. About.VERSION .. " (beta)"
end

-- Opens a URL in the desktop browser. Aseprite's Dialog has no link widget;
-- app.command.Launch is the documented way (it needs no file access).
function About.launch(ctx, url)
  local launch = ctx.launch or function(target)
    return app.command.Launch { path = target }
  end
  local ok, result = pcall(launch, url)
  if not ok or result == false then
    (ctx.alert or app.alert) {
      title = "Palette Trio",
      text = { "Could not open the browser. The address is:", url },
      buttons = "OK",
    }
  end
end

function About.open(ctx)
  if ctx.aboutDialog then
    pcall(function() ctx.aboutDialog:show { wait = false } end)
    return
  end
  local dlg = Dialog {
    title = "About Palette Trio",
    resizeable = false,
    onclose = function() ctx.aboutDialog = nil end,
  }
  if not dlg then return end
  ctx.aboutDialog = dlg
  dlg:label { id = "name", text = "Palette Trio" }
  dlg:newrow()
  dlg:label { id = "version", text = About.versionText(ctx) }
  dlg:newrow()
  dlg:label { id = "tagline", text = "Shade families for your Aseprite palette," }
  dlg:newrow()
  dlg:label { id = "tagline2", text = "plus non-destructive pixel-art lighting." }
  dlg:separator()
  dlg:label { id = "author", text = "By " .. About.AUTHOR .. " - MIT License" }
  dlg:newrow()
  dlg:button { id = "website", text = About.WEBSITE_TEXT,
    onclick = function() About.launch(ctx, About.WEBSITE_URL) end }
  dlg:newrow()
  dlg:button { id = "github", text = About.GITHUB_TEXT,
    onclick = function() About.launch(ctx, About.GITHUB_URL) end }
  dlg:separator()
  dlg:button { id = "close", text = "Close", focus = true, onclick = function() dlg:close() end }
  dlg:show { wait = false }
end

return About
