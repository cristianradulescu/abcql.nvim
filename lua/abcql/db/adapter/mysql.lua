local Adapter = require("abcql.db.adapter.base")
local Query = require("abcql.db.query")

---@class abcql.db.adapter.MySQLAdapter: abcql.db.adapter.Adapter
local MySQLAdapter = {}
MySQLAdapter.__index = MySQLAdapter
setmetatable(MySQLAdapter, { __index = Adapter })

--- Create a new MySQL adapter instance
--- @param config AdapterConfig Configuration parameters for the adapter
--- @return table The adapter instance
function MySQLAdapter.new(config)
  local self = Adapter.new(config)
  return setmetatable(self, MySQLAdapter)
end

--- Get the MySQL CLI command name
--- @return string The command name "mysql"
function MySQLAdapter:get_command()
  return "mysql"
end

--- Get CLI arguments for MySQL query execution
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (skip_column_names: boolean, database: string)
--- @return table Array of command-line arguments for mysql CLI
function MySQLAdapter:get_args(query, opts)
  opts = opts or {}
  local args = {
    "-h" .. (self.config.host or "localhost"),
    "-P" .. tostring(self.config.port or 3306),
    "-u" .. (self.config.user or "root"),
  }

  if self.config.password then
    table.insert(args, "-p" .. self.config.password)
  end

  -- Use opts.database if provided, otherwise fall back to config.database
  local database = opts.database or self.config.database
  if database then
    table.insert(args, "-D" .. database)
  end

  table.insert(args, "--batch")
  table.insert(args, "--default-character-set=utf8mb4")

  if self:is_write_query(query) then
    -- Use -vvv to force table output format even in batch mode
    -- This ensures we get "Query OK, X rows affected" messages for write queries
    table.insert(args, "-vvv")
  end

  if opts.skip_column_names then
    table.insert(args, "--skip-column-names")
  end

  table.insert(args, "-e")
  table.insert(args, query)

  return args
end

--- Execute a query with possible asynchronous callback
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (adapter-specific)
--- @param callback function Called with (results, error) where results is structured data
function MySQLAdapter:execute_query(query, opts, callback)
  if callback == nil then
    return Query.execute_sync(self, query, opts)
  end

  return Query.execute_async(self, query, callback, opts)
end

--- Detect if a query is a write operation (INSERT, UPDATE, DELETE)
--- @param query string The SQL query
--- @return boolean True if the query is a write operation
function MySQLAdapter:is_write_query(query)
  local query_upper = query:upper():match("^%s*(%u+)")
  return query_upper == "INSERT" or query_upper == "UPDATE" or query_upper == "DELETE"
end

--- Parse MySQL write query output to extract affected rows information
--- @param raw string Raw output from mysql CLI for write queries
--- @return table Result object with affected_rows, matched_rows, changed_rows, warnings
function MySQLAdapter:parse_write_output(raw)
  local result = {
    affected_rows = 0,
    matched_rows = 0,
    changed_rows = 0,
    warnings = 0,
  }

  -- Parse "Query OK, X rows affected" line
  local affected = raw:match("(%d+)%s+rows?%s+affected")
  if affected then
    result.affected_rows = tonumber(affected) or 0
  end

  -- Parse "Rows matched: X  Changed: Y  Warnings: Z" line
  local matched = raw:match("Rows matched:%s*(%d+)")
  if matched then
    result.matched_rows = tonumber(matched) or 0
  end

  local changed = raw:match("Changed:%s*(%d+)")
  if changed then
    result.changed_rows = tonumber(changed) or 0
  end

  local warnings = raw:match("Warnings:%s*(%d+)")
  if warnings then
    result.warnings = tonumber(warnings) or 0
  end

  return result
end

--- Parse MySQL tab-separated output into rows
--- @param raw string Raw tab-separated output from mysql CLI
--- @return table Array of rows, where each row is an array of field values
function MySQLAdapter:parse_output(raw)
  local rows = {}
  for line in raw:gmatch("[^\r\n]+") do
    local row = {}
    for field in line:gmatch("[^\t]+") do
      table.insert(row, field)
    end
    table.insert(rows, row)
  end
  return rows
end

