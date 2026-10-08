---@class abcql.export.Rows
local Rows = {}

--- Format every value of the results on its own line, row by row (use it on a column slice for a
--- plain list). NULLs are skipped and each run of newlines/carriage returns inside a value becomes one space, so
--- one value is always one line.
--- @param results QueryResult
--- @return string[]|nil lines
--- @return string|nil err
function Rows.export(results)
  if not results or not results.headers or not results.rows then
    return nil, "Invalid results data"
  end

  local lines = {}
  for _, row in ipairs(results.rows) do
    for i = 1, #results.headers do
      local cell = row[i]
      if cell ~= nil and cell ~= vim.NIL and tostring(cell) ~= "NULL" then
        table.insert(lines, (tostring(cell):gsub("[\r\n]+", " ")))
      end
    end
  end

  if #lines == 0 then
    return nil, "No non-NULL values"
  end
  return lines
end

return Rows
