local M = {}

-- Box-drawing characters for table borders
-- Using Unicode box-drawing block (U+2500-U+257F)
M.border = {
  -- Horizontal and vertical lines
  horizontal = "─",
  vertical = "│",
  -- Corners
  top_left = "┌",
  top_right = "┐",
  bottom_left = "└",
  bottom_right = "┘",
  -- T-junctions
  top_tee = "┬",
  bottom_tee = "┴",
  left_tee = "├",
  right_tee = "┤",
  -- Cross
  cross = "┼",
}

--- Truncate a string to a maximum length with ellipsis
--- @param str string The string to truncate
--- @param max_len number Maximum length including ellipsis
--- @return string The truncated string
function M.truncate(str, max_len)
  local display_width = vim.fn.strdisplaywidth(str)
  if display_width <= max_len then
    return str
  end
  if max_len <= 3 then
    return string.rep(".", max_len)
  end

  -- Binary search for the right byte position to truncate at
  local low, high = 1, #str
  local best_pos = 1

  while low <= high do
    local mid = math.floor((low + high) / 2)
    local substr = str:sub(1, mid)
    local width = vim.fn.strdisplaywidth(substr)

    if width <= max_len - 3 then
      best_pos = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end

  return str:sub(1, best_pos) .. "..."
end

--- Pad a string to the right with spaces
--- @param str string The string to pad
--- @param len number Target length after padding
--- @return string The padded string
function M.pad_right(str, len)
  local display_width = vim.fn.strdisplaywidth(str)
  if display_width > len then
    return M.truncate(str, len)
  end
  return str .. string.rep(" ", len - display_width)
end

--- Format a duration in milliseconds for display
--- @param ms number Duration in milliseconds
--- @return string Formatted duration string (e.g., "500ms", "2.50s", "2m 5s")
function M.format_duration(ms)
  if ms < 1000 then
    return string.format("%dms", ms)
  elseif ms < 60000 then
    return string.format("%.2fs", ms / 1000)
  else
    local minutes = math.floor(ms / 60000)
    local seconds = math.floor((ms % 60000) / 1000)
    return string.format("%dm %ds", minutes, seconds)
  end
end

--- Format a row count for display
--- @param count number Number of rows
--- @return string Formatted row count (e.g., "1 row" or "1,234,567 rows")
function M.format_row_count(count)
  local formatted = tostring(count):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  formatted = formatted:gsub("^,", "")

  if count == 1 then
    return "1 row"
  end
  return formatted .. " rows"
end

--- Calculate column widths based on headers and data
--- @param columns table Array of column names
--- @param rows table Array of row arrays
--- @param max_width number Maximum width for any column (default 50)
--- @return table Array of column widths
function M.calculate_column_widths(columns, rows, max_width)
  max_width = max_width or 50
  local widths = {}

  for i, col in ipairs(columns) do
    widths[i] = vim.fn.strdisplaywidth(col)
  end

  for _, row in ipairs(rows) do
    for i = 1, #widths do
      local cell = row[i]
      local cell_str = cell == nil and "NULL" or tostring(cell)
      local cell_len = vim.fn.strdisplaywidth(cell_str)
      if cell_len > widths[i] then
        widths[i] = math.min(cell_len, max_width)
      end
    end
  end

  return widths
end

--- Format a row with proper column widths and padding
--- @param row table Array of cell values
--- @param widths table Array of column widths
--- @return string Formatted row string
function M.format_row(row, widths)
  local cells = {}
  for i = 1, #widths do
    local cell = row[i]
    local cell_str = cell == nil and "NULL" or tostring(cell)
    local width = widths[i]
    local cell_width = vim.fn.strdisplaywidth(cell_str)
    if cell_width > width then
      cell_str = M.truncate(cell_str, width)
    end
    table.insert(cells, M.pad_right(cell_str, width))
  end
  return M.border.vertical .. " " .. table.concat(cells, " " .. M.border.vertical .. " ") .. " " .. M.border.vertical
end

--- Create the top border line
--- @param widths table Array of column widths
--- @return string Top border line string
function M.create_top_border(widths)
  local parts = {}
  for _, width in ipairs(widths) do
    table.insert(parts, string.rep(M.border.horizontal, width + 2))
  end
  return M.border.top_left .. table.concat(parts, M.border.top_tee) .. M.border.top_right
end

--- Create a separator line between header and data rows
--- @param widths table Array of column widths
--- @return string Separator line string
function M.create_separator(widths)
  local parts = {}
  for _, width in ipairs(widths) do
    table.insert(parts, string.rep(M.border.horizontal, width + 2))
  end
  return M.border.left_tee .. table.concat(parts, M.border.cross) .. M.border.right_tee
end

--- Create the bottom border line
--- @param widths table Array of column widths
--- @return string Bottom border line string
function M.create_bottom_border(widths)
  local parts = {}
  for _, width in ipairs(widths) do
    table.insert(parts, string.rep(M.border.horizontal, width + 2))
  end
  return M.border.bottom_left .. table.concat(parts, M.border.bottom_tee) .. M.border.bottom_right
end

return M
