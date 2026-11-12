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
    return nil, "Invalid DSN format: missing file path (expected " .. scheme .. ":///path/to/file.db)"
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

--- Decode `%XX` escapes. A `%` not followed by two hex digits is kept as is, so
--- an unencoded password such as `50%off` still means what it says.
--- @param s string
--- @return string
function M.percent_decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Percent-encode everything but RFC 3986 unreserved characters (letters,
--- digits, `-._~`). `$` is encoded too, so `${...}` in a password is not taken
--- for an environment variable reference.
--- @param s string
--- @return string
function M.percent_encode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- Split a server DSN (`scheme://[user[:password]@]host[:port]/database[?options]`, or a
--- proxy URL of the same shape) at its userinfo. This is the one rule every parse, strip,
--- set and display mask uses: the authority runs from `://` to the first `/`; inside it the
--- userinfo ends at the LAST `@` (so a raw `@` in a password works), and the user ends at
--- the first `:`. A `/` in a password must be written `%2F`. Parts are raw (not decoded).
--- File DSNs (sqlite://) and strings without a scheme give nil.
--- @param dsn string
--- @return { prefix: string, user: string|nil, password: string|nil, rest: string }|nil parts
---   `prefix` is `scheme://`, `rest` is everything after the userinfo (`host:port/db?...`);
---   `user` is nil without userinfo, `password` is nil without a `:` in the userinfo
function M.split_userinfo(dsn)
  if type(dsn) ~= "string" then
    return nil
  end
  local prefix, scheme, after = dsn:match("^((%w+)://)(.*)$")
  if not prefix or M.FILE_SCHEMES[scheme:lower()] then
    return nil
  end
  local authority = after:match("^[^/]*")
  local at = authority:match("^.*()@")
  if not at then
    return { prefix = prefix, rest = after }
  end
  local userinfo = after:sub(1, at - 1)
  local user, password = userinfo:match("^([^:]*):(.*)$")
  return { prefix = prefix, user = user or userinfo, password = password, rest = after:sub(at + 1) }
end

--- Remove the password from a DSN (`scheme://user:pass@host/db` -> `scheme://user@host/db`).
--- Anything that is not a server DSN is returned unchanged.
--- @param dsn string
--- @return string
function M.strip_password(dsn)
  local parts = M.split_userinfo(dsn)
  if not parts or not parts.password then
    return dsn
  end
  return parts.prefix .. parts.user .. "@" .. parts.rest
end

--- Set (or replace) the password of a DSN that names a user. The password is
--- percent-encoded, so `parse_dsn` gives it back exactly.
--- @param dsn string
--- @param password string
--- @return string dsn Unchanged when it names no user
function M.set_password(dsn, password)
  local parts = M.split_userinfo(dsn)
  if not parts or not parts.user or parts.user == "" then
    return dsn
  end
  return parts.prefix .. parts.user .. ":" .. M.percent_encode(password) .. "@" .. parts.rest
end

--- A DSN (or proxy URL) safe to show: the password replaced by `****`. For a
--- string without a scheme, everything before the last `@` of its first
--- `/`-separated part is masked, since it can't be told apart from a password.
--- @param dsn string|nil
--- @return string
function M.mask(dsn)
  if type(dsn) ~= "string" then
    return ""
  end
  local parts = M.split_userinfo(dsn)
  if parts then
    if not parts.password or parts.password == "" then
      return dsn
    end
    return parts.prefix .. parts.user .. ":****@" .. parts.rest
  end
  if dsn:match("^%w+://") then
    return dsn -- a file DSN: no userinfo
  end
  local at = dsn:match("^[^/]*()@")
  if at then
    return "****" .. dsn:sub(at)
  end
  return dsn
end

--- Parse a DSN string into components. User and password are percent-decoded
--- (`mysql://u:p%40ss@host/db` has the password `p@ss`). Error messages never
--- contain the password.
--- @param dsn string DSN in format: scheme://user:password@host:port/database, or sqlite://<path>
--- @return table|nil Parsed DSN components or nil on error
--- @return string|nil Error message if parsing failed
function M.parse_dsn(dsn)
  if type(dsn) ~= "string" then
    return nil, "Invalid DSN: expected a string"
  end
  local scheme = dsn:match("^(%w+)://")
  if not scheme then
    return nil,
      "Invalid DSN format: missing scheme (expected mysql://user@host:port/database or sqlite:///path/to/file.db)"
  end

  local rest = dsn:sub(#scheme + 4)

  if M.FILE_SCHEMES[scheme:lower()] then
    return parse_file_dsn(scheme:lower(), rest)
  end

  local host, port, database, options

  if not rest:match("^[^/]") then
    return nil, "Invalid DSN format: missing host (expected " .. scheme .. "://user@host:port/database)"
  end

  local parts = assert(M.split_userinfo(dsn))
  local auth_part = parts.rest:match("^[^/]*")
  local path_part = parts.rest:sub(#auth_part + 1)

  local user = parts.user and parts.user ~= "" and M.percent_decode(parts.user) or nil
  local password = parts.password and parts.password ~= "" and M.percent_decode(parts.password) or nil

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

  if not database or database == "" then
    return nil, "Missing database name in DSN (expected " .. scheme .. "://user:password@host:port/database)"
  end

  local parsed = {
    scheme = scheme:lower(),
    user = user,
    password = password,
    host = host,
    port = port and tonumber(port) or nil,
    database = database,
    options = parse_options(options),
  }

  return parsed, nil
end

return M
