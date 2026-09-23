local M = {}

--- Parse `key=value&...` into a table
--- @param query string|nil
--- @return table<string, string>
local function parse_options(query)
  local options = {}
  if query and query ~= "" then
    for key, value in query:gmatch("([^&=]+)=([^&]+)") do
      options[key] = value
    end
  end
  return options
end

--- Parse a file-based DSN (sqlite://<path>[?options]). `sqlite:///abs/app.db`
--- is an absolute path; anything else (`sqlite://data/app.db`, `sqlite://~/app.db`)
--- is expanded and resolved against the current directory, so a project's
--- `.abcql.lua` can point at a database file inside the project.
--- @param scheme string
--- @param rest string Everything after `scheme://`
--- @return table|nil
--- @return string|nil
local function parse_file_dsn(scheme, rest)
  local path, query = rest:match("^([^?]*)%??(.*)$")
  if path == "" then
    return nil, "Invalid DSN format: " .. scheme .. "://" .. rest .. " (expected " .. scheme .. ":///path/to/file.db)"
  end
  if path ~= ":memory:" then
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  end

  return {
    scheme = scheme,
    path = path,
    -- SQLite's name for the schema of the opened file; used wherever a
    -- database name is expected (tree, LSP cache, qualified names).
    database = "main",
    options = parse_options(query),
  },
    nil
end

--- Schemes whose DSN names a local database file instead of a server
M.FILE_SCHEMES = { sqlite = true }

--- Parse a DSN string into components
--- @param dsn string DSN in format: scheme://user:password@host:port/database, or sqlite://<path>
--- @return table|nil Parsed DSN components or nil on error
--- @return string|nil Error message if parsing failed
function M.parse_dsn(dsn)
  local scheme = dsn:match("^(%w+)://")
  if not scheme then
    return nil, "Invalid DSN format: " .. dsn
  end

  local rest = dsn:sub(#scheme + 4)

  if M.FILE_SCHEMES[scheme:lower()] then
    return parse_file_dsn(scheme:lower(), rest)
  end

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
    options = parse_options(options),
  }

  return parsed, nil
end

return M
