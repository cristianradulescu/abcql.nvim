--- Configuration loader for abcql.nvim
--- Loads datasources from .abcql.lua files with priority:
--- 1. .abcql.lua in current working directory (project-specific)
--- 2. ~/.config/abcql/datasources.lua (user global)
--- 3. setup() config (fallback)

local M = {}

--- @alias abcql.DatasourceSource "local" | "user" | "config"

--- @class abcql.LoadedDatasource
--- @field dsn string The connection string (with env vars expanded)
--- @field source abcql.DatasourceSource Where this datasource was loaded from
--- @field source_path? string Path to the config file (nil for "config" source)

--- Default config file name
M.CONFIG_FILE_NAME = ".abcql.lua"

--- User config directory
M.USER_CONFIG_DIR = vim.fn.stdpath("config") .. "/abcql"

--- User datasources file path
M.USER_DATASOURCES_PATH = M.USER_CONFIG_DIR .. "/datasources.lua"

--- Template content for new config files
M.CONFIG_TEMPLATE = [[
-- abcql.nvim datasources configuration
-- Add this file to .gitignore to avoid committing credentials
--
-- Environment variables can be used with ${VAR_NAME} syntax:
--   dev = "${DATABASE_URL}",
--   staging = "mysql://user:${DB_PASSWORD}@staging:3306/mydb",

return {
  datasources = {
    -- dev = "mysql://user:password@localhost:3306/database",
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
      vim.notify(
        string.format("abcql: Environment variable '%s' is not set", var_name),
        vim.log.levels.WARN
      )
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

  -- Load the file
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

--- Load datasources from all config sources
--- Returns merged datasources with source tracking
--- @param setup_datasources? table<string, string> Datasources from setup() call
--- @return table<string, abcql.LoadedDatasource> Merged datasources with metadata
function M.load_all_datasources(setup_datasources)
  local result = {}

  -- 1. First, add setup() datasources (lowest priority)
  if setup_datasources then
    for name, dsn in pairs(setup_datasources) do
      result[name] = {
        dsn = M.expand_env_vars(dsn),
        source = "config",
        source_path = nil,
      }
    end
  end

  -- 2. Load user global config (medium priority)
  local user_config, user_err = M.load_config_file(M.USER_DATASOURCES_PATH)
  if user_err then
    vim.notify(user_err, vim.log.levels.ERROR)
  elseif user_config and user_config.datasources then
    for name, dsn in pairs(user_config.datasources) do
      result[name] = {
        dsn = M.expand_env_vars(dsn),
        source = "user",
        source_path = M.USER_DATASOURCES_PATH,
      }
    end
  end

  -- 3. Load local project config (highest priority)
  local local_path = M.get_local_config_path()
  local local_config, local_err = M.load_config_file(local_path)
  if local_err then
    vim.notify(local_err, vim.log.levels.ERROR)
  elseif local_config and local_config.datasources then
    for name, dsn in pairs(local_config.datasources) do
      result[name] = {
        dsn = M.expand_env_vars(dsn),
        source = "local",
        source_path = local_path,
      }
    end
  end

  return result
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

  -- Write the template
  local file, err = io.open(path, "w")
  if not file then
    return false, string.format("Failed to create config file: %s", err)
  end

  file:write(M.CONFIG_TEMPLATE)
  file:close()

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
