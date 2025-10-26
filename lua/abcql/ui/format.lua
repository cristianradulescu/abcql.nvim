local M = {}

--- Truncate a string to a maximum length with ellipsis
--- @param str string The string to truncate
--- @param max_len number Maximum length including ellipsis
--- @return string The truncated string
function M.truncate(str, max_len)
  if #str <= max_len then
    return str
  end
  if max_len <= 3 then
    return string.rep(".", max_len)
  end
  return str:sub(1, max_len - 3) .. "..."
end

--- Pad a string to the right with spaces
--- @param str string The string to pad
--- @param len number Target length after padding
--- @return string The padded string
function M.pad_right(str, len)
  if #str > len then
    return str:sub(1, len)
  end
  return str .. string.rep(" ", len - #str)
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
    widths[i] = #col
  end

  for _, row in ipairs(rows) do
    for i = 1, #widths do
      local cell = row[i]
      local cell_str = cell == nil and "NULL" or tostring(cell)
      local cell_len = #cell_str
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
    if #cell_str > width then
      cell_str = M.truncate(cell_str, width)
    end
    table.insert(cells, M.pad_right(cell_str, width))
  end
  return " " .. table.concat(cells, " | ") .. " "
end

--- Create a separator line
--- @param widths table Array of column widths
--- @return string Separator line string
function M.create_separator(widths)
  local parts = {}
  for _, width in ipairs(widths) do
    table.insert(parts, string.rep("-", width))
  end
  return "-" .. table.concat(parts, "-+-") .. "-"
end

return M
