-- Pure geometry for the two painted widgets of the Light dialog: the layer
-- list (checkbox per layer) and the frame strip (one row of frames).
-- Logical pixels. Nothing here touches Aseprite.
local Widgets = {}

------------------------------------------------------------------------------
-- Layer list: a header ("all" / "none") followed by one row per layer.
------------------------------------------------------------------------------

local Layers = {}
Widgets.Layers = Layers

Layers.WIDTH = 96
Layers.HEADER_H = 13
Layers.ROW_H = 13
Layers.BOX = 9
Layers.PAD = 3
Layers.SWATCH = 7
Layers.INDENT = 4

function Layers.visibleRows(height)
  return math.max(1, math.floor((height - Layers.HEADER_H) / Layers.ROW_H))
end

function Layers.maxScroll(height, count)
  return math.max(0, count - Layers.visibleRows(height))
end

-- Row index (1-based) of the first visible row for a scroll offset in rows.
function Layers.rowTop(index, scroll)
  return Layers.HEADER_H + (index - 1 - scroll) * Layers.ROW_H
end

-- Hit-test. Returns nil or { kind = "all" | "none" | "box" | "name", index }.
function Layers.hit(width, height, count, scroll, x, y)
  if y < 0 or x < 0 or x >= width then return nil end
  if y < Layers.HEADER_H then
    return { kind = x < width / 2 and "all" or "none" }
  end
  local index = math.floor((y - Layers.HEADER_H) / Layers.ROW_H) + 1 + scroll
  if index < 1 or index > count or y >= height then return nil end
  local boxRight = Layers.PAD + Layers.BOX + 2
  return { kind = x < boxRight and "box" or "name", index = index }
end

-- Keeps a row inside the visible window. Returns the new scroll.
function Layers.scrollToShow(height, count, index, scroll)
  local visible = Layers.visibleRows(height)
  if index - 1 < scroll then scroll = index - 1 end
  if index > scroll + visible then scroll = index - visible end
  return math.max(0, math.min(scroll, Layers.maxScroll(height, count)))
end

------------------------------------------------------------------------------
-- Frame strip: one row of equally sized frame cells, scrolled horizontally.
------------------------------------------------------------------------------

local Frames = {}
Widgets.Frames = Frames

-- Compact like Aseprite's own timeline: the cell is only as wide as the
-- longest frame number needs (the UI measures the text and passes `cell`).
Frames.CELL_W = 14    -- default cell width when none is given
Frames.MIN_CELL_W = 12
Frames.NUM_H = 11     -- height of the numbered row
Frames.HEIGHT = 22    -- numbered row + the row of dots

function Frames.contentWidth(count, cell)
  return count * (cell or Frames.CELL_W)
end

function Frames.maxScroll(width, count, cell)
  return math.max(0, Frames.contentWidth(count, cell) - width)
end

-- First and last frame (1-based) that are at least partly visible.
function Frames.visibleRange(width, count, scroll, cell)
  cell = cell or Frames.CELL_W
  if count < 1 then return 1, 0 end
  local first = math.floor(scroll / cell) + 1
  local last = math.min(count, math.floor((scroll + width - 1) / cell) + 1)
  return math.max(1, first), last
end

function Frames.cellX(index, scroll, cell)
  return (index - 1) * (cell or Frames.CELL_W) - scroll
end

-- Frame under x, or nil.
function Frames.hit(width, count, scroll, x, y, cell)
  cell = cell or Frames.CELL_W
  if x < 0 or x >= width or (y and (y < 0 or y >= Frames.HEIGHT)) then return nil end
  local index = math.floor((x + scroll) / cell) + 1
  if index < 1 or index > count then return nil end
  return index
end

-- Scroll offset (px) that keeps a frame fully visible.
function Frames.scrollToShow(width, count, index, scroll, cell)
  cell = cell or Frames.CELL_W
  local left = (index - 1) * cell
  local right = left + cell
  if left < scroll then scroll = left end
  if right > scroll + width then scroll = right - width end
  return math.max(0, math.min(scroll, Frames.maxScroll(width, count, cell)))
end

-- Wheel steps scroll by one cell.
function Frames.scrollBy(width, count, scroll, steps, cell)
  cell = cell or Frames.CELL_W
  return math.max(0, math.min(scroll + steps * cell, Frames.maxScroll(width, count, cell)))
end

return Widgets
