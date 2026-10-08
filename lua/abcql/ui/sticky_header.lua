--- Sticky column header for the results window.
---
--- A one-line, non-focusable float over the top of the results window that shows the header row
--- of the table once it has scrolled out of view. The float displays the *same buffer* as the
--- results window, scrolled to the header line with the same `leftcol`, so highlights and
--- horizontal scrolling come for free and the buffer itself is untouched.
local M = {}

local float_win = nil
local float_parent = nil

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Close the float (no-op when it isn't open)
function M.hide()
  if valid(float_win) then
    pcall(vim.api.nvim_win_close, float_win, true)
  end
  float_win, float_parent = nil, nil
end

--- Show, move or hide the float to match the results window's scroll position
--- @param win number|nil Results window
--- @param header_lnum number|nil 1-based buffer line of the header row (nil when there is no table)
function M.update(win, header_lnum)
  if not (valid(win) and header_lnum) then
    return M.hide()
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  if view.topline <= header_lnum then
    return M.hide()
  end

  local config = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(win),
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 40,
  }
  if valid(float_win) and float_parent == win then
    vim.api.nvim_win_set_config(float_win, config)
  else
    M.hide()
    float_win = vim.api.nvim_open_win(buf, false, vim.tbl_extend("force", config, { noautocmd = true }))
    float_parent = win
    vim.wo[float_win].wrap = false
    vim.wo[float_win].sidescrolloff = 0
    vim.wo[float_win].winhighlight = "NormalFloat:Normal"
    vim.wo[float_win].winfixbuf = true
  end

  -- The cursor has to sit inside the visible columns or Neovim scrolls horizontally to reach it
  local col = math.max(vim.fn.virtcol2col(float_win, header_lnum, view.leftcol + 1) - 1, 0)
  vim.api.nvim_win_call(float_win, function()
    vim.fn.winrestview({ topline = header_lnum, lnum = header_lnum, col = col, leftcol = view.leftcol })
  end)
end

return M
