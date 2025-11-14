if vim.fn.has("nvim-0.11.0") == 0 then
  vim.notify("abcql.nvim requires Neovim >= 0.11.0", vim.log.levels.ERROR)
  return
end

local M = {}

---@param opts? abcql.Config
function M.setup(opts)
  require("abcql.config").setup(opts)
end

return M
