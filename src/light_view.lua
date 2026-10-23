-- Pure geometry for the Light preview: zoom, pan, and conversion between
-- preview (screen) and cel pixel coordinates. The light can be placed
-- anywhere, including outside the object, so the default view leaves room
-- around the image.
local View = {}

View.FIT = 0.55          -- the image fills this share of the preview at zoom 1
View.MIN_ZOOM = 0.1
View.MAX_ZOOM = 32
View.ZOOM_STEP = 1.25

function View.new()
  return { zoom = 1, panX = 0, panY = 0 }
end

function View.reset(view)
  view.zoom, view.panX, view.panY = 1, 0, 0
end

-- Returns { scale, originX, originY }: screen = origin + cel * scale.
function View.transform(view, canvasW, canvasH, imageW, imageH)
  local fit = math.min(canvasW * View.FIT / math.max(1, imageW), canvasH * View.FIT / math.max(1, imageH))
  local scale = fit * view.zoom
  return {
    scale = scale,
    originX = (canvasW - imageW * scale) / 2 + view.panX,
    originY = (canvasH - imageH * scale) / 2 + view.panY,
  }
end

function View.toCel(t, sx, sy)
  return (sx - t.originX) / t.scale, (sy - t.originY) / t.scale
end

function View.toScreen(t, cx, cy)
  return t.originX + cx * t.scale, t.originY + cy * t.scale
end

-- Zooms by `steps` (positive = out, like a wheel moving down) keeping the
-- cel point under (sx, sy) fixed.
function View.zoomAt(view, canvasW, canvasH, imageW, imageH, sx, sy, steps)
  local before = View.transform(view, canvasW, canvasH, imageW, imageH)
  local cx, cy = View.toCel(before, sx, sy)
  local zoom = view.zoom * (View.ZOOM_STEP ^ (-steps))
  view.zoom = math.max(View.MIN_ZOOM, math.min(View.MAX_ZOOM, zoom))
  local after = View.transform(view, canvasW, canvasH, imageW, imageH)
  local nx, ny = View.toScreen(after, cx, cy)
  view.panX = view.panX + (sx - nx)
  view.panY = view.panY + (sy - ny)
end

function View.pan(view, dx, dy)
  view.panX, view.panY = view.panX + dx, view.panY + dy
end

return View
