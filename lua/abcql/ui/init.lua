---@class abcql.UI
local UI = {}

---@alias abcql.UI.LayoutOpts { editor_buf: number? }

-- State management for the abcql UI
-- This table tracks all buffers, windows, and visibility state for the UI components
local state = {
  -- Buffer IDs for the main components
  editor_buf = nil,
  results_buf = nil,
  data_source_tree_buf = nil,

  -- Window IDs for the main components
  editor_win = nil,
  results_win = nil,
  data_source_tree_win = nil,

  -- Visibility state for togglable components
  -- editor is always visible when UI is open
  results_visible = false,
  data_source_tree_visible = false,
}

--- Open the abcql UI
--- Creates a three-panel layout: query editor (top), results (bottom), data source tree (right)
--- The layout uses splits with winfixbuf to prevent buffer mixing
--- @param opts? abcql.UI.LayoutOpts Optional parameters
function UI.open(opts)
  opts = opts or {}

  -- If no editor buffer is provided, check if the current buffer is a SQL file to use instead, or create one
  if nil == opts.editor_buf then
    local current_buf = vim.api.nvim_get_current_buf()
    local is_sql_file = vim.bo[current_buf].filetype == "sql" and vim.bo[current_buf].buftype == ""
    if not is_sql_file and opts.editor_buf == nil then
      vim.ui.select({ "Yes", "No" }, {
        prompt = "abcql UI requires a SQL file buffer. Create one?",
      }, function(choice)
        if choice == "Yes" then
          local scratch_buf = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_name(scratch_buf, "[abcql] SQL console")
          vim.api.nvim_buf_set_option(scratch_buf, "filetype", "sql")
          vim.api.nvim_buf_set_option(scratch_buf, "buftype", "")
          vim.api.nvim_buf_set_option(scratch_buf, "buflisted", false)
          vim.api.nvim_buf_set_option(scratch_buf, "bufhidden", "hide")
          vim.api.nvim_buf_set_option(scratch_buf, "swapfile", false)
          vim.api.nvim_set_current_buf(scratch_buf)
          UI.open({ editor_buf = scratch_buf })
        end
      end)

      return
    else
      UI.open({ editor_buf = current_buf })

      return
    end
  end

  -- Check if UI is already open by checking if any buffer exists and is valid
  vim.print(vim.inspect(state.editor_buf))
  vim.print(vim.inspect(opts.editor_buf))
  if state.editor_buf == nil and opts.editor_buf ~= nil and vim.api.nvim_buf_is_valid(opts.editor_buf) then
    vim.notify("abcql editor buf found", vim.log.levels.INFO)
    state.editor_buf = opts.editor_buf
  end

  vim.notify("Opening abcql UI", vim.log.levels.INFO)

  -- Create buffers with nofile type and nobuflisted to prevent them from
  -- appearing in buffer lists and being mixed with regular file buffers
  state.results_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.results_buf, "[abcql] Query Results")
  vim.api.nvim_buf_set_option(state.results_buf, "buflisted", false)
  vim.api.nvim_buf_set_option(state.results_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.results_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(state.results_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(state.results_buf, "modifiable", false) -- Results are read-only

  state.data_source_tree_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.data_source_tree_buf, "[abcql] Data Sources")
  vim.api.nvim_buf_set_option(state.data_source_tree_buf, "buflisted", false)
  vim.api.nvim_buf_set_option(state.data_source_tree_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.data_source_tree_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(state.data_source_tree_buf, "swapfile", false)

  -- Create the window layout
  -- Layout structure:
  --   +-------------------+-------+
  --   | Query Editor      | Tree  |
  --   |                   |       |
  --   +-------------------+       |
  --   | Query Results     |       |
  --   +-------------------+-------+

  -- The current window will become the editor window
  state.editor_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.editor_win, state.editor_buf)

  -- Create vertical split on the right for the data source tree (30 columns wide)
  vim.cmd("vertical rightbelow split")
  state.data_source_tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.data_source_tree_win, state.data_source_tree_buf)
  vim.api.nvim_win_set_width(state.data_source_tree_win, 30)

  -- Go back to the editor window and create horizontal split below for results
  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("rightbelow split")
  state.results_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.results_win, state.results_buf)

  -- Set the results window height to 40% of available height
  local total_height = vim.o.lines - vim.o.cmdheight - 2 -- Account for statusline and tabline
  vim.api.nvim_win_set_height(state.results_win, math.floor(total_height * 0.4))

  -- Return focus to the editor window
  vim.api.nvim_set_current_win(state.editor_win)

  -- Configure window options to maintain layout integrity
  -- winfixbuf prevents other buffers from being loaded in these windows (requires Neovim 0.10+)
  -- winfixwidth/winfixheight prevent accidental resizing via window commands
  vim.api.nvim_set_option_value("winfixbuf", true, { win = state.editor_win })
  vim.api.nvim_set_option_value("winfixbuf", true, { win = state.results_win })
  vim.api.nvim_set_option_value("winfixbuf", true, { win = state.data_source_tree_win })
  vim.api.nvim_set_option_value("winfixwidth", true, { win = state.data_source_tree_win })

  -- Initialize visibility state
  state.results_visible = true
  state.data_source_tree_visible = true
