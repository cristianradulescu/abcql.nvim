--- Follow a foreign key from a result cell: find the FK the cell's column belongs to (through
--- the tables of the query that produced the result and the LSP schema cache) and build the
--- `SELECT * FROM ref_table WHERE ref_col = <value>` that shows the referenced row.
local Parser = require("abcql.lsp.parser")

---@class abcql.db.Follow
local Follow = {}

---@class abcql.FollowTarget
---@field database string Database of the referencing table
---@field table string Referencing table
---@field ref_database string Database of the referenced table
---@field ref_table string Referenced table
---@field columns string[] FK columns (composite keys keep all of them)
---@field ref_columns string[] Referenced columns, in the same order
---@field col_indices number[] Result column index of each FK column

local NUMERIC_TYPE = { "int", "dec", "numeric", "float", "double", "real" }

--- Tables of a statement found in the schema cache, preferring the result's database
---@param cache abcql.lsp.Cache
---@param datasource_name string
---@param database string|nil
---@param sql string
---@return { database: string, name: string }[]
local function statement_tables(cache, datasource_name, database, sql)
  local found = {}
  for _, name in ipairs(Parser.extract_table_names(sql)) do
    local db, real = nil, nil
    if database then
      db, real = cache:find_table(datasource_name, name, database)
    end
    if not db then
      db, real = cache:find_table(datasource_name, name)
    end
    if db then
      table.insert(found, { database = db, name = real })
    end
  end
  return found
end

--- Index of a header (case-insensitive), preferring `preferred` when it matches
---@param headers string[]
---@param column string
---@param preferred number
---@return number|nil
local function header_index(headers, column, preferred)
  local wanted = column:lower()
  if headers[preferred] and headers[preferred]:lower() == wanted then
    return preferred
  end
  for i, header in ipairs(headers) do
    if header:lower() == wanted then
      return i
    end
  end
  return nil
end

--- Foreign keys that the result column `col_idx` is part of. A composite key qualifies only
--- when all of its columns are in the result. Keys of different tables that point at the same
--- referenced columns are listed once.
---@param cache abcql.lsp.Cache
---@param datasource_name string
---@param database string|nil Database the query ran in
---@param sql string Query that produced the result
---@param headers string[]
---@param col_idx number
---@return abcql.FollowTarget[]
function Follow.targets(cache, datasource_name, database, sql, headers, col_idx)
  local header = headers[col_idx]
  if not header or not sql then
    return {}
  end
  header = header:lower()

  local targets, seen = {}, {}
  for _, tbl in ipairs(statement_tables(cache, datasource_name, database, sql)) do
    local constraints = cache:get_constraints(datasource_name, tbl.database, tbl.name)
    local groups, order = {}, {}
    for i, fk in ipairs(constraints and constraints.foreign_keys or {}) do
      local key = fk.constraint or (fk.ref_table .. "#" .. i)
      if not groups[key] then
        groups[key] = { ref_table = fk.ref_table, columns = {}, ref_columns = {} }
        table.insert(order, key)
      end
      table.insert(groups[key].columns, fk.column)
      table.insert(groups[key].ref_columns, fk.ref_column)
    end

    for _, key in ipairs(order) do
      local group = groups[key]
      local has_header, indices = false, {}
      for _, column in ipairs(group.columns) do
        has_header = has_header or column:lower() == header
        table.insert(indices, header_index(headers, column, col_idx))
      end
      local ref_db, ref_table = cache:find_table(datasource_name, group.ref_table, tbl.database)
      if not ref_db then
        ref_db, ref_table = tbl.database, group.ref_table
      end
      local id = (ref_db .. "." .. ref_table .. "(" .. table.concat(group.ref_columns, ",") .. ")"):lower()
      if has_header and #indices == #group.columns and not seen[id] then
        seen[id] = true
        table.insert(targets, {
          database = tbl.database,
          table = tbl.name,
          ref_database = ref_db,
          ref_table = ref_table,
          columns = group.columns,
          ref_columns = group.ref_columns,
          col_indices = indices,
        })
      end
    end
  end
  return targets
end

