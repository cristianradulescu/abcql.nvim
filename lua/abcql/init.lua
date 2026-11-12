if vim.fn.has("nvim-0.11.0") == 0 then
  vim.notify("abcql.nvim requires Neovim >= 0.11.0", vim.log.levels.ERROR)
  return
end

local M = {}

--- The plugin version, e.g. "1.0.0" (see CHANGELOG.md).
M.version = require("abcql.version")

---@param opts? abcql.Config
function M.setup(opts)
  require("abcql.config").setup(opts)
end

return M
