---@class abcql.config: abcql.Config
local M = {}

---@class abcql.Config
local defaults = {
  data_sources = {},
}

local config = vim.deepcopy(defaults) --[[@as abcql.Config]]

---@param opts? abcql.Config
function M.setup(opts)
  vim.notify("Setting up abcql config", vim.log.levels.INFO)

  config = vim.tbl_deep_extend("force", {}, vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("Abcql", function()
    vim.notify(vim.inspect(config), vim.log.levels.INFO, { title = "abcql Config" })
  end, {})
end

setmetatable(M, {
  __index = function(_, key)
    return config[key]
  end,
})

return M
