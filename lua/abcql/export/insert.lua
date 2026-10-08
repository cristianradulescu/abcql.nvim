---@class abcql.export.Insert
local Insert = {}

local Values = require("abcql.export.values")

--- Placeholder used when the table the rows belong to can't be told from the query
Insert.PLACEHOLDER = "<table>"

--- SQL literal for a cell: NULL, a bare number or BLOB hex (`0xCAFE`), otherwise a quoted string
--- @param value any
--- @param adapter abcql.db.adapter.Adapter|nil
--- @return string
function Insert.literal(value, adapter)
  if value == nil or value == vim.NIL or tostring(value) == "NULL" then
    return "NULL"
  end
  local str = tostring(value)
  if Values.is_number(str) or str:match("^0x%x+$") then
    return str
  end
  -- MySQL treats backslash as an escape character inside strings; SQLite doesn't
  if not (adapter and adapter.ENGINE == "sqlite") then
    str = str:gsub("\\", "\\\\")
  end
  str = adapter and adapter:escape_value(str) or str:gsub("'", "''")
  return "'" .. str .. "'"
end

--- Format the results as a single multi-row `INSERT INTO ... VALUES ...;` statement. The table is
--- `ctx.table` when the query read exactly one table, otherwise a `<table>` placeholder to fill in
--- (handy to load joined data into a new table). Column names are the result headers.
--- @param results QueryResult
--- @param ctx? { table: string?, adapter: abcql.db.adapter.Adapter? }
--- @return string[]|nil lines
--- @return string|nil err
function Insert.export(results, ctx)
  if not results or not results.headers or not results.rows then
    return nil, "Invalid results data"
  end
  if #results.rows == 0 then
    return nil, "No rows to insert"
  end
  ctx = ctx or {}
  local adapter = ctx.adapter
  local function ident(name)
    return adapter and adapter:escape_identifier(name) or name
  end

  local columns = {}
  for i, header in ipairs(results.headers) do
    columns[i] = ident(tostring(header))
  end

  local lines = {
    string.format(
      "INSERT INTO %s (%s)",
      ctx.table and ident(ctx.table) or Insert.PLACEHOLDER,
      table.concat(columns, ", ")
    ),
    "VALUES",
  }
  for r, row in ipairs(results.rows) do
    local cells = {}
    for i = 1, #results.headers do
      cells[i] = Insert.literal(row[i], adapter)
    end
    table.insert(lines, "  (" .. table.concat(cells, ", ") .. ")" .. (r < #results.rows and "," or ";"))
  end
  return lines
end

return Insert
