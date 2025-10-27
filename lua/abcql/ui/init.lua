---@class abcql.UI
local UI = {}

---@alias abcql.UI.LayoutOpts { editor_buf: number? }

-- State management for the abcql UI
-- This table tracks all buffers, windows, and visibility state for the UI components
local state = {
  -- Buffer IDs for the main components
  editor_buf = nil,
  results_buf = nil,
  datasource_tree_buf = nil,

  -- Window IDs for the main components
  editor_win = nil,
  results_win = nil,
  datasource_tree_win = nil,

  -- Visibility state for togglable components
  -- editor is always visible when UI is open
  results_visible = false,
  data_source_tree_visible = false,
}

--- Create the query editor buffer
--- @return number buf Buffer ID
local function create_editor_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "[abcql] SQL console")
  vim.api.nvim_buf_set_option(buf, "filetype", "sql")
  vim.api.nvim_buf_set_option(buf, "buftype", "")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  -- Insert initial content into the editor buffer
  local initial_lines = {
    "-- abcql SQL Console",
    "",
    "show tables;",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

  return buf
end

--- Create the results buffer
--- @return number buf Buffer ID
--- @return fun(win: number) win_options_callback Callback to set window options
local function create_results_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "[abcql] Query Results")
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false) -- Results are read-only

  local win_options_callback = function(win)
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("number", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("spell", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("colorcolumn", "", { win = win, scope = "local" })
  end

  return buf, win_options_callback
end

--- Create the data source tree buffer
--- @return number buf Buffer ID
--- @return fun(win: number) win_options_callback Callback to set window options
local function create_data_source_tree_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "[abcql] Data Sources")
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  -- vim.api.nvim_buf_set_option(buf, "buflisted", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "hide")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  -- Dummy data source tree content
  local lines = {
    "Data Sources:",
    "",
    "- datasource_1",
    "  - database_1",
    "    - table_1",
    "    - table_2",
    "  - database_2",
    "- datasource_2",
    "  - database_a",
    "    - table_x",
    "    - table_y",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local win_options_callback = function(win)
    vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("number", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("spell", false, { win = win, scope = "local" })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
    vim.api.nvim_set_option_value("colorcolumn", "", { win = win, scope = "local" })
  end

  return buf, win_options_callback
end

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
          local scratch_buf = create_editor_buffer()
          UI.open({ editor_buf = scratch_buf })
        end
      end)

      return
    else
      UI.open({ editor_buf = current_buf })

      return
    end
  end

  -- Set editor buffer based on provided buffer
  if state.editor_buf == nil and opts.editor_buf ~= nil and vim.api.nvim_buf_is_valid(opts.editor_buf) then
    state.editor_buf = opts.editor_buf
  else
    vim.notify("abcql UI is missing the query editor", vim.log.levels.ERROR)
    return
  end

  local results_win_opts, datasource_win_opts
  state.results_buf, results_win_opts = create_results_buffer()
  state.datasource_tree_buf, datasource_win_opts = create_data_source_tree_buffer()

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
  state.datasource_tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.datasource_tree_win, state.datasource_tree_buf)
  vim.api.nvim_win_set_width(state.datasource_tree_win, 30)
  datasource_win_opts(state.datasource_tree_win)

  -- Go back to the editor window and create horizontal split below for results
  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("rightbelow split")
  state.results_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.results_win, state.results_buf)
  results_win_opts(state.results_win)

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
  vim.api.nvim_set_option_value("winfixbuf", true, { win = state.datasource_tree_win })
  vim.api.nvim_set_option_value("winfixwidth", true, { win = state.datasource_tree_win })

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

  if state.datasource_tree_buf and vim.api.nvim_buf_is_valid(state.datasource_tree_buf) then
    vim.api.nvim_buf_delete(state.datasource_tree_buf, { force = true })
  end

  -- Reset state
  state.editor_buf = nil
  state.results_buf = nil
  state.datasource_tree_buf = nil
  state.editor_win = nil
  state.results_win = nil
  state.datasource_tree_win = nil
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
    if state.datasource_tree_win and vim.api.nvim_win_is_valid(state.datasource_tree_win) then
      vim.api.nvim_win_close(state.datasource_tree_win, false)
      state.datasource_tree_win = nil
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
      state.datasource_tree_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.datasource_tree_win, state.datasource_tree_buf)

      -- Set window width and options
      vim.api.nvim_win_set_width(state.datasource_tree_win, 30)
      vim.api.nvim_set_option_value("winfixbuf", true, { win = state.datasource_tree_win })
      vim.api.nvim_set_option_value("winfixwidth", true, { win = state.datasource_tree_win })

      state.data_source_tree_visible = true

      -- Restore focus to the window that was current before toggling
      if current_win and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end
end

--- Display query results in the results buffer
--- @param results QueryResult Results object with columns, rows, and optional metadata (duration_ms)
function UI.display(results)
  local buf = state.results_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    UI.open()
    UI.display(results)
    return
  end
  vim.bo[buf].modifiable = true

  local lines = {}

  if not results.headers or #results.headers == 0 then
    table.insert(lines, "No results")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    return
  end

  local format = require("abcql.ui.format")
  local rows = results.rows or {}
  local widths = format.calculate_column_widths(results.headers, rows)

  table.insert(lines, format.create_separator(widths))
  table.insert(lines, format.format_row(results.headers, widths))
  table.insert(lines, format.create_separator(widths))

  if #rows == 0 then
    table.insert(lines, " No rows returned ")
    table.insert(lines, format.create_separator(widths))
  else
    for _, row in ipairs(rows) do
      table.insert(lines, format.format_row(row, widths))
    end
    table.insert(lines, format.create_separator(widths))
  end

  table.insert(lines, "")

  local row_count = format.format_row_count(#rows)
  table.insert(lines, string.format(" %s ", row_count))

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

return UI
