local M = {}

local loader = require("abcql.config.loader")

---@class abcql.Config.UI
---@field results_height number Results panel height: a fraction of the screen (0 < n < 1) or an absolute line count
---@field tree_width number Datasource tree width in columns
---@field icons boolean Use Nerd Font icons in the tree (false falls back to plain ASCII)
---@field cell_max_width number Maximum rendered width of a results cell before truncation

---@class abcql.Config.Query
---@field confirm "always"|"writes"|"never" When to show the confirmation prompt before executing
---@field max_rows number Maximum rows fetched per query (0 disables the cap)
---@field auto_attach boolean Attach the last used datasource to new SQL buffers automatically
---@field treesitter boolean Use the tree-sitter `sql` parser for statement boundaries when available

---@class abcql.Config
---@field datasources table<string, string|table>
---@field default string|nil Name of the datasource attached automatically to SQL buffers
---@field backend { path: string?, timeout_ms: number }
---@field ui abcql.Config.UI
---@field query abcql.Config.Query

---@type abcql.Config
local defaults = {
  datasources = {
    -- Examples:
    -- shop_dev = "mysql://user:password@localhost:3306/shop_db",
    -- shop_prod = "mysql://user:password@prodserv:3306/shop_db",
  },
  -- Datasource attached automatically to SQL buffers when none is chosen
  -- explicitly. A `default` in `.abcql.lua` takes precedence over this.
  default = nil,
  backend = {
    -- Path to the abcql-backend binary. Defaults to bin/abcql-backend
    -- relative to the plugin's own runtime directory (see abcql.backend.get_path).
    path = nil,
    -- Default query timeout, forwarded to abcql-backend as timeout_ms.
    timeout_ms = 30000,
  },
  ui = {
    results_height = 0.4,
    tree_width = 30,
    icons = true,
    cell_max_width = 50,
  },
  query = {
    confirm = "writes",
    max_rows = 1000,
    auto_attach = true,
    treesitter = true,
  },
}

local config = vim.deepcopy(defaults)

--- Stores loaded datasources with source metadata
--- @type table<string, abcql.LoadedDatasource>
local loaded_datasources = {}

--- Default datasource name resolved from config files / setup()
--- @type string|nil
local default_datasource = nil

--- Apply loaded datasources to the config and the database registry
--- @param setup_default string|nil Default datasource name from setup()
local function apply_datasources(setup_default)
  loaded_datasources, default_datasource = loader.load_all_datasources(config.datasources, setup_default)

  -- Update config.datasources with merged results (simple dsn map for backward compat)
  config.datasources = loader.get_dsn_map(loaded_datasources)
  config.default = default_datasource

  -- Initialize connection registry with data sources (includes proxy/flags config)
  local db_config = vim.deepcopy(config)
  db_config.datasources = loader.get_datasource_configs(loaded_datasources)
  require("abcql.db").setup(db_config)
end

---@param opts? abcql.Config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", {}, vim.deepcopy(defaults), opts or {})
  apply_datasources(config.default)
end

--- Reload datasources from config files
--- Useful when cwd changes or config files are modified
function M.reload_datasources()
  apply_datasources(config.default)

  local ok, Tree = pcall(require, "abcql.ui.tree")
  if ok then
    Tree.reset()
  end
  local ok_ui, UI = pcall(require, "abcql.ui")
  if ok_ui and UI.refresh_tree then
    UI.refresh_tree()
  end

  vim.notify("abcql: Datasources reloaded", vim.log.levels.INFO)
end

--- Get loaded datasources with their source metadata
--- @return table<string, abcql.LoadedDatasource>
function M.get_loaded_datasources()
  return loaded_datasources
end

--- Get the default datasource name, if configured
--- @return string|nil
function M.get_default_datasource()
  return default_datasource
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
