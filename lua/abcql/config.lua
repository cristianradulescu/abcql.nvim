local M = {}

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

---@param opts? abcql.Config
function M.setup(opts)
  vim.notify("Setting up abcql config", vim.log.levels.INFO)

  config = vim.tbl_deep_extend("force", {}, vim.deepcopy(defaults), opts or {})

  -- Initialize connection registry with data sources
  require("abcql.db").setup(config)
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
