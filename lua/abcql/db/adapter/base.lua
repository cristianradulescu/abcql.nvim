---@alias AdapterConfig { host?: string, port?: number, user?: string, password?: string, database?: string, options?: table<string, string>, proxy?: string }

---@class abcql.db.adapter.Adapter
---@field config {}
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
--- @param config AdapterConfig Configuration parameters for the adapter
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

--- Execute a query with possible asynchronous callback
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (adapter-specific)
--- @param callback function Called with (results, error) where results is structured data
function Adapter:execute_query(query, opts, callback)
  error("execute_query must be implemented by adapter")
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

--- Generate a proxychains config file for the given proxy
--- @param proxy table Parsed proxy with type, host, port fields
--- @return string path Path to the generated config file
local function generate_proxychains_config(proxy)
  local config_content = string.format(
    "strict_chain\nquiet_mode\n[ProxyList]\n%s %s %d\n",
    proxy.type, proxy.host, proxy.port
  )
  local path = os.tmpname()
  local file = io.open(path, "w")
  if file then
    file:write(config_content)
    file:close()
  end
  return path
end

--- Build the full command array for execution, wrapping with proxychains if proxy is configured
--- @param cmd string The base command (e.g., "mysql")
--- @param args table Array of command-line arguments
--- @return table The full command array ready for vim.system()
function Adapter:build_command(cmd, args)
  if not self.config.proxy then
    return { cmd, unpack(args) }
  end

  -- Generate proxychains config on first use, cache for reuse
  if not self._proxychains_config_path then
    local proxy, err = parse_proxy_url(self.config.proxy)
    if not proxy then
      vim.notify("abcql: " .. err, vim.log.levels.ERROR)
      return { cmd, unpack(args) }
    end

    -- Check that proxychains4 is available
    if vim.fn.executable("proxychains4") ~= 1 then
      vim.notify("abcql: proxychains4 is not installed. Install it to use SOCKS proxy connections.", vim.log.levels.ERROR)
      return { cmd, unpack(args) }
    end

    self._proxychains_config_path = generate_proxychains_config(proxy)
  end

  local full_cmd = { "proxychains4", "-q", "-f", self._proxychains_config_path, cmd }
  for _, arg in ipairs(args) do
    table.insert(full_cmd, arg)
  end
  return full_cmd
end

return Adapter
