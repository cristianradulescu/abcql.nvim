---@class abcql.db.adapter.Adapter
---@field config table Connection configuration
---@field get_command fun(self: abcql.db.adapter.Adapter): string
---@field get_args fun(self: abcql.db.adapter.Adapter, query: string, opts: table|nil): table
---@field parse_output fun(self: abcql.db.adapter.Adapter, raw: string): table
---@field get_databases fun(self: abcql.db.adapter.Adapter, callback: fun(databases: table, err: string|nil))
---@field get_tables fun(self: abcql.db.adapter.Adapter, database: string, callback: fun(tables: table, err: string|nil))
---@field get_columns fun(self: abcql.db.adapter.Adapter, database: string, table_name: string, callback: fun(columns: table, err: string|nil))
---@field escape_identifier fun(self: abcql.db.adapter.Adapter, name: string): string
---@field escape_value fun(self: abcql.db.adapter.Adapter, value: string): string
local Adapter = {}
Adapter.__index = Adapter

--- Create a new adapter instance
--- @param config table Connection configuration
--- @return abcql.db.adapter.Adapter
function Adapter.new(config)
  local self = setmetatable({}, Adapter)
  self.config = config or {}
  return self
end

--- Get the CLI command name for this database adapter
--- @return string The command name (e.g., "mysql", "psql")
function Adapter:get_command()
  error("get_command must be implemented by adapter")
end

--- Get CLI arguments for executing a query
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (adapter-specific)
--- @return table Array of command-line arguments
function Adapter:get_args(query, opts)
  error("get_args must be implemented by adapter")
end

--- Parse raw CLI output into structured data
--- @param raw string Raw output from CLI command
--- @return table Array of rows
function Adapter:parse_output(raw)
  error("parse_output must be implemented by adapter")
end

--- Fetch list of all databases asynchronously
--- @param callback function Called with (databases, error) where databases is array of database names
function Adapter:get_databases(callback)
  error("get_databases must be implemented by adapter")
end

--- Fetch list of tables in a database asynchronously
--- @param database string Database name
--- @param callback function Called with (tables, error) where tables is array of table names
function Adapter:get_tables(database, callback)
  error("get_tables must be implemented by adapter")
end

--- Fetch list of columns in a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (columns, error) where columns is array of {name, type} tables
function Adapter:get_columns(database, table_name, callback)
  error("get_columns must be implemented by adapter")
end

--- Escape a database identifier (table name, column name, etc.)
--- @param name string The identifier to escape
--- @return string The escaped identifier
function Adapter:escape_identifier(name)
  return name
end

--- Escape a value for use in SQL queries
--- @param value string The value to escape
--- @return string The escaped value
function Adapter:escape_value(value)
  return value
end

return Adapter