end

--- Close the ABCQL UI
--- Closes all windows and deletes all buffers associated with the UI
function UI.close()
  -- Delete all buffers if they exist and are valid
  if state.editor_buf and vim.api.nvim_buf_is_valid(state.editor_buf) then
    vim.api.nvim_buf_delete(state.editor_buf, { force = true })
  end

  if state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf) then
    vim.api.nvim_buf_delete(state.results_buf, { force = true })
  end

  if state.data_source_tree_buf and vim.api.nvim_buf_is_valid(state.data_source_tree_buf) then
    vim.api.nvim_buf_delete(state.data_source_tree_buf, { force = true })
  end

  -- Reset state
  state.editor_buf = nil
  state.results_buf = nil
  state.data_source_tree_buf = nil
  state.editor_win = nil
  state.results_win = nil
  state.data_source_tree_win = nil
  state.results_visible = false
  state.data_source_tree_visible = false

  vim.notify("Closed abcql UI", vim.log.levels.INFO)
end

--- Toggle visibility of the query results panel
--- If visible, closes the window but keeps the buffer
--- If hidden, recreates the window in the correct position
function UI.toggle_results()
  -- Check if UI is open
  if not state.editor_buf or not vim.api.nvim_buf_is_valid(state.editor_buf) then
    vim.notify("abcql UI is not open", vim.log.levels.WARN)
    return
  end

  if state.results_visible then
    -- Hide the results panel
    if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
      vim.api.nvim_win_close(state.results_win, false)
      state.results_win = nil
      state.results_visible = false
    end
  else
    -- Show the results panel
    -- Save current window to restore focus later
    local current_win = vim.api.nvim_get_current_win()

    -- Go to editor window and create split below it
    if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
      vim.api.nvim_set_current_win(state.editor_win)
      vim.cmd("rightbelow split")
      state.results_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.results_win, state.results_buf)

      -- Set window height and options
      local total_height = vim.o.lines - vim.o.cmdheight - 2
      vim.api.nvim_win_set_height(state.results_win, math.floor(total_height * 0.4))
      vim.api.nvim_set_option_value("winfixbuf", true, { win = state.results_win })

      state.results_visible = true

      -- Restore focus to the window that was current before toggling
      if current_win and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end
end

--- Toggle visibility of the data source tree panel
--- If visible, closes the window but keeps the buffer
--- If hidden, recreates the window in the correct position
function UI.toggle_tree()
  -- Check if UI is open
  if not state.editor_buf or not vim.api.nvim_buf_is_valid(state.editor_buf) then
    vim.notify("abcql UI is not open", vim.log.levels.WARN)
    return
  end

  if state.data_source_tree_visible then
    -- Hide the tree panel
    if state.data_source_tree_win and vim.api.nvim_win_is_valid(state.data_source_tree_win) then
      vim.api.nvim_win_close(state.data_source_tree_win, false)
      state.data_source_tree_win = nil
      state.data_source_tree_visible = false
    end
  else
    -- Show the tree panel
    -- Save current window to restore focus later
    local current_win = vim.api.nvim_get_current_win()

    -- Go to editor window and create vertical split on the right
    if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
      vim.api.nvim_set_current_win(state.editor_win)
      vim.cmd("vertical rightbelow split")
      state.data_source_tree_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.data_source_tree_win, state.data_source_tree_buf)

      -- Set window width and options
      vim.api.nvim_win_set_width(state.data_source_tree_win, 30)
      vim.api.nvim_set_option_value("winfixbuf", true, { win = state.data_source_tree_win })
      vim.api.nvim_set_option_value("winfixwidth", true, { win = state.data_source_tree_win })

      state.data_source_tree_visible = true

      -- Restore focus to the window that was current before toggling
      if current_win and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end
end

return UI
