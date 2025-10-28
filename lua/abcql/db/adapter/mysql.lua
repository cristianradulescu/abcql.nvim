local Adapter = require("abcql.db.adapter.base")
local Query = require("abcql.db.query")

---@class abcql.db.adapter.MySQLAdapter: abcql.db.adapter.Adapter
local MySQLAdapter = {}
MySQLAdapter.__index = MySQLAdapter
setmetatable(MySQLAdapter, { __index = Adapter })

--- Create a new MySQL adapter instance
--- @param config table Connection configuration (host, port, user, database)
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
