--- Run status: the lines of the last executed statement get a green (ok) or red (error)
--- background. Only one statement is marked at a time, across all buffers.
---@class abcql.ui.Status
local M = {}

local NS = vim.api.nvim_create_namespace("abcql_run_status")

--- Line range of a statement (1-indexed, inclusive).
---@class abcql.ui.StatusMark
---@field bufnr number
---@field start_line number
---@field end_line number

--- Remove the marker from every buffer.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    end
  end
end

--- A statement started: drop the previous marker; the new one appears when it finishes.
--- @param mark abcql.ui.StatusMark|nil
function M.running(mark)
  if mark then
    M.clear()
  end
end

--- Colour the statement's lines by outcome.
--- @param mark abcql.ui.StatusMark|nil
--- @param err string|nil
function M.done(mark, err)
  if not mark or not vim.api.nvim_buf_is_valid(mark.bufnr) then
    return
  end
  M.clear()
  local hl = err and "AbcqlRunError" or "AbcqlRunOk"
  local last = vim.api.nvim_buf_line_count(mark.bufnr)
  for line = mark.start_line, math.min(mark.end_line, last) do
    vim.api.nvim_buf_set_extmark(mark.bufnr, NS, line - 1, 0, { line_hl_group = hl })
  end
end

return M
