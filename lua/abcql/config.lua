---@class abcql.config: abcql.Config
local M = {}

---@class abcql.Config
local defaults = {
  data_sources = {
    -- Examples:
    -- shop_dev = "mysql://user:password@localhost:3306/shop_db",
    -- shop_prod = "mysql://user:password@prodserv:3306/shop_db",
  },
}

local config = vim.deepcopy(defaults) --[[@as abcql.Config]]

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