--- Whether a cached column type is numeric
---@param type_name string|nil
---@return boolean
local function is_numeric_type(type_name)
  type_name = (type_name or ""):lower()
  for _, prefix in ipairs(NUMERIC_TYPE) do
    if type_name:find(prefix, 1, true) then
      return true
    end
  end
  return false
end

--- SQL literal for a cell value: bare for a number in a numeric column, quoted otherwise
---@param adapter abcql.db.adapter.Adapter
---@param value string
---@param numeric boolean
---@return string
local function literal(adapter, value, numeric)
  if numeric and value:match("^%-?%d+%.?%d*$") then
    return value
  end
  return "'" .. (adapter:escape_value(value)) .. "'"
end

--- The SELECT showing the row a foreign key points at
---@param cache abcql.lsp.Cache
---@param datasource Datasource
---@param target abcql.FollowTarget
---@param row table Result row
---@return string|nil sql
---@return string|nil err
function Follow.build_sql(cache, datasource, target, row)
  local adapter = datasource.adapter
  local ref_types = {}
  for _, col in ipairs(cache:get_columns(datasource.name, target.ref_database, target.ref_table) or {}) do
    ref_types[col.name:lower()] = col.type
  end

  local conditions = {}
  for i, ref_column in ipairs(target.ref_columns) do
    local value = row[target.col_indices[i]]
    if value == nil or value == vim.NIL or value == "NULL" then
      return nil, string.format("%s is NULL, it references nothing", target.columns[i])
    end
    local numeric = is_numeric_type(ref_types[ref_column:lower()])
    table.insert(
      conditions,
      string.format("%s = %s", adapter:escape_identifier(ref_column), literal(adapter, tostring(value), numeric))
    )
  end

  local name = adapter:escape_identifier(target.ref_table)
  local current = adapter.config and adapter.config.database
  if not current or current:lower() ~= target.ref_database:lower() then
    name = adapter:escape_identifier(target.ref_database) .. "." .. name
  end
  return string.format("SELECT * FROM %s WHERE %s", name, table.concat(conditions, " AND ")), nil
end

--- Label of a target in the picker: `orders.customer_id → customers.id`
---@param target abcql.FollowTarget
---@return string
function Follow.label(target)
  local function cols(list)
    return #list == 1 and list[1] or "(" .. table.concat(list, ", ") .. ")"
  end
  return string.format(
    "%s.%s → %s.%s",
    target.table,
    cols(target.columns),
    target.ref_table,
    cols(target.ref_columns)
  )
end

--- Follow the foreign key of a result cell: run the SELECT of the referenced row through
--- `Query.run` (so it lands in history and `<C-o>` goes back). Asks which key to follow when
--- the column matches several.
---@param datasource Datasource
---@param database string|nil Database the result's query ran in
---@param sql string|nil Query that produced the result
---@param results QueryResult
---@param row_idx number
---@param col_idx number
function Follow.follow(datasource, database, sql, results, row_idx, col_idx)
  local function info(msg)
    vim.notify("abcql: " .. msg, vim.log.levels.INFO)
  end

  local LSP = require("abcql.lsp")
  if not LSP.has_schema(datasource.name) then
    info("schema of " .. datasource.name .. " is not loaded (attach a buffer or :AbcqlSchemaRefresh)")
    return
  end
  local cache = LSP.get_cache()
  local header = results.headers[col_idx]
  local targets = Follow.targets(cache, datasource.name, database, sql, results.headers, col_idx)
  if #targets == 0 then
    info(string.format("%s is not a foreign key of the queried tables", header))
    return
  end

  local function run(target)
    local follow_sql, err = Follow.build_sql(cache, datasource, target, results.rows[row_idx])
    if not follow_sql then
      info(err)
      return
    end
    -- A generated single-row SELECT, like the code action's browse
    require("abcql.db.query").run(follow_sql, datasource, { confirm = false })
  end

  if #targets == 1 then
    run(targets[1])
    return
  end
  vim.ui.select(targets, { prompt = "Follow foreign key", format_item = Follow.label }, function(choice)
    if choice then
      run(choice)
    end
  end)
end

return Follow
