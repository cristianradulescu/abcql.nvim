local Adapter = require("abcql.db.adapter.base")
local Query = require("abcql.db.query")

---@class abcql.db.adapter.MySQLAdapter: abcql.db.adapter.Adapter
local MySQLAdapter = {}
MySQLAdapter.__index = MySQLAdapter
setmetatable(MySQLAdapter, { __index = Adapter })

--- Engine identifier sent to abcql-backend
MySQLAdapter.ENGINE = "mysql"

--- Create a new MySQL adapter instance
--- @param config AdapterConfig Configuration parameters for the adapter
--- @return table The adapter instance
function MySQLAdapter.new(config)
  local self = Adapter.new(config)
  return setmetatable(self, MySQLAdapter)
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

--- Fetch list of all databases asynchronously
--- @param callback function Called with (databases, error) where databases is array of database names
function MySQLAdapter:get_databases(callback)
  local query = "SHOW DATABASES like '" .. self:escape_value(self.config.database) .. "'"
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
  end)
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
  end)
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
  end)
end

--- Fetch the columns of every table in a database with one query
--- @param database string Database name
--- @param callback fun(columns_by_table: table<string, ColumnInfo[]>|nil, err: string|nil)
function MySQLAdapter:get_all_columns(database, callback)
  local query = string.format(
    "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='%s' ORDER BY TABLE_NAME, ORDINAL_POSITION",
    self:escape_value(database)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local by_table = {}
    for _, row in ipairs(result.rows) do
      if row[1] and row[2] then
        by_table[row[1]] = by_table[row[1]] or {}
        table.insert(by_table[row[1]], { name = row[2], type = row[3] or "" })
      end
    end

    callback(by_table, nil)
  end)
end

--- Fetch primary/foreign key constraints of every table in a database with one query
--- @param database string Database name
--- @param callback fun(constraints_by_table: table<string, { primary_key: string[], foreign_keys: table[] }>|nil, err: string|nil)
function MySQLAdapter:get_all_constraints(database, callback)
  local query = string.format(
    [[SELECT
      kcu.TABLE_NAME,
      kcu.COLUMN_NAME,
      tc.CONSTRAINT_TYPE,
      kcu.REFERENCED_TABLE_NAME,
      kcu.REFERENCED_COLUMN_NAME
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
    JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
      ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
      AND kcu.TABLE_SCHEMA = tc.TABLE_SCHEMA
      AND kcu.TABLE_NAME = tc.TABLE_NAME
    WHERE kcu.TABLE_SCHEMA='%s'
    ORDER BY kcu.TABLE_NAME, tc.CONSTRAINT_TYPE, kcu.ORDINAL_POSITION]],
    self:escape_value(database)
  )

  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local by_table = {}
    for _, row in ipairs(result.rows) do
      local table_name, column_name, constraint_type, ref_table, ref_column = row[1], row[2], row[3], row[4], row[5]
      by_table[table_name] = by_table[table_name] or { primary_key = {}, foreign_keys = {} }
      if constraint_type == "PRIMARY KEY" then
        table.insert(by_table[table_name].primary_key, column_name)
      elseif
        constraint_type == "FOREIGN KEY"
        and ref_table
        and ref_table ~= "NULL"
        and ref_column
        and ref_column ~= "NULL"
      then
        table.insert(by_table[table_name].foreign_keys, {
          column = column_name,
          ref_table = ref_table,
          ref_column = ref_column,
        })
      end
    end

    callback(by_table, nil)
  end)
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
  end)
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
  end)
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
