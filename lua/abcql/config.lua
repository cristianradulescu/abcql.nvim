local M = {}

local loader = require("abcql.config.loader")

---@alias abcql.Config
---| { datasources: table<string, string> } Mapping of data source names to DSN strings

---@type abcql.Config
local defaults = {
  datasources = {
    -- Examples:
    -- shop_dev = "mysql://user:password@localhost:3306/shop_db",
    -- shop_prod = "mysql://user:password@prodserv:3306/shop_db",
  },
}

local config = vim.deepcopy(defaults)

--- Stores loaded datasources with source metadata
--- @type table<string, abcql.LoadedDatasource>
local loaded_datasources = {}

---@param opts? abcql.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", {}, vim.deepcopy(defaults), opts or {})

  -- Load datasources from all sources (files + setup config)
  loaded_datasources = loader.load_all_datasources(config.datasources)

  -- Update config.datasources with merged results
  config.datasources = loader.get_dsn_map(loaded_datasources)

  -- Initialize connection registry with data sources
  require("abcql.db").setup(config)
end

--- Reload datasources from config files
--- Useful when cwd changes or config files are modified
function M.reload_datasources()
  -- Reload from all sources
  loaded_datasources = loader.load_all_datasources(config.datasources)

  -- Update config
  config.datasources = loader.get_dsn_map(loaded_datasources)

  -- Re-initialize the database module
  require("abcql.db").setup(config)

  vim.notify("abcql: Datasources reloaded", vim.log.levels.INFO)
end

--- Get loaded datasources with their source metadata
--- @return table<string, abcql.LoadedDatasource>
function M.get_loaded_datasources()
  return loaded_datasources
end

--- Returns a deep copy of the current configuration
---@return abcql.Config
function M.dump()
  return vim.inspect(vim.deepcopy(config))
end

setmetatable(M, {
  __index = function(_, key)
    return config[key]
  end,
})

return M
