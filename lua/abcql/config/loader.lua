--- Configuration loader for abcql.nvim
--- Loads datasources from .abcql.lua files with priority:
--- 1. .abcql.lua in current working directory (project-specific)
--- 2. ~/.config/abcql/datasources.lua (user global)
--- 3. setup() config (fallback)

local M = {}

--- @alias abcql.DatasourceSource "local" | "user" | "config"

--- @class abcql.LoadedDatasource
--- @field dsn string The connection string (with env vars expanded)
--- @field proxy? string SOCKS proxy URL (e.g., "socks5://127.0.0.1:1080")
--- @field secret? abcql.SecretRef Secret reference for credential lookup
--- @field readonly? boolean Refuse to run statements that modify data or schema
--- @field confirm? "always"|"writes"|"never" Per-datasource confirmation policy (overrides query.confirm)
--- @field highlight? string Highlight group used for this datasource in the winbar
--- @field auto_limit? number|false LIMIT added to plain SELECTs (overrides query.auto_limit; 0/false disables)
--- @field lint_dangerous? boolean Override query.lint_dangerous for this datasource
--- @field session? "persistent"|"oneshot" Override query.session for this datasource
--- @field history_rows? boolean Override query.history_rows (false: history keeps the query and outcome, not the rows)
--- @field source abcql.DatasourceSource Where this datasource was loaded from
--- @field source_path? string Path to the config file (nil for "config" source)

--- @class abcql.SecretRef
--- @field provider? string Secret backend provider. Defaults to "secret-tool" on Linux.
--- @field service string Secret service namespace (e.g. "abcql")
--- @field account string Secret account/key identifier

--- Default config file name
M.CONFIG_FILE_NAME = ".abcql.lua"

--- User config directory
M.USER_CONFIG_DIR = vim.fn.stdpath("config") .. "/abcql"

--- User datasources file path
M.USER_DATASOURCES_PATH = M.USER_CONFIG_DIR .. "/datasources.lua"

--- Whether files written by add_datasource_to_file are marked trusted for
--- vim.secure.read (tests disable this to keep the trust database clean)
M.TRUST_WRITTEN_FILES = true

