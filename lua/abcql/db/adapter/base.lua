---@alias AdapterConfig { host?: string, port?: number, user?: string, password?: string, database?: string, options?: table<string, string>, proxy?: string }

---@class abcql.db.adapter.Adapter
---@field config {}
---@field ENGINE string|nil Engine identifier sent to abcql-backend (e.g. "mysql"); defaults to "mysql" if unset
---@field get_databases fun(self: abcql.db.adapter.Adapter, callback: fun(databases: table, err: string|nil))
---@field get_tables fun(self: abcql.db.adapter.Adapter, database: string, callback: fun(tables: table, err: string|nil))
---@field get_columns fun(self: abcql.db.adapter.Adapter, database: string, table_name: string, callback: fun(columns: table, err: string|nil))
---@field get_all_columns? fun(self: abcql.db.adapter.Adapter, database: string, callback: fun(columns_by_table: table<string, table>|nil, err: string|nil)) Optional batched column fetch used by the LSP schema cache
---@field get_all_constraints? fun(self: abcql.db.adapter.Adapter, database: string, callback: fun(constraints_by_table: table|nil, err: string|nil)) Optional batched constraint fetch used by hover
---@field escape_identifier fun(self: abcql.db.adapter.Adapter, name: string): string
---@field escape_value fun(self: abcql.db.adapter.Adapter, value: string): string
local Adapter = {}
Adapter.__index = Adapter

--- Create a new adapter instance
--- @param config AdapterConfig Configuration parameters for the adapter
--- @return abcql.db.adapter.Adapter
function Adapter.new(config)
  local self = setmetatable({}, Adapter)
  self.config = config or {}
  return self
end

--- Execute a query with possible asynchronous callback
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (adapter-specific)
--- @param callback function Called with (results, error) where results is structured data
function Adapter:execute_query(query, opts, callback)
  error("execute_query must be implemented by adapter")
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

--- Fetch constraints for a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (constraints, error) where constraints is { primary_key: string[], foreign_keys: {column, ref_table, ref_column}[] }
function Adapter:get_constraints(database, table_name, callback)
  error("get_constraints must be implemented by adapter")
end

--- Fetch indexes for a table asynchronously
--- @param database string Database name
--- @param table_name string Table name
--- @param callback function Called with (indexes, error) where indexes is array of { name: string, columns: string[], unique: boolean }
function Adapter:get_indexes(database, table_name, callback)
  error("get_indexes must be implemented by adapter")
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

--- Parse a SOCKS proxy URL into components
--- @param proxy_url string Proxy URL (e.g., "socks5://localhost:1080")
--- @return table|nil Parsed proxy with type, host, port fields
--- @return string|nil Error message if parsing failed
local function parse_proxy_url(proxy_url)
  local proxy_type, host, port = proxy_url:match("^(socks[45])://([^:]+):(%d+)$")
  if not proxy_type then
    return nil, "Invalid proxy URL format: " .. proxy_url .. " (expected socks4://host:port or socks5://host:port)"
  end
  return { type = proxy_type, host = host, port = tonumber(port) }, nil
end

--- Build the JSON-serializable request table sent to abcql-backend for a query.
--- Generic across engines: connection fields come straight from `self.config`
--- (already parsed/secret-resolved by abcql.db.connection.registry), so most
--- adapters shouldn't need to override this.
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (database?: string, timeout?: number in ms, max_rows?: number)
--- @return table request
function Adapter:build_backend_request(query, opts)
  opts = opts or {}

  local timeout = opts.timeout
  local max_rows = opts.max_rows
  local ok, config = pcall(require, "abcql.config")
  if ok and type(config) == "table" then
    if timeout == nil and type(config.backend) == "table" then
      timeout = config.backend.timeout_ms
    end
    if max_rows == nil and type(config.query) == "table" then
      max_rows = config.query.max_rows
    end
  end

  -- vim.json.encode has no way to tell an empty map from an empty array, and
  -- defaults to `[]` for an empty plain Lua table -- which Go's
  -- map[string]string field rejects. vim.empty_dict() forces `{}` instead.
  local options = self.config.options
  if not options or not next(options) then
    options = vim.empty_dict()
  end

  local request = {
    engine = self.ENGINE or "mysql",
    host = self.config.host,
    port = self.config.port,
    user = self.config.user,
    password = self.config.password,
    database = opts.database or self.config.database,
    options = options,
    sql = query,
    timeout_ms = timeout,
    max_rows = max_rows,
  }

  if self.config.proxy then
    local proxy, err = parse_proxy_url(self.config.proxy)
    if proxy then
      request.proxy = proxy
    else
      vim.notify("abcql: " .. err, vim.log.levels.ERROR)
    end
  end

  return request
end

return Adapter
