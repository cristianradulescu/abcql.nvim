local M = {}

--- Parse a DSN string into components
--- @param dsn string DSN in format: scheme://user:password@host:port/database
--- @return table|nil Parsed DSN components or nil on error
--- @return string|nil Error message if parsing failed
function M.parse_dsn(dsn)
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

return M
