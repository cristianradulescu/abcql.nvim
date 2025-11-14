---@class abcql.export.CSV
local CSV = {}

--- Escape a CSV field value according to RFC 4180
--- @param value string The value to escape
--- @return string The escaped value
local function escape_csv_field(value)
  -- Convert to string if not already
  local str = tostring(value or "")

  -- If the field contains comma, double quote, or newline, wrap in quotes and escape quotes
  if str:match('[,"\n\r]') then
    -- Escape double quotes by doubling them
    str = str:gsub('"', '""')
    -- Wrap in double quotes
    return '"' .. str .. '"'
  end

  return str
end

--- Format a row as CSV
--- @param row table Array of values
--- @param field_count number Number of fields expected
--- @return string CSV formatted row
local function format_csv_row(row, field_count)
  local fields = {}
  for i = 1, field_count do
    local value = row[i]
    table.insert(fields, escape_csv_field(value))
  end
  return table.concat(fields, ",")
end

--- Export QueryResult to CSV format
--- @param results QueryResult The query results to export
--- @return string[]? lines Array of CSV lines, or nil if error
--- @return string? error Error message if failed
function CSV.export(results)
  -- Validate input
  if not results then
    return nil, "No results to export"
  end

  if type(results) ~= "table" then
    return nil, "Invalid results format"
  end

  -- Check if results has headers
  if not results.headers or type(results.headers) ~= "table" then
    return nil, "Results missing headers"
  end

  -- Check if results has rows
  if not results.rows or type(results.rows) ~= "table" then
    return nil, "Results missing rows"
  end

  local lines = {}
  local field_count = #results.headers

  -- Add header row
  table.insert(lines, format_csv_row(results.headers, field_count))

  -- Add data rows
  for _, row in ipairs(results.rows) do
    table.insert(lines, format_csv_row(row, field_count))
  end

  return lines, nil
end

return CSV
