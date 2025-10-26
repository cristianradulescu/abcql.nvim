---@alias Datasource { name: string, dsn: string, adapter?: abcql.db.adapter.Adapter }

---@class abcql.db.connection.Registry
---@field private adapters table<string, abcql.db.adapter.Adapter> Registered adapter classes by scheme
---@field private datasources table<string, Datasource> Registered data sources by name
---@field private connections table<string, abcql.db.adapter.Adapter> Active connection instances by DSN
local Registry = {}
Registry.__index = Registry

--- Create a new registry instance
--- @return abcql.db.connection.Registry
function Registry.new()
  local self = setmetatable({}, Registry)
  self.adapters = {}
  self.datasources = {}
  return self
end

--- Register an adapter class for a specific DSN scheme
--- @param scheme string The DSN scheme (e.g., "mysql", "postgres")
--- @param adapter_class table The adapter class with a .new() constructor
function Registry:register_adapter(scheme, adapter_class)
  self.adapters[scheme:lower()] = adapter_class
end

--- Register a data source name (DSN) with a friendly name
--- @param name string The friendly name for the data source
--- @param dsn string The data source name (DSN) string
--- @return Datasource|nil The registered data source if successful, nil otherwise
--- @return string|nil Error message if registration failed
function Registry:register_datasource(name, dsn)
  -- Check if data source already exists
  if self.datasources[name] then
    return self.datasources[name], nil
  end

  -- Parse DSN
  local parsed, err = require("abcql.db.connection.dsn").parse_dsn(dsn)
  if not parsed then
    return nil, err
  end

  -- Find adapter for scheme
  local adapter_class = self.adapters[parsed.scheme]
  if not adapter_class then
    return nil, "No adapter registered for scheme: " .. parsed.scheme
  end

  -- Create adapter instance
  local adapter = adapter_class.new({
    host = parsed.host,
    port = parsed.port,
    user = parsed.user,
    password = parsed.password,
    database = parsed.database,
    options = parsed.options,
  })

  local datasource = {
    name = name,
    dsn = dsn,
    adapter = adapter,
  }

  self.datasources = vim.tbl_extend("force", self.datasources, { [name] = datasource })

  return datasource, nil
end

--- Get a registered data source by name
--- @param name string The friendly name of the data source
--- @return Datasource|nil The datasource details if found, nil otherwise
function Registry:get_datasource(name)
  if not self.datasources[name] then
    return nil
  end

  return self.datasources[name]
end

--- Get all registered data sources
--- @return table<string, Datasource> Table of data source names to DSN strings
function Registry:get_all_datasources()
  return self.datasources
end

--- Get list of registered adapter schemes
--- @return string[] List of available schemes
function Registry:get_schemes()
  local schemes = {}
  for scheme, _ in pairs(self.adapters) do
    table.insert(schemes, scheme)
  end
  table.sort(schemes)
  return schemes
end

return Registry
