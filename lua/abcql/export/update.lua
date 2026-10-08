---@class abcql.export.Update
local Update = {}

local Insert = require("abcql.export.insert")

--- Format the results as one `UPDATE ... SET ... WHERE ...;` statement per row. The columns at
--- `ctx.key_indices` (chosen by the user) form the WHERE condition, joined with AND, and are left
--- out of SET; a NULL key becomes `IS NULL`. The table is `ctx.table` when the query read exactly
--- one, otherwise the `<table>` placeholder.
--- @param results QueryResult
--- @param ctx? { table: string?, adapter: abcql.db.adapter.Adapter?, key_indices: integer[]? }
--- @return string[]|nil lines
--- @return string|nil err
function Update.export(results, ctx)
  if not results or not results.headers or not results.rows then
    return nil, "Invalid results data"
  end
  ctx = ctx or {}
  local keys, key_order = {}, {}
  for _, idx in ipairs(ctx.key_indices or {}) do
    if not results.headers[idx] then
      return nil, "No WHERE column selected"
    end
    if not keys[idx] then
      keys[idx] = true
      table.insert(key_order, idx)
    end
  end
  if #key_order == 0 then
    return nil, "No WHERE column selected"
  end
  if #key_order >= #results.headers then
    return nil, "Nothing to update besides the WHERE columns"
  end
  if #results.rows == 0 then
    return nil, "No rows to update"
  end

  local adapter = ctx.adapter
  local function ident(name)
    return adapter and adapter:escape_identifier(name) or name
  end

  local target = ctx.table and ident(ctx.table) or Insert.PLACEHOLDER
  local lines = {}
  for _, row in ipairs(results.rows) do
    local sets = {}
    for i, header in ipairs(results.headers) do
      if not keys[i] then
        table.insert(sets, string.format("%s = %s", ident(tostring(header)), Insert.literal(row[i], adapter)))
      end
    end
    local conditions = {}
    for _, idx in ipairs(key_order) do
      local name = ident(tostring(results.headers[idx]))
      local value = Insert.literal(row[idx], adapter)
      table.insert(conditions, value == "NULL" and (name .. " IS NULL") or string.format("%s = %s", name, value))
    end
    table.insert(
      lines,
      string.format("UPDATE %s SET %s WHERE %s;", target, table.concat(sets, ", "), table.concat(conditions, " AND "))
    )
  end
  return lines
end

return Update
