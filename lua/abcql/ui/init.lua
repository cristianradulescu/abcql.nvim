---@class abcql.UI
local UI = {}

-- State management for the ABCQL UI
-- This table tracks all buffers, windows, and visibility state for the UI components
local state = {
  -- Buffer IDs for the three main components
  editor_buf = nil,
  results_buf = nil,
  data_source_tree_buf = nil,

  -- Window IDs for the three main components
  editor_win = nil,
  results_win = nil,
  data_source_tree_win = nil,

  -- Visibility state for togglable components
  -- editor is always visible when UI is open
  results_visible = true,
  tree_visible = true,

  -- Autocmd group ID for managing layout-related autocmds
  layout_augroup = nil,
}

--- Open the ABCQL UI
--- Creates a three-panel layout: query editor (top), results (bottom), data source tree (right)
--- The layout uses splits with winfixbuf to prevent buffer mixing
--- @param opts? table Optional parameters
function UI.open(opts)
  opts = opts or {}

  -- Check if UI is already open by checking if any buffer exists and is valid
  if state.editor_buf ~= nil and vim.api.nvim_buf_is_valid(state.editor_buf) then
    vim.notify("abcql UI is already open", vim.log.levels.INFO)
    return
  end

  vim.notify("Opening abcql UI", vim.log.levels.INFO)

  -- Create buffers with nofile type and nobuflisted to prevent them from
  -- appearing in buffer lists and being mixed with regular file buffers
  state.editor_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.editor_buf, "[abcql] Query Editor")
  vim.api.nvim_buf_set_option(state.editor_buf, "buflisted", false)
  vim.api.nvim_buf_set_option(state.editor_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.editor_buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(state.editor_buf, "swapfile", false)

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

  -- Set up autocmds to handle window closure and maintain layout
  state.layout_augroup = vim.api.nvim_create_augroup("AbcqlLayout", { clear = true })

  -- When any of our windows are closed, close the entire UI
  -- This prevents partial/broken layout states
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.layout_augroup,
    callback = function(ev)
      -- ev.match contains the window ID that was closed
      local closed_win = tonumber(ev.match)

      -- Check if the closed window was one of our UI windows
      if
        closed_win == state.editor_win
        or closed_win == state.results_win
        or closed_win == state.data_source_tree_win
      then
        -- If editor window was closed, close entire UI
        -- For results/tree, just update visibility state
        if closed_win == state.editor_win then
          vim.schedule(function()
            UI.close()
          end)
        elseif closed_win == state.results_win then
          state.results_visible = false
          state.results_win = nil
        elseif closed_win == state.data_source_tree_win then
          state.tree_visible = false
          state.data_source_tree_win = nil
        end
      end
    end,
  })

  -- Initialize visibility state
  state.results_visible = true
  state.tree_visible = true
end

--- Close the ABCQL UI
--- Closes all windows and deletes all buffers associated with the UI
function UI.close()
  -- Close all windows if they exist and are valid
  if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
    vim.api.nvim_win_close(state.editor_win, false)
  end

  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.api.nvim_win_close(state.results_win, false)
  end

  if state.data_source_tree_win and vim.api.nvim_win_is_valid(state.data_source_tree_win) then
    vim.api.nvim_win_close(state.data_source_tree_win, false)
  end

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

  -- Clear the autocmd group
  if state.layout_augroup then
    vim.api.nvim_del_augroup_by_id(state.layout_augroup)
  end

  -- Reset state
  state.editor_buf = nil
  state.results_buf = nil
  state.data_source_tree_buf = nil
  state.editor_win = nil
  state.results_win = nil
  state.data_source_tree_win = nil
  state.results_visible = true
  state.tree_visible = true
  state.layout_augroup = nil

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

  if state.tree_visible then
    -- Hide the tree panel
    if state.data_source_tree_win and vim.api.nvim_win_is_valid(state.data_source_tree_win) then
      vim.api.nvim_win_close(state.data_source_tree_win, false)
      state.data_source_tree_win = nil
      state.tree_visible = false
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

      state.tree_visible = true

      -- Restore focus to the window that was current before toggling
      if current_win and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end
end

return UI
