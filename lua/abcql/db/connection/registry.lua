---@class abcql.db.connection.Registry
---@field private adapters table<string, abcql.db.adapter.Adapter> Registered adapter classes by scheme
---@field private connections table<string, abcql.db.adapter.Adapter> Active connection instances by DSN
local Registry = {}
Registry.__index = Registry

--- Create a new registry instance
--- @return abcql.db.connection.Registry
function Registry.new()
  local self = setmetatable({}, Registry)
  self.adapters = {}
  self.connections = {}
  return self
end

--- Register an adapter class for a specific DSN scheme
--- @param scheme string The DSN scheme (e.g., "mysql", "postgres")
--- @param adapter_class table The adapter class with a .new() constructor
function Registry:register_adapter(scheme, adapter_class)
  self.adapters[scheme:lower()] = adapter_class
end

--- Parse a DSN string into components
--- @param dsn string DSN in format: scheme://user:password@host:port/database
--- @return table|nil Parsed DSN components or nil on error
--- @return string|nil Error message if parsing failed
function Registry:parse_dsn(dsn)
  local scheme = dsn:match("^(%w+)://")
  if not scheme then
    return nil, "Invalid DSN format: " .. dsn
  end

  local rest = dsn:sub(#scheme + 4)

  local user, password, host, port, database, options

  local auth_and_rest = rest:match("^([^/]+)(.*)$")
  if not auth_and_rest then
    return nil, "Invalid DSN format: " .. dsn
  end

  local auth_part = auth_and_rest
  local path_part = rest:match("^[^/]+(/.*)$") or ""

  if auth_part:find("@") then
    local user_pass, host_port = auth_part:match("^(.+)@(.+)$")
    if user_pass then
      if user_pass:find(":") then
        user, password = user_pass:match("^([^:]+):(.+)$")
      else
        user = user_pass
      end
      auth_part = host_port
    end
  end

  host, port = auth_part:match("^([^:]+):(%d+)$")
  if not host then
    host = auth_part:match("^([^:]+)$")
  end

  if path_part ~= "" then
    database, options = path_part:match("^/([^?]*)(.*)$")
    if options and options:sub(1, 1) == "?" then
      options = options:sub(2)
    end
  end

  local parsed = {
    scheme = scheme:lower(),
    user = user,
    password = password,
    host = host,
    port = port and tonumber(port) or nil,
    database = (database and database ~= "") and database or nil,
    options = {},
  }

  if options and options ~= "" then
    for key, value in options:gmatch("([^&=]+)=([^&]+)") do
      parsed.options[key] = value
    end
  end

  return parsed, nil
end

--- Get or create a connection for a DSN
--- @param dsn string The data source name
--- @return abcql.db.adapter.Adapter|nil The adapter instance
--- @return string|nil Error message if connection failed
function Registry:get_connection(dsn)
  -- Check if connection already exists
  if self.connections[dsn] then
    return self.connections[dsn], nil
  end

  -- Parse DSN
  local parsed, err = self:parse_dsn(dsn)
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

  -- Cache connection
  self.connections[dsn] = adapter

  return adapter, nil
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
