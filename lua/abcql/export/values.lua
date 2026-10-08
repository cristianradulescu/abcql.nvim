---@class abcql.export.Values
local Values = {}

--- Whether a value is safe to emit as an unquoted SQL number (no leading zeros, so "007" stays a string)
--- @param value string
--- @return boolean
function Values.is_number(value)
  return value:match("^-?[1-9]%d*%.?%d*$") ~= nil or value:match("^-?0%.?%d*$") ~= nil and value:match("^-?0%d") == nil
end

--- Format every value of the results as one comma-separated line, for pasting into `IN (...)`
--- (use it on a column slice). NULLs are skipped. Numbers are left bare when every value is
--- numeric, otherwise all values are single-quoted with `'` doubled.
--- @param results QueryResult
--- @return string[]|nil lines
--- @return string|nil err
function Values.export(results)
  if not results or not results.headers or not results.rows then
    return nil, "Invalid results data"
  end

  local values = {}
  local numeric = true
  for _, row in ipairs(results.rows) do
    for i = 1, #results.headers do
      local cell = row[i]
      if cell ~= nil and cell ~= vim.NIL and tostring(cell) ~= "NULL" then
        local str = tostring(cell)
        table.insert(values, str)
        numeric = numeric and Values.is_number(str)
      end
    end
  end

  if #values == 0 then
    return nil, "No non-NULL values"
  end

  if not numeric then
    for i, str in ipairs(values) do
      values[i] = "'" .. str:gsub("'", "''") .. "'"
    end
  end
  return { table.concat(values, ", ") }
end

return Values