--- Template content for new config files
M.CONFIG_TEMPLATE = [[
-- abcql.nvim datasources configuration
-- Add this file to .gitignore to avoid committing credentials
--
-- Environment variables can be used with ${VAR_NAME} syntax:
--   dev = "${DATABASE_URL}",
--   staging = "mysql://user:${DB_PASSWORD}@staging:3306/mydb",
--
-- Linux keyring support (GNOME Keyring / Secret Service via secret-tool):
--   prod = {
--     dsn = "mysql://user@db-internal:3306/database",
--     secret = {
--       service = "abcql",
--       account = "prod-db-password",
--     },
--   },
--
-- SOCKS proxy support (dialed natively by abcql-backend, socks5 only):
--   prod = {
--     dsn = "mysql://user:password@db-internal:3306/database",
--     proxy = "socks5://127.0.0.1:1080",
--   },
--
-- Safety flags (all optional):
--   prod = {
--     dsn = "mysql://user:password@db-internal:3306/database",
--     readonly = true,             -- refuse INSERT/UPDATE/DELETE/DDL
--     confirm = "always",          -- "always" | "writes" | "never"
--     highlight = "DiagnosticError", -- winbar highlight group
--     auto_limit = 100,            -- LIMIT added to SELECTs without one (false = off)
--     lint_dangerous = false,      -- skip the UPDATE/DELETE-without-WHERE lint
--     session = "persistent",      -- keep one connection per buffer (MySQL only); "oneshot" = one per run
--     history_rows = false,        -- query history keeps the SQL and outcome, not the result rows
--   },
--
-- Passwords with reserved characters (@ : / ? # % and so on) can be
-- percent-encoded in the DSN: "mysql://user:p%40ss@host:3306/db" is p@ss.
--
-- MySQL connections use TLS when the server offers it (tls=preferred, without
-- certificate verification). For production, verify the server: add ?tls=true.

return {
  -- Datasource attached automatically to SQL buffers in this project
  -- (can be overridden per file with a `-- abcql: <name>` comment).
  -- default = "dev",
  datasources = {
    -- dev = "mysql://user:password@localhost:3306/database",
    -- app = "sqlite://data/app.db", -- SQLite file, relative to the working directory (or sqlite:///abs/path.db)
  },
}
]]

--- Expand environment variables in a string
--- Supports ${VAR_NAME} syntax
--- @param str string The string potentially containing env var references
--- @return string The string with env vars expanded
function M.expand_env_vars(str)
  if type(str) ~= "string" then
    return str
  end

  return str:gsub("%${([^}]+)}", function(var_name)
    local value = os.getenv(var_name)
    if value then
      return value
    else
      vim.notify(string.format("abcql: Environment variable '%s' is not set", var_name), vim.log.levels.WARN)
      return "${" .. var_name .. "}"
    end
  end)
end

--- Safely load a Lua config file
--- @param path string Path to the Lua file
--- @return table|nil config The loaded config table, or nil if failed
--- @return string|nil error Error message if loading failed
function M.load_config_file(path)
  -- Check if file exists
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, nil -- File doesn't exist, not an error
  end

  -- Load the file using vim.secure.trust if available (Neovim 0.9+)
  -- This prompts the user to trust the file before executing it
  if vim.secure and vim.secure.read then
    local content = vim.secure.read(path)
    if not content then
      return nil, nil -- User declined to trust the file
    end
    local chunk, load_err = loadstring(content, path)
    if not chunk then
      return nil, string.format("Failed to parse config file '%s': %s", path, load_err)
    end
    local ok, result = pcall(chunk)
    if not ok then
      return nil, string.format("Failed to load config file '%s': %s", path, result)
    end
    if type(result) ~= "table" then
      return nil, string.format("Config file '%s' must return a table", path)
    end
    return result, nil
  end

  -- Fallback for older Neovim versions
  local ok, result = pcall(dofile, path)
  if not ok then
    return nil, string.format("Failed to load config file '%s': %s", path, result)
  end

  -- Validate structure
  if type(result) ~= "table" then
    return nil, string.format("Config file '%s' must return a table", path)
  end

  return result, nil
end

--- Get the path to the local config file in current working directory
--- @return string
function M.get_local_config_path()
  return vim.fn.getcwd() .. "/" .. M.CONFIG_FILE_NAME
end

--- Normalize a datasource value into a loaded datasource entry
--- Supports both string DSNs and table configs with {dsn=..., proxy=..., readonly=..., ...}
--- @param value string|table The raw datasource value
--- @param source abcql.DatasourceSource
--- @param source_path string|nil
--- @return abcql.LoadedDatasource
local function normalize_datasource(value, source, source_path)
  local entry = {
    source = source,
    source_path = source_path,
  }

  if type(value) == "table" then
    entry.dsn = M.expand_env_vars(value.dsn)
    entry.proxy = value.proxy and M.expand_env_vars(value.proxy) or nil
    entry.secret = value.secret
    entry.readonly = value.readonly == true or nil
    entry.confirm = value.confirm
    entry.highlight = value.highlight
    entry.auto_limit = value.auto_limit
    entry.lint_dangerous = value.lint_dangerous
    entry.session = value.session
    entry.history_rows = value.history_rows
  else
    entry.dsn = M.expand_env_vars(value)
  end

  return entry
end

--- Load datasources from all config sources
--- Returns merged datasources with source tracking, plus the resolved
--- `default` datasource name (local config > user config > setup()).
--- @param setup_datasources? table<string, string|table> Datasources from setup() call
--- @param setup_default? string Default datasource name from setup()
--- @return table<string, abcql.LoadedDatasource> Merged datasources with metadata
--- @return string|nil default Default datasource name, if any
function M.load_all_datasources(setup_datasources, setup_default)
  local result = {}
  local default = setup_default

  -- 1. First, add setup() datasources (lowest priority)
  if setup_datasources then
    for name, value in pairs(setup_datasources) do
      result[name] = normalize_datasource(value, "config", nil)
    end
  end

  -- 2. Load user global config (medium priority)
  local user_config, user_err = M.load_config_file(M.USER_DATASOURCES_PATH)
  if user_err then
    vim.notify(user_err, vim.log.levels.ERROR)
  elseif user_config then
    for name, value in pairs(user_config.datasources or {}) do
      result[name] = normalize_datasource(value, "user", M.USER_DATASOURCES_PATH)
    end
    if type(user_config.default) == "string" then
      default = user_config.default
    end
  end

  -- 3. Load local project config (highest priority)
  local local_path = M.get_local_config_path()
  local local_config, local_err = M.load_config_file(local_path)
  if local_err then
    vim.notify(local_err, vim.log.levels.ERROR)
  elseif local_config then
    for name, value in pairs(local_config.datasources or {}) do
      result[name] = normalize_datasource(value, "local", local_path)
    end
    if type(local_config.default) == "string" then
      default = local_config.default
    end
  end

  if default and not result[default] then
    vim.notify(string.format("abcql: default datasource '%s' is not configured", default), vim.log.levels.WARN)
    default = nil
  end

  return result, default
end

--- Get only the DSN strings from loaded datasources
--- @param loaded_datasources table<string, abcql.LoadedDatasource>
--- @return table<string, string> Simple name -> dsn mapping
function M.get_dsn_map(loaded_datasources)
  local result = {}
  for name, data in pairs(loaded_datasources) do
    result[name] = data.dsn
  end
  return result
end

--- Get datasource configs with DSN, optional proxy/secret and safety flags
--- @param loaded_datasources table<string, abcql.LoadedDatasource>
--- @return table<string, { dsn: string, proxy?: string, secret?: abcql.SecretRef, readonly?: boolean, confirm?: string, highlight?: string, auto_limit?: number|false, lint_dangerous?: boolean, session?: "persistent"|"oneshot", history_rows?: boolean }> name -> config mapping
function M.get_datasource_configs(loaded_datasources)
  local result = {}
  for name, data in pairs(loaded_datasources) do
    result[name] = {
      dsn = data.dsn,
      proxy = data.proxy,
      secret = data.secret,
      readonly = data.readonly,
      confirm = data.confirm,
      highlight = data.highlight,
      auto_limit = data.auto_limit,
      lint_dangerous = data.lint_dangerous,
      session = data.session,
      history_rows = data.history_rows,
    }
  end
  return result
end

--- Create a new config file at the specified path
--- @param path string Path where to create the config file
--- @return boolean success Whether the file was created
--- @return string|nil error Error message if creation failed
function M.create_config_file(path)
  -- Check if file already exists
  local stat = vim.uv.fs_stat(path)
  if stat then
    return false, string.format("Config file already exists at '%s'", path)
  end

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    local ok = vim.fn.mkdir(dir, "p")
    if ok == 0 then
      return false, string.format("Failed to create directory '%s'", dir)
    end
  end

  -- Write the template (0600: the file is meant to hold credentials)
  local ok, err = require("abcql.fs").write_private(path, M.CONFIG_TEMPLATE)
  if not ok then
    return false, string.format("Failed to create config file: %s", err)
  end

  return true, nil
end

--- Remove the password component from a DSN (`scheme://user:pass@host` -> `scheme://user@host`).
--- The userinfo ends at the last `@` before the host (see abcql.db.connection.dsn.split_userinfo).
--- @param dsn string
--- @return string
function M.strip_dsn_password(dsn)
  return require("abcql.db.connection.dsn").strip_password(dsn)
end

--- Set (or replace) the password component of a DSN; the password is percent-encoded
--- so reserved characters (`@ : / ? # %`) survive parsing.
--- @param dsn string
--- @param password string
--- @return string
function M.set_dsn_password(dsn, password)
  return require("abcql.db.connection.dsn").set_password(dsn, password)
end

--- End of a short string (`"..."` / `'...'`) starting at `from` (just after the opening quote).
--- @param line string
--- @param from number
--- @param quote string
--- @return number|nil close Index of the closing quote; nil when the line ends first
--- @return boolean continues The line ends in a backslash, so the string goes on
local function short_string_end(line, from, quote)
  local j = from
  while j <= #line do
    local c = line:sub(j, j)
    if c == "\\" then
      if j == #line then
        return nil, true
      end
      j = j + 2
    elseif c == quote then
      return j, false
    else
      j = j + 1
    end
  end
  return nil, false
end

--- Count the braces of one line of Lua source that are code, skipping string
--- literals (short and long-bracket) and comments (line and long-bracket).
--- @param line string
--- @param open string|nil What is still open from the previous line: the closing
---   long bracket (`]]`, `]==]`) of a long string/comment, or the quote of a
---   backslash-continued short string
--- @return number delta Number of `{` minus number of `}`
--- @return string|nil open What is still open at the end of this line
local function lex_line(line, open)
  local delta = 0
  local i = 1
  if open == '"' or open == "'" then
    local close, continues = short_string_end(line, 1, open)
    if not close then
      return 0, continues and open or nil
    end
    i = close + 1
  elseif open then
    local _, close_end = line:find(open, 1, true)
    if not close_end then
      return 0, open
    end
    i = close_end + 1
  end

  while i <= #line do
    local c = line:sub(i, i)
    if c == "-" and line:sub(i + 1, i + 1) == "-" then
      local eq = line:match("^%[(=*)%[", i + 2)
      if not eq then
        break -- line comment: the rest of the line is not code
      end
      local close = "]" .. eq .. "]"
      local _, close_end = line:find(close, i + 4 + #eq, true)
      if not close_end then
        return delta, close
      end
      i = close_end + 1
    elseif c == '"' or c == "'" then
      local close, continues = short_string_end(line, i + 1, c)
      if not close then
        return delta, continues and c or nil
      end
      i = close + 1
    elseif c == "[" and line:match("^%[=*%[", i) then
      local eq = line:match("^%[(=*)%[", i)
      local close = "]" .. eq .. "]"
      local _, close_end = line:find(close, i + 2 + #eq, true)
      if not close_end then
        return delta, close
      end
      i = close_end + 1
    else
      if c == "{" then
        delta = delta + 1
      elseif c == "}" then
        delta = delta - 1
      end
      i = i + 1
    end
  end
  return delta, nil
end

--- Whether a config line starts the entry `name = ...` (or `["name"] = ...`)
--- @param line string
--- @param name string
--- @return boolean
local function is_entry_line(line, name)
  return line:match("^%s*" .. vim.pesc(name) .. "%s*=") ~= nil
    or line:match('^%s*%["' .. vim.pesc(name) .. '"%]%s*=') ~= nil
end

--- Find the line range of a datasource entry in config file lines.
--- Handles one-line string entries and multi-line table entries. Braces are
--- matched as Lua code: those inside strings (a password with `{`) and comments
--- don't count, and a line that starts inside a long string or comment is never
--- taken for an entry.
--- @param lines string[]
--- @param name string
--- @return number|nil start_line 1-indexed
--- @return number|nil end_line 1-indexed (inclusive)
function M.find_datasource_entry(lines, name)
  local open = nil
  for i, line in ipairs(lines) do
    if open == nil and is_entry_line(line, name) then
      local depth = 0
      for j = i, #lines do
        local delta
        delta, open = lex_line(lines[j], open)
        depth = depth + delta
        if depth <= 0 and open == nil then
          return i, j
        end
      end
      return i, #lines
    end
    local _
    _, open = lex_line(line, open)
  end
  return nil, nil
end

--- Replace a datasource entry in a config file with a freshly rendered one.
--- @param path string
--- @param name string
--- @param entry { dsn: string, proxy?: string, secret?: abcql.SecretRef, readonly?: boolean, confirm?: string, highlight?: string, auto_limit?: number|false, lint_dangerous?: boolean, session?: "persistent"|"oneshot", history_rows?: boolean }
--- @return boolean success
--- @return string|nil error
function M.update_datasource_in_file(path, name, entry)
  local parsed, parse_err = require("abcql.db.connection.dsn").parse_dsn(M.expand_env_vars(entry.dsn or ""))
  if not parsed then
    return false, parse_err
  end

  local file, open_err = io.open(path, "r")
  if not file then
    return false, "Failed to read config file: " .. tostring(open_err)
  end
  local content = file:read("*a")
  file:close()

  local lines = vim.split(content, "\n", { plain = true })
  local start_line, end_line = M.find_datasource_entry(lines, name)
  if not start_line then
    return false, string.format("Datasource '%s' not found in %s", name, path)
  end

  local new_lines = vim.split(M.format_datasource_entry(name, entry), "\n", { plain = true })
  local result = {}
  for i = 1, start_line - 1 do
    table.insert(result, lines[i])
  end
  for _, line in ipairs(new_lines) do
    table.insert(result, line)
  end
  for i = end_line + 1, #lines do
    table.insert(result, lines[i])
  end

  -- Atomic (temp file + rename) and 0600, so a failed write can't lose the file
  local ok, write_err = require("abcql.fs").write_private(path, table.concat(result, "\n"))
  if not ok then
    return false, "Failed to write config file: " .. tostring(write_err)
  end

  if M.TRUST_WRITTEN_FILES and vim.secure and vim.secure.trust then
    pcall(vim.secure.trust, { action = "allow", path = path })
  end

  return true, nil
end

--- Render a datasource entry as Lua source for a config file
--- @param name string
--- @param entry { dsn: string, proxy?: string, secret?: abcql.SecretRef, readonly?: boolean, confirm?: string, highlight?: string, auto_limit?: number|false, lint_dangerous?: boolean, session?: "persistent"|"oneshot", history_rows?: boolean }
--- @return string
function M.format_datasource_entry(name, entry)
  local key = name:match("^[%a_][%w_]*$") and name or string.format("[%q]", name)
  -- Only well-typed flags are written: anything else would be emitted as an
  -- unquoted value (or make %q throw) and break or silently change the file.
  local readonly = entry.readonly == true
  local confirm = type(entry.confirm) == "string" and entry.confirm or nil
  local highlight = type(entry.highlight) == "string" and entry.highlight or nil
  local lint_dangerous = type(entry.lint_dangerous) == "boolean"
  local session = (entry.session == "persistent" or entry.session == "oneshot") and entry.session or nil
  local history_rows = type(entry.history_rows) == "boolean"
  local auto_limit = entry.auto_limit
  if type(auto_limit) ~= "number" and auto_limit ~= false then
    auto_limit = nil
  end
  local has_flags = entry.proxy
    or entry.secret
    or readonly
    or confirm
    or highlight
    or lint_dangerous
    or session
    or history_rows
    or auto_limit ~= nil
  if not has_flags then
    return string.format("    %s = %q,", key, entry.dsn)
  end

  local lines = { string.format("    %s = {", key), string.format("      dsn = %q,", entry.dsn) }
  if entry.secret then
    table.insert(lines, "      secret = {")
    table.insert(lines, string.format("        service = %q,", entry.secret.service))
    table.insert(lines, string.format("        account = %q,", entry.secret.account))
    table.insert(lines, "      },")
  end
  if entry.proxy then
    table.insert(lines, string.format("      proxy = %q,", entry.proxy))
  end
  if readonly then
    table.insert(lines, "      readonly = true,")
  end
  if confirm then
    table.insert(lines, string.format("      confirm = %q,", confirm))
  end
  if highlight then
    table.insert(lines, string.format("      highlight = %q,", highlight))
  end
  if lint_dangerous then
    table.insert(lines, string.format("      lint_dangerous = %s,", tostring(entry.lint_dangerous)))
  end
  if session then
    table.insert(lines, string.format("      session = %q,", session))
  end
  if history_rows then
    table.insert(lines, string.format("      history_rows = %s,", tostring(entry.history_rows)))
  end
  if auto_limit ~= nil then
    table.insert(lines, string.format("      auto_limit = %s,", tostring(auto_limit)))
  end
  table.insert(lines, "    },")
  return table.concat(lines, "\n")
end

--- Append a datasource to a config file, creating the file from the template
--- when it does not exist. The entry is inserted right after the
--- `datasources = {` line so comments and other entries are preserved.
--- @param path string Config file path
--- @param name string Datasource name
--- @param entry { dsn: string, proxy?: string, secret?: abcql.SecretRef, readonly?: boolean, confirm?: string, highlight?: string, auto_limit?: number|false, lint_dangerous?: boolean, session?: "persistent"|"oneshot", history_rows?: boolean }
--- @return boolean success
--- @return string|nil error
function M.add_datasource_to_file(path, name, entry)
  if not name:match("^[%w_%-%.]+$") then
    return false, "Invalid datasource name (use letters, digits, _ - .)"
  end
  local parsed, parse_err = require("abcql.db.connection.dsn").parse_dsn(M.expand_env_vars(entry.dsn))
  if not parsed then
    return false, parse_err
  end

  if not vim.uv.fs_stat(path) then
    local ok, err = M.create_config_file(path)
    if not ok then
      return false, err
    end
  end

  local file, open_err = io.open(path, "r")
  if not file then
    return false, "Failed to read config file: " .. tostring(open_err)
  end
  local content = file:read("*a")
  file:close()

  local lines = vim.split(content, "\n", { plain = true })
  if M.find_datasource_entry(lines, name) then
    return false, string.format("Datasource '%s' already exists in %s", name, path)
  end
  local insert_at = nil
  local open = nil
  for i, line in ipairs(lines) do
    if open == nil and line:match("^%s*datasources%s*=%s*{%s*$") then
      insert_at = i
      break
    end
    local _
    _, open = lex_line(line, open)
  end
  if not insert_at then
    return false, "Could not find a `datasources = {` line in " .. path
  end

  table.insert(lines, insert_at + 1, M.format_datasource_entry(name, entry))

  -- Atomic (temp file + rename) and 0600, so a failed write can't lose the file
  local ok, write_err = require("abcql.fs").write_private(path, table.concat(lines, "\n"))
  if not ok then
    return false, "Failed to write config file: " .. tostring(write_err)
  end

  -- The file was written by the user through this command, so re-trust it
  -- for vim.secure.read instead of prompting on the next reload.
  if M.TRUST_WRITTEN_FILES and vim.secure and vim.secure.trust then
    pcall(vim.secure.trust, { action = "allow", path = path })
  end

  return true, nil
end

--- Initialize a local config file in the current working directory
--- @return boolean success
--- @return string|nil error
function M.init_local_config()
  local path = M.get_local_config_path()
  return M.create_config_file(path)
end

--- Initialize the user global config file
--- @return boolean success
--- @return string|nil error
function M.init_user_config()
  return M.create_config_file(M.USER_DATASOURCES_PATH)
end

--- Check if a local config file exists in the current working directory
--- @return boolean
function M.has_local_config()
  local stat = vim.uv.fs_stat(M.get_local_config_path())
  return stat ~= nil
end

--- Check if the user global config file exists
--- @return boolean
function M.has_user_config()
  local stat = vim.uv.fs_stat(M.USER_DATASOURCES_PATH)
  return stat ~= nil
end

return M
