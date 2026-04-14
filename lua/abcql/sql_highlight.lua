local M = {}

local NS = vim.api.nvim_create_namespace("abcql_sql_keywords")

local function apply(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local lower = line:lower()

    local start_idx = 1
    while true do
      local s, e = lower:find("%f[%w]describe%f[^%w]", start_idx)
      if not s then
        break
      end
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Keyword", row - 1, s - 1, e)
      start_idx = e + 1
    end

    start_idx = 1
    while true do
      local s, e = lower:find("%f[%w]desc%f[^%w]", start_idx)
      if not s then
        break
      end
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Keyword", row - 1, s - 1, e)
      start_idx = e + 1
    end

    start_idx = 1
    while true do
      local s, e = lower:find("%f[%w]show%f[^%w]%s+%f[%w]create%f[^%w]%s+%f[%w]table%f[^%w]", start_idx)
      if not s then
        break
      end
      vim.api.nvim_buf_add_highlight(bufnr, NS, "Keyword", row - 1, s - 1, e)
      start_idx = e + 1
    end
  end
end

function M.attach(bufnr)
  local group = vim.api.nvim_create_augroup("abcql_sql_highlight_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      apply(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  apply(bufnr)
end

return M
