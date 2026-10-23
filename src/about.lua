-- "About Palette Trio" dialog (opened from the ... menu).
local About = {}

About.WEBSITE_URL = "https://smallhall.net"
About.WEBSITE_TEXT = "Smallhall.net - More apps and games"
About.GITHUB_URL = "https://github.com/andmkv/asetrio"
About.GITHUB_TEXT = "GitHub - source, issues, releases"
About.AUTHOR = "Andrey Makeev"

-- Reads "version" from the extension's package.json (no JSON library needed).
function About.readVersion(root)
  local ok, text = pcall(function()
    local file = assert(io.open(app.fs.joinPath(root, "package.json"), "r"))
    local content = file:read("a")
    file:close()
    return content
  end)
  if not ok or type(text) ~= "string" then return nil end
  return text:match('"version"%s*:%s*"([^"]+)"')
end

function About.versionText(ctx)
  return ctx.version and ("Version " .. ctx.version .. " (beta)") or "Beta"
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
  dlg:link { id = "website", text = About.WEBSITE_TEXT, url = About.WEBSITE_URL }
  dlg:newrow()
  dlg:link { id = "github", text = About.GITHUB_TEXT, url = About.GITHUB_URL }
  dlg:separator()
  dlg:button { id = "close", text = "Close", focus = true, onclick = function() dlg:close() end }
  dlg:show { wait = false }
end

return About
