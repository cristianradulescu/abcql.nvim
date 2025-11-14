---@class abcql.export.TSV
local TSV = {}

--- Sanitize a TSV field value by removing tabs and newlines
--- @param value string The value to sanitize
--- @return string The sanitized value
local function sanitize_tsv_field(value)
  -- Convert to string if not already
  local str = tostring(value or "")

  -- Replace tabs with spaces
  str = str:gsub("\t", " ")

  -- Replace newlines with spaces
  str = str:gsub("[\n\r]", " ")

  return str
end

--- Format a row as TSV
--- @param row table Array of values
--- @param field_count number Number of fields expected
--- @return string TSV formatted row
local function format_tsv_row(row, field_count)
  local fields = {}
  for i = 1, field_count do
    local value = row[i]
    table.insert(fields, sanitize_tsv_field(value))
  end
  return table.concat(fields, "\t")
end

--- Export QueryResult to TSV format
--- @param results QueryResult The query results to export
--- @return string[]? lines Array of TSV lines, or nil if error
--- @return string? error Error message if failed
function TSV.export(results)
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
  table.insert(lines, format_tsv_row(results.headers, field_count))

  -- Add data rows
  for _, row in ipairs(results.rows) do
    table.insert(lines, format_tsv_row(row, field_count))
  end

  return lines, nil
end

return TSV