--- Fetch list of all databases asynchronously
--- @param callback function Called with (databases, error) where databases is array of database names
function MySQLAdapter:get_databases(callback)
  local query = "SHOW DATABASES like '" .. self.config.database .. "'"
  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local databases = {}
    for _, row in ipairs(result.rows) do
      if row[1] then
        table.insert(databases, row[1])
      end
    end

    callback(databases, nil)
  end, { skip_column_names = true })
end

--- Fetch list of tables in a database asynchronously
--- @param database string Database name
--- @param callback function Called with (tables, error) where tables is array of table names
function MySQLAdapter:get_tables(database, callback)
  local query = string.format(
    "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='%s'",
    self:escape_value(database)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local tables = {}
    for _, row in ipairs(result.rows) do
      if row[1] then
        table.insert(tables, row[1])
      end
    end

    callback(tables, nil)
  end, { skip_column_names = true })
end

--- Fetch list of columns in a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (columns, error) where columns is array of {name, type} tables
function MySQLAdapter:get_columns(database, table_name, callback)
  local query = string.format(
    "SELECT COLUMN_NAME, COLUMN_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s'",
    self:escape_value(database),
    self:escape_value(table_name)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local columns = {}
    for _, row in ipairs(result.rows) do
      if row[1] and row[2] then
        table.insert(columns, { name = row[1], type = row[2] })
      end
    end

    callback(columns, nil)
  end, { skip_column_names = true })
end

--- Fetch constraints for a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (constraints, error) where constraints is { primary_key: string[], foreign_keys: {column, ref_table, ref_column}[] }
function MySQLAdapter:get_constraints(database, table_name, callback)
  local query = string.format(
    [[SELECT
      kcu.COLUMN_NAME,
      tc.CONSTRAINT_TYPE,
      kcu.REFERENCED_TABLE_NAME,
      kcu.REFERENCED_COLUMN_NAME
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
    JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
      ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
      AND kcu.TABLE_NAME = tc.TABLE_NAME
    WHERE kcu.TABLE_SCHEMA='%s' AND kcu.TABLE_NAME='%s'
    ORDER BY tc.CONSTRAINT_TYPE, kcu.ORDINAL_POSITION]],
    self:escape_value(database),
    self:escape_value(table_name)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local constraints = {
      primary_key = {},
      foreign_keys = {},
    }

    for _, row in ipairs(result.rows) do
      local column_name = row[1]
      local constraint_type = row[2]
      local ref_table = row[3]
      local ref_column = row[4]

      if constraint_type == "PRIMARY KEY" then
        table.insert(constraints.primary_key, column_name)
      elseif constraint_type == "FOREIGN KEY" and ref_table and ref_column then
        table.insert(constraints.foreign_keys, {
          column = column_name,
          ref_table = ref_table,
          ref_column = ref_column,
        })
      end
    end

    callback(constraints, nil)
  end, { skip_column_names = true })
end

--- Fetch indexes for a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (indexes, error) where indexes is array of { name: string, columns: string[], unique: boolean }
function MySQLAdapter:get_indexes(database, table_name, callback)
  local query = string.format(
    [[SELECT
      INDEX_NAME,
      COLUMN_NAME,
      NON_UNIQUE,
      SEQ_IN_INDEX
    FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA='%s' AND TABLE_NAME='%s'
    ORDER BY INDEX_NAME, SEQ_IN_INDEX]],
    self:escape_value(database),
    self:escape_value(table_name)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    -- Group columns by index name
    local index_map = {}
    local index_order = {}

    for _, row in ipairs(result.rows) do
      local index_name = row[1]
      local column_name = row[2]
      local non_unique = row[3]

      if not index_map[index_name] then
        index_map[index_name] = {
          name = index_name,
          columns = {},
          unique = non_unique == "0",
        }
        table.insert(index_order, index_name)
      end

      table.insert(index_map[index_name].columns, column_name)
    end

    -- Convert to array preserving order
    local indexes = {}
    for _, name in ipairs(index_order) do
      table.insert(indexes, index_map[name])
    end

    callback(indexes, nil)
  end, { skip_column_names = true })
end

--- Escape a MySQL identifier using backticks
--- @param name string The identifier to escape
--- @return string The escaped identifier with backticks
function MySQLAdapter:escape_identifier(name)
  return "`" .. name:gsub("`", "``") .. "`"
end

--- Escape a value for MySQL queries by escaping single quotes
--- @param value string The value to escape
--- @return string The escaped value
function MySQLAdapter:escape_value(value)
  return value:gsub("'", "''")
end

return MySQLAdapter
