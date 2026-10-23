-- Pure geometry for the swatch grid (logical, unscaled pixels).
-- Same cell size and separators as Aseprite's palette; rows scroll
-- vertically. The grid never resizes the window.
local Grid = {}

-- Swatches match Aseprite's own palette: color_bar.box_size (default 11) and,
-- when color_bar.entries_separator is on, a 1px dark line between cells.
Grid.BOX = 11             -- default box size when the preference is missing
Grid.TOOLBAR_H = 14
Grid.RIGHT_PAD = 3        -- room for the scroll thumb
Grid.MIN_CELL = 5
Grid.DEFAULT_ROWS = 16    -- rows visible in a new window
Grid.MIN_ROWS = 4
Grid.ICON = 12            -- toolbar icon button size

function Grid.baseIndex(count)
  return count == 5 and 3 or 2
end

-- Width of the swatch block for a box size (used as the canvas width).
function Grid.naturalWidth(count, box, line)
  box, line = box or Grid.BOX, line or 1
  return count * box + (count + 1) * line + Grid.RIGHT_PAD
end
Grid.WIDTH = Grid.naturalWidth(3)

-- Column geometry. Cells keep the native box size; they only shrink when the
-- canvas is narrower than that (never grow). The block is centered.
function Grid.layout(width, count, box, line)
  box, line = box or Grid.BOX, line or 1
  local avail = width - Grid.RIGHT_PAD
  local cell = box
  if count * cell + (count + 1) * line > avail then
    cell = math.max(Grid.MIN_CELL, math.floor((avail - (count + 1) * line) / count))
  end
  local blockWidth = count * cell + (count + 1) * line
  local x0 = math.max(0, math.floor((avail - blockWidth) / 2))
  local columns = {}
  for i = 1, count do columns[i] = { x = x0 + line + (i - 1) * (cell + line), width = cell } end
  return {
    cell = cell, line = line, rowH = cell + line, columns = columns, count = count,
    left = x0, blockWidth = blockWidth, right = x0 + blockWidth,
  }
end

-- Initial canvas height for a new window (never applied afterwards).
function Grid.initialHeight(rowCount, count, box, line)
  box, line = box or Grid.BOX, line or 1
  local rows = math.max(Grid.MIN_ROWS, math.min(rowCount, Grid.DEFAULT_ROWS))
  return Grid.TOOLBAR_H + rows * (box + line) + line
end

function Grid.contentHeight(layout, rowCount, top)
  return (top or 0) + rowCount * layout.rowH + layout.line
end

function Grid.maxScroll(layout, height, rowCount, top)
  return math.max(0, Grid.contentHeight(layout, rowCount, top) - height)
end

function Grid.rowTop(layout, rowIndex, scroll, top)
  return (top or 0) + layout.line + (rowIndex - 1) * layout.rowH - scroll
end

function Grid.visibleRange(layout, height, rowCount, scroll, top)
  top = top or 0
  local first = math.max(1, math.floor(scroll / layout.rowH) + 1)
  local last = math.min(rowCount, math.ceil((scroll + height - top) / layout.rowH))
  return first, last
end

-- Returns rowIndex, columnIndex for a point, or nil. Gaps belong to the cell
-- on their left/above so the whole grid is clickable.
function Grid.hit(layout, rowCount, scroll, x, y, top)
  top = top or 0
  if y < top or rowCount == 0 then return nil end
  local row = math.floor((y - top - layout.line + scroll) / layout.rowH) + 1
  if row < 1 or row > rowCount then return nil end
  local columns = layout.columns
  for i, column in ipairs(columns) do
    local nextX = columns[i + 1] and columns[i + 1].x or (column.x + column.width + layout.line)
    if x >= (i == 1 and 0 or column.x) and x < nextX then return row, i end
  end
  return nil
end

-- Two icon buttons: Light and the "..." menu. Right-aligned when there is
-- room; at extreme widths they stay at the left edge instead of clipping.
-- At the native box size the block (3 shades: 3*11+4+3 = 40px) is wide
-- enough for both icons (25px).
function Grid.toolbar(width)
  local size, gap = Grid.ICON, 1
  local needed = size * 2 + gap
  local x = width - needed - 1
  if x < 1 then x = 1 end
  return {
    { id = "light", x = x, y = 1, width = size, height = size },
    { id = "menu", x = x + size + gap, y = 1, width = size, height = size },
  }
end

function Grid.toolbarHit(width, x, y)
  for _, item in ipairs(Grid.toolbar(width)) do
    if x >= item.x and x < item.x + item.width and y >= item.y and y < item.y + item.height then
      return item.id
    end
  end
  return nil
end

return Grid
