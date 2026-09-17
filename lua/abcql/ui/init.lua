---@class abcql.UI
local UI = {}

---@alias abcql.UI.LayoutOpts { editor_buf: number?, editor_buf_owned: boolean? }
---@alias abcql.UI.DisplayOpts { query: string?, datasource: Datasource?, history_position: string? }

-- Augroup for all UI-related autocmds (WinClosed, BufEnter guards)
local AUGROUP = vim.api.nvim_create_augroup("abcql_ui", { clear = true })

local RESULTS_BUF_NAME = "[abcql] Query Results"

-- State management for the abcql UI
-- This table tracks all buffers, windows, and visibility state for the UI components
local state = {
  -- Buffer IDs for the main components
  editor_buf = nil,
  editor_buf_owned = false,
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

  -- Current query results (for export functionality)
  current_results = nil,

  -- Column widths for current results (for cell detection)
  current_widths = nil,

  -- 1-indexed buffer line of the table's top border (cells start 3 lines below)
  table_top_line = nil,

  -- Winbar text for the results window (context of the displayed result)
  results_winbar = "",

  -- Display options of the live (non-history) result, restored when leaving history
  live_display_opts = nil,

  -- Timer driving the "Running…" indicator
  running_timer = nil,
}

--- Read the `ui` config section with defaults for anything missing
--- @return abcql.Config.UI
local function ui_config()
  local defaults = { results_height = 0.4, tree_width = 30, icons = true, cell_max_width = 50 }
  local ok, config = pcall(require, "abcql.config")
  if not ok or type(config.ui) ~= "table" then
    return defaults
  end
  return vim.tbl_extend("keep", config.ui, defaults)
end

--- Check if the UI layout is valid (editor window exists and is usable)
--- @return boolean
function UI.is_valid()
  return state.editor_win ~= nil
    and vim.api.nvim_win_is_valid(state.editor_win)
    and state.editor_buf ~= nil
    and vim.api.nvim_buf_is_valid(state.editor_buf)
end

--- Escape a string for use inside 'winbar' / 'statusline'
--- @param text string
--- @return string
local function escape_statusline(text)
  return (text:gsub("%%", "%%%%"))
end

--- Resolve the results window height from config (fraction of the screen or absolute lines)
--- @return number
local function results_height()
  local configured = ui_config().results_height
  local total_height = vim.o.lines - vim.o.cmdheight - 2 -- Account for statusline and tabline
  if type(configured) ~= "number" or configured <= 0 then
    configured = 0.4
  end
  if configured < 1 then
    return math.max(3, math.floor(total_height * configured))
  end
  return math.max(3, math.min(math.floor(configured), total_height - 3))
end

--- Create the query editor buffer
--- @return number buf Buffer ID
local function create_editor_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "[abcql] SQL console")
  vim.bo[buf].filetype = "sql"
  vim.bo[buf].buftype = ""
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

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

--- Apply the standard window-local options for a panel window
--- @param win number
--- @param opts? { sidescroll: boolean }
local function apply_panel_win_options(win, opts)
  opts = opts or {}
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].spell = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].colorcolumn = ""
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  if opts.sidescroll then
    -- 'sidescroll' itself is global (Neovim defaults it to 1); only the offset is window-local
    vim.wo[win].sidescrolloff = 5
  end
end

--- Set the results window winbar (no-op when the window is hidden)
--- @param text string Already-escaped winbar text
local function set_results_winbar(text)
  state.results_winbar = text
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.wo[state.results_win].winbar = text
  end
end

--- Create the results buffer
--- @return number buf Buffer ID
local function create_results_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, RESULTS_BUF_NAME)
  vim.bo[buf].buftype = "nofile"
  -- "hide", not "wipe": the panel can be toggled off and on without losing the buffer
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false -- Results are read-only

  -- Setup highlight groups
  require("abcql.ui.highlights").setup()

  return buf
end

--- Byte offsets of each data cell on a table line.
--- Format: │ col1 │ col2 │ col3 │ — each │ is 3 bytes in UTF-8.
--- @return { start: number, stop: number }[] 0-indexed byte ranges (stop exclusive)
local function cell_byte_ranges()
  local widths = state.current_widths or {}
  local ranges = {}
  local byte_pos = 0
  for _, width in ipairs(widths) do
    local cell_start = byte_pos + 4 -- "│ " = 3 bytes + 1 space
    local cell_end = cell_start + width
    table.insert(ranges, { start = cell_start, stop = cell_end })
    byte_pos = cell_end + 1 -- trailing space before the next │
  end
  return ranges
end

--- Get the cell content at the current cursor position in the results buffer
--- @return { row_idx: number, col_idx: number, header: string, value: any }|nil Cell info or nil if not on a data cell
local function get_cell_at_cursor()
  local results = state.current_results
  local widths = state.current_widths

  if not results or not widths or not results.headers or #results.headers == 0 or not state.table_top_line then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1] -- 1-indexed
  local col = cursor[2] -- 0-indexed byte position

  -- top border, header row, separator, then data rows
  local data_start_line = state.table_top_line + 3
  local row_count = #(results.rows or {})
  local data_end_line = data_start_line + row_count - 1

  if line_num < data_start_line or line_num > data_end_line then
    return nil -- Not on a data row
  end

  local row_idx = line_num - data_start_line + 1
  local row = results.rows[row_idx]
  if not row then
    return nil
  end

  local col_idx = nil
  for i, range in ipairs(cell_byte_ranges()) do
    if col >= range.start and col < range.stop then
      col_idx = i
      break
    end
  end

  if not col_idx then
    return nil
  end

  return {
    row_idx = row_idx,
    col_idx = col_idx,
    header = results.headers[col_idx],
    value = row[col_idx],
  }
end

--- Convert a cell value to its display string
--- @param value any
--- @return string
local function cell_to_string(value)
  if value == nil then
    return "NULL"
  end
  return tostring(value)
end

--- Show a floating popup with the full cell content
local function show_cell_popup()
  local cell = get_cell_at_cursor()

  if not cell then
    vim.notify("abcql: no cell under cursor", vim.log.levels.INFO)
    return
  end

  local value = cell_to_string(cell.value)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local lines = vim.split(value, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(20, vim.o.lines - 10)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. cell.header .. " (q close, y yank) ",
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, { buffer = buf })
  end
  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', value)
    vim.fn.setreg("+", value)
    close()
    vim.notify("abcql: cell yanked", vim.log.levels.INFO)
  end, { buffer = buf, desc = "Yank full cell value" })
end

--- Yank the cell under the cursor to the unnamed and clipboard registers
local function yank_cell()
  local cell = get_cell_at_cursor()
  if not cell then
    vim.notify("abcql: no cell under cursor", vim.log.levels.INFO)
    return
  end
  local value = cell_to_string(cell.value)
  vim.fn.setreg('"', value)
  vim.fn.setreg("+", value)
  vim.notify("abcql: yanked " .. cell.header, vim.log.levels.INFO)
end

--- Yank the row under the cursor as tab-separated values
local function yank_row()
  local cell = get_cell_at_cursor()
  local results = state.current_results
  if not cell or not results then
    vim.notify("abcql: no row under cursor", vim.log.levels.INFO)
    return
  end
  local values = {}
  for i = 1, #results.headers do
    table.insert(values, cell_to_string(results.rows[cell.row_idx][i]))
  end
  local text = table.concat(values, "\t")
  vim.fn.setreg('"', text)
  vim.fn.setreg("+", text)
  vim.notify(string.format("abcql: yanked row %d", cell.row_idx), vim.log.levels.INFO)
end

--- Move the cursor to the next/previous cell (wrapping across rows)
--- @param direction 1|-1
local function move_cell(direction)
  local results = state.current_results
  if not results or not state.table_top_line or not state.current_widths or #state.current_widths == 0 then
    return
  end
  local ranges = cell_byte_ranges()
  local data_start_line = state.table_top_line + 3
  local row_count = #(results.rows or {})
  if row_count == 0 then
    return
  end
  local data_end_line = data_start_line + row_count - 1

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line, col = cursor[1], cursor[2]
  if line < data_start_line then
    line = data_start_line
    col = -1
  elseif line > data_end_line then
    line = data_end_line
    col = math.huge
  end

  local col_idx = nil
  for i, range in ipairs(ranges) do
    if col < range.stop then
      col_idx = i
      break
    end
  end
  if col_idx == nil then
    col_idx = #ranges + 1
  end
  if direction > 0 then
    -- When the cursor sits in the gap before a cell, "next" lands on that cell itself.
    local in_gap = ranges[col_idx] ~= nil and col < ranges[col_idx].start
    if not in_gap then
      col_idx = col_idx + 1
    end
    if col_idx > #ranges then
      col_idx = 1
      line = line + 1
      if line > data_end_line then
        line = data_start_line
      end
    end
  else
    col_idx = col_idx - 1
    if col_idx < 1 then
      col_idx = #ranges
      line = line - 1
      if line < data_start_line then
        line = data_end_line
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, { line, ranges[col_idx].start })
end

--- Display a history entry (or the live result when back at the newest)
--- @param entry table|nil
--- @param is_latest boolean|nil
local function display_history_entry(entry, is_latest)
  local History = require("abcql.history")
  if is_latest then
    if state.current_results then
      UI.display(state.current_results, nil, state.live_display_opts)
    end
    return
  end
  if not entry then
    return
  end
  local pos, total = History.get_position()
  local display_opts = {
    query = entry.query,
    history_position = string.format("history %d/%d", pos, total),
    datasource = { name = entry.datasource, adapter = { config = { database = entry.database } } },
  }
  if entry.error then
    UI.display(entry.error, nil, display_opts)
  elseif entry.result then
    UI.display(entry.result, nil, display_opts)
  end
end

--- Navigate to previous query in history and display it
local function history_go_back()
  local entry = require("abcql.history").go_back()
  display_history_entry(entry, false)
end

--- Navigate to next query in history (toward latest) and display it
local function history_go_forward()
  local entry, is_latest = require("abcql.history").go_forward()
  display_history_entry(entry, is_latest)
end

--- Setup keymaps for the results buffer
--- @param buf number Buffer ID
local function setup_results_keymaps(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc })
  end

  map("K", show_cell_popup, "abcql: show full cell content")
  map("<CR>", show_cell_popup, "abcql: show full cell content")
  map("yc", yank_cell, "abcql: yank cell")
  map("yr", yank_row, "abcql: yank row (tab-separated)")
  map("<Tab>", function()
    move_cell(1)
  end, "abcql: next cell")
  map("<S-Tab>", function()
    move_cell(-1)
  end, "abcql: previous cell")
  map("<C-o>", history_go_back, "abcql: previous query in history")
  map("<C-i>", history_go_forward, "abcql: next query in history")
  map("[h", history_go_back, "abcql: previous query in history")
  map("]h", history_go_forward, "abcql: next query in history")
  map("<C-c>", function()
    require("abcql.db.query").cancel()
  end, "abcql: cancel running query")
end

--- Create the data source tree buffer
--- @return number buf Buffer ID
local function create_data_source_tree_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "[abcql] Data Sources")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

--- Name of the datasource attached to the editor buffer, if any
--- @return string|nil
local function active_datasource_name()
  if not state.editor_buf or not vim.api.nvim_buf_is_valid(state.editor_buf) then
    return nil
  end
  local ds = require("abcql.db").get_active_datasource(state.editor_buf)
  return ds and ds.name or nil
end

--- Refresh the datasource tree display
--- Preserves tree state (expanded nodes and loaded children) across refreshes
--- Only builds a new tree from registry if no tree exists yet
function UI.refresh_tree()
  local buf = state.datasource_tree_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local Tree = require("abcql.ui.tree")
  local root = Tree.get_root()

  if not root then
    local db = require("abcql.db")
    root = Tree.build_from_registry(db.connectionRegistry)
  end

  local lines, highlights = Tree.render(root, { active_datasource = active_datasource_name() })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  Tree.apply_highlights(buf, highlights)
end

--- Insert text at the cursor position of the editor window
--- @param text string
local function insert_into_editor(text)
  if not UI.is_valid() then
    return
  end
  vim.api.nvim_set_current_win(state.editor_win)
  local cursor = vim.api.nvim_win_get_cursor(state.editor_win)
  local row, col = cursor[1] - 1, cursor[2]
  local line = vim.api.nvim_buf_get_lines(state.editor_buf, row, row + 1, false)[1] or ""
  -- In normal mode the cursor sits on a character; insert after it unless the line is empty.
  local insert_col = (#line == 0) and 0 or math.min(col + 1, #line)
  vim.api.nvim_buf_set_text(state.editor_buf, row, insert_col, row, insert_col, { text })
  vim.api.nvim_win_set_cursor(state.editor_win, { row + 1, insert_col + #text - 1 })
end

--- Setup keymaps for the datasource tree buffer
--- @param buf number Buffer ID
local function setup_tree_keymaps(buf)
  local Tree = require("abcql.ui.tree")

  local function node_at_cursor()
    return Tree.get_node_at_line(vim.api.nvim_win_get_cursor(0)[1])
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc })
  end

  map("<CR>", function()
    local node = node_at_cursor()
    if node then
      Tree.toggle_node(node, UI.refresh_tree)
    end
  end, "abcql: expand/collapse node")

  map("r", UI.refresh_tree, "abcql: redraw tree")

  map("R", function()
    local node = node_at_cursor()
    if node then
      Tree.reload_node(node, UI.refresh_tree)
    end
  end, "abcql: reload node from the database")

  map("y", function()
    local node = node_at_cursor()
    local name = node and Tree.qualified_name(node)
    if not name then
      vim.notify("abcql: nothing to yank here", vim.log.levels.INFO)
      return
    end
    vim.fn.setreg('"', name)
    vim.fn.setreg("+", name)
    vim.notify("abcql: yanked " .. name, vim.log.levels.INFO)
  end, "abcql: yank qualified name")

  map("i", function()
    local node = node_at_cursor()
    local name = node and Tree.qualified_name(node)
    if not name then
      vim.notify("abcql: nothing to insert here", vim.log.levels.INFO)
      return
    end
    insert_into_editor(name)
  end, "abcql: insert name into editor")

  map("f", function()
    Tree.filter(function(node)
      UI.refresh_tree()
      local line = Tree.get_line_of_node(node)
      if line and state.datasource_tree_win and vim.api.nvim_win_is_valid(state.datasource_tree_win) then
        vim.api.nvim_win_set_cursor(state.datasource_tree_win, { line, 0 })
      end
    end)
  end, "abcql: find a loaded table")

  map("<leader>Se", function()
    local node = node_at_cursor()
    if node then
      Tree.browse_table_data(node, function() end)
    end
  end, "abcql: browse table data")
end

--- Register the WinClosed autocmd for the results window
local function watch_results_window()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    pattern = tostring(state.results_win),
    once = true,
    callback = function()
      state.results_win = nil
      state.results_visible = false
    end,
  })
end

--- Register the WinClosed autocmd for the tree window
local function watch_tree_window()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    pattern = tostring(state.datasource_tree_win),
    once = true,
    callback = function()
      state.datasource_tree_win = nil
      state.data_source_tree_visible = false
    end,
  })
end

--- Open (or re-open) the results window below the editor
--- @return boolean shown
local function open_results_window()
  if not (state.editor_win and vim.api.nvim_win_is_valid(state.editor_win)) then
    return false
  end
  if not (state.results_buf and vim.api.nvim_buf_is_valid(state.results_buf)) then
    state.results_buf = create_results_buffer()
    setup_results_keymaps(state.results_buf)
  end

  local current_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("rightbelow split")
  state.results_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.results_win, state.results_buf)
  apply_panel_win_options(state.results_win, { sidescroll = true })
  vim.api.nvim_win_set_height(state.results_win, results_height())
  vim.wo[state.results_win].winfixbuf = true
  vim.wo[state.results_win].winbar = state.results_winbar
  state.results_visible = true
  watch_results_window()

  if current_win and vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
  return true
end

--- Open the abcql UI
--- Creates a two-panel layout by default: query editor (top), results (bottom)
--- The data source tree panel can be opened with UI.toggle_tree()
--- The layout uses splits with winfixbuf to prevent buffer mixing
--- @param opts? abcql.UI.LayoutOpts Optional parameters
function UI.open(opts)
  opts = opts or {}

  -- If no editor buffer is provided, check if the current buffer is a SQL file to use instead, or create one
  if nil == opts.editor_buf then
    local current_buf = vim.api.nvim_get_current_buf()
    local is_sql_file = vim.bo[current_buf].filetype == "sql" and vim.bo[current_buf].buftype == ""
    if not is_sql_file then
      vim.ui.select({ "Yes", "No" }, {
        prompt = "abcql UI requires a SQL file buffer. Create one?",
      }, function(choice)
        if choice == "Yes" then
          local scratch_buf = create_editor_buffer()
          UI.open({ editor_buf = scratch_buf, editor_buf_owned = true })
        end
      end)

      return
    end

    UI.open({ editor_buf = current_buf, editor_buf_owned = false })
    return
  end

  -- If the UI is already open, focus the editor window instead of re-creating
  if UI.is_valid() then
    vim.api.nvim_set_current_win(state.editor_win)
    return
  end

  -- Set editor buffer based on provided buffer
  if opts.editor_buf ~= nil and vim.api.nvim_buf_is_valid(opts.editor_buf) then
    state.editor_buf = opts.editor_buf
    state.editor_buf_owned = opts.editor_buf_owned == true
  else
    vim.notify("abcql UI is missing the query editor", vim.log.levels.ERROR)
    return
  end

  state.results_buf = create_results_buffer()
  state.datasource_tree_buf = create_data_source_tree_buffer()

  setup_results_keymaps(state.results_buf)
  setup_tree_keymaps(state.datasource_tree_buf)

  -- Register display callback to break circular dependency (tree -> ui)
  require("abcql.ui.tree").set_display_fn(function(results, title, display_opts)
    UI.display(results, title, display_opts)
  end)

  UI.refresh_tree()

  -- Create the window layout
  -- Layout structure:
  --   +---------------------------+
  --   | Query Editor              |
  --   +---------------------------+
  --   | Query Results             |
  --   +---------------------------+

  -- The current window will become the editor window
  -- Don't hijack floating windows — create a new normal window first
  local cur_win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(cur_win)
  if win_config.relative and win_config.relative ~= "" then
    vim.cmd("enew")
    cur_win = vim.api.nvim_get_current_win()
  end

  state.editor_win = cur_win
  vim.api.nvim_win_set_buf(state.editor_win, state.editor_buf)

  state.results_winbar = "%#AbcqlWinbarLabel# results %* no query yet"
  open_results_window()

  -- Return focus to the editor window
  vim.api.nvim_set_current_win(state.editor_win)

  -- Initialize visibility state
  state.data_source_tree_visible = false

  -- Register WinClosed autocmds to sync state when windows are closed externally
  vim.api.nvim_create_autocmd("WinClosed", {
    group = AUGROUP,
    pattern = tostring(state.editor_win),
    once = true,
    callback = function()
      -- Editor is the anchor — tear down the entire layout
      state.editor_win = nil
      UI.close()
    end,
  })

  -- BufEnter guard: redirect foreign buffers away from results/tree windows
  vim.api.nvim_create_autocmd("BufEnter", {
    group = AUGROUP,
    callback = function(args)
      local win = vim.api.nvim_get_current_win()
      local buf = args.buf

      local function redirect(panel_win, panel_buf)
        vim.schedule(function()
          if
            panel_win
            and vim.api.nvim_win_is_valid(panel_win)
            and panel_buf
            and vim.api.nvim_buf_is_valid(panel_buf)
          then
            vim.api.nvim_win_set_buf(panel_win, panel_buf)
          end
          -- Redirect the intruding buffer to the editor window
          if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_win_set_buf(state.editor_win, buf)
            vim.api.nvim_set_current_win(state.editor_win)
          end
        end)
      end

      if win == state.results_win and buf ~= state.results_buf then
        redirect(state.results_win, state.results_buf)
      elseif win == state.datasource_tree_win and buf ~= state.datasource_tree_buf then
        redirect(state.datasource_tree_win, state.datasource_tree_buf)
      end
    end,
  })

  -- Keep the tree's "active datasource" marker in sync with the editor buffer
  vim.api.nvim_create_autocmd("User", {
    group = AUGROUP,
    pattern = "AbcqlDatasourceAttached",
    callback = function()
      UI.refresh_tree()
    end,
  })
end

--- Stop the running indicator timer, if any
local function stop_running_timer()
  if state.running_timer then
    state.running_timer:stop()
    state.running_timer:close()
    state.running_timer = nil
  end
end

--- Close the ABCQL UI
--- Closes all abcql windows. Keeps externally owned editor buffers, and
--- deletes the editor buffer only when abcql created a temporary one.
function UI.close()
  -- Clear all UI autocmds first to prevent re-entrant callbacks
  vim.api.nvim_clear_autocmds({ group = AUGROUP })
  stop_running_timer()

  -- Disable winfix options on close to prevent issues with buffers not related to the plugin
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.wo[state.results_win].winfixbuf = false
  end
  if state.datasource_tree_win and vim.api.nvim_win_is_valid(state.datasource_tree_win) then
    vim.wo[state.datasource_tree_win].winfixbuf = false
    vim.wo[state.datasource_tree_win].winfixwidth = false
  end

  -- Close abcql side windows first
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.api.nvim_win_close(state.results_win, false)
  end

  if state.datasource_tree_win and vim.api.nvim_win_is_valid(state.datasource_tree_win) then
    vim.api.nvim_win_close(state.datasource_tree_win, false)
  end

  -- Editor ownership semantics:
  -- - Keep existing user buffers (opened before abcql)
  -- - Delete only temporary editor buffers created by abcql itself
  if state.editor_buf_owned and state.editor_buf and vim.api.nvim_buf_is_valid(state.editor_buf) then
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
  state.editor_buf_owned = false
  state.results_buf = nil
  state.datasource_tree_buf = nil
  state.editor_win = nil
  state.results_win = nil
  state.datasource_tree_win = nil
  state.results_visible = false
  state.data_source_tree_visible = false
  state.current_results = nil
  state.current_widths = nil
  state.table_top_line = nil
  state.results_winbar = ""
end

--- Make sure the results window is visible (re-opening it if it was toggled off)
--- @return boolean visible
function UI.show_results()
  if not UI.is_valid() then
    return false
  end
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    return true
  end
  return open_results_window()
end

--- Toggle visibility of the query results panel
--- If visible, closes the window but keeps the buffer
--- If hidden, recreates the window in the correct position
function UI.toggle_results()
  if not UI.is_valid() then
    vim.notify("abcql UI is not open", vim.log.levels.WARN)
    return
  end

  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    -- Hide the results panel
    vim.api.nvim_win_close(state.results_win, false)
    state.results_win = nil
    state.results_visible = false
  else
    open_results_window()
  end
end

--- Open the tree window to the right of the editor
local function open_tree_window()
  if not (state.editor_win and vim.api.nvim_win_is_valid(state.editor_win)) then
    return
  end
  if not (state.datasource_tree_buf and vim.api.nvim_buf_is_valid(state.datasource_tree_buf)) then
    state.datasource_tree_buf = create_data_source_tree_buffer()
    setup_tree_keymaps(state.datasource_tree_buf)
  end

  local current_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("vertical rightbelow split")
  state.datasource_tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.datasource_tree_win, state.datasource_tree_buf)
  vim.api.nvim_win_set_width(state.datasource_tree_win, ui_config().tree_width)
  apply_panel_win_options(state.datasource_tree_win)
  vim.wo[state.datasource_tree_win].winfixbuf = true
  vim.wo[state.datasource_tree_win].winfixwidth = true
  vim.wo[state.datasource_tree_win].winbar = "%#AbcqlWinbarLabel# data sources %*"
  state.data_source_tree_visible = true
  watch_tree_window()

  UI.refresh_tree()

  -- Auto-expand the datasource attached to the editor buffer (and its DSN database)
  local Tree = require("abcql.ui.tree")
  local ds_name = active_datasource_name()
  if ds_name then
    Tree.expand_datasource(ds_name, UI.refresh_tree)
  end

  if current_win and vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
end

--- Toggle visibility of the data source tree panel
--- If visible, closes the window but keeps the buffer
--- If hidden, recreates the window in the correct position
function UI.toggle_tree()
  if not UI.is_valid() then
    vim.notify("abcql UI is not open", vim.log.levels.WARN)
    return
  end

  if state.datasource_tree_win and vim.api.nvim_win_is_valid(state.datasource_tree_win) then
    vim.api.nvim_win_close(state.datasource_tree_win, false)
    state.datasource_tree_win = nil
    state.data_source_tree_visible = false
  else
    open_tree_window()
  end
end

--- Format duration in milliseconds to a human-readable string
--- @param duration_ms number Duration in milliseconds
--- @return string Formatted duration (e.g., "1.23s", "456ms")
local function format_duration(duration_ms)
  if duration_ms >= 1000 then
    return string.format("%.2fs", duration_ms / 1000)
  else
    return string.format("%dms", math.floor(duration_ms))
  end
end

--- First non-comment line of a query, collapsed to one line and shortened
--- @param query string|nil
--- @param max number
--- @return string|nil
local function query_summary(query, max)
  if not query then
    return nil
  end
  local text = require("abcql.db.statements").strip_leading_comments(query)
  text = text:gsub("%s+", " ")
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  if vim.fn.strdisplaywidth(text) > max then
    text = require("abcql.ui.format").truncate(text, max)
  end
  return text
end

--- Build the results winbar for a displayed result
--- @param opts abcql.UI.DisplayOpts
--- @param summary string Result summary (row count, duration...)
--- @param summary_group string Highlight group for the summary
--- @return string
local function build_results_winbar(opts, summary, summary_group)
  local parts = { "%#AbcqlWinbarLabel# results %*" }
  local ds = opts.datasource
  if ds and ds.name then
    local group = ds.highlight or "AbcqlDatasource"
    local label = ds.name
    local db = ds.adapter and ds.adapter.config and ds.adapter.config.database
    if db and db ~= "" then
      label = label .. "/" .. db
    end
    table.insert(parts, "%#" .. group .. "#" .. escape_statusline(label) .. "%*")
  end
  if opts.history_position then
    table.insert(parts, "%#AbcqlQueryLabel#" .. escape_statusline(opts.history_position) .. "%*")
  end
  local q = query_summary(opts.query, math.max(20, vim.o.columns - 60))
  if q then
    table.insert(parts, escape_statusline(q))
  end
  table.insert(parts, "%#" .. summary_group .. "#" .. escape_statusline(summary) .. "%*")
  return table.concat(parts, " %#AbcqlBorder#•%* ")
end

--- Show the "Running…" indicator in the results winbar
--- @param query string
--- @param datasource Datasource
function UI.set_running(query, datasource)
  if not UI.is_valid() then
    UI.open()
  end
  UI.show_results()
  stop_running_timer()

  local started = vim.uv.hrtime()
  local opts = { query = query, datasource = datasource }
  local function refresh()
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    set_results_winbar(
      build_results_winbar(
        opts,
        string.format("running… %s  (<C-c> cancel)", format_duration(elapsed)),
        "AbcqlRunning"
      )
    )
    vim.cmd("redrawstatus")
  end
  refresh()

  state.running_timer = vim.uv.new_timer()
  state.running_timer:start(250, 250, vim.schedule_wrap(refresh))
end

--- Remove the running indicator (the next display() call sets the final winbar)
function UI.clear_running()
  stop_running_timer()
end

--- Write lines to the results buffer and reset the view to the top-left
--- @param buf number
--- @param lines string[]
local function set_results_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.api.nvim_win_set_cursor(state.results_win, { 1, 0 })
    vim.api.nvim_win_call(state.results_win, function()
      vim.cmd("normal! zt0")
    end)
  end
end

--- Display query results or errors in the results buffer
--- @param results QueryResult|string Results object with columns, rows, and optional metadata, or error message string
--- @param results_title string? Optional buffer name override (kept for backwards compatibility)
--- @param opts abcql.UI.DisplayOpts? Display options: query shown above the results, datasource for the winbar
function UI.display(results, results_title, opts)
  opts = opts or {}
  stop_running_timer()

  if not UI.is_valid() then
    UI.open()
    if not UI.is_valid() then
      -- The user declined to create an editor buffer; nothing to draw into.
      return
    end
  end
  UI.show_results()

  local buf = state.results_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if results_title ~= nil then
    pcall(vim.api.nvim_buf_set_name, buf, results_title)
  end

  -- Clear previous highlights
  local highlights = require("abcql.ui.highlights")
  highlights.clear(buf)

  local lines = {}
  local query_line_count = 0

  -- History browsing: show the full query above the results
  if opts.history_position and opts.query then
    table.insert(lines, "")
    table.insert(lines, " Query:")
    table.insert(lines, " ──────")
    for _, line in ipairs(vim.split(opts.query, "\n")) do
      table.insert(lines, "   " .. line)
    end
    table.insert(lines, "")
    table.insert(lines, " Results:")
    table.insert(lines, " ────────")
    query_line_count = #lines
  end

  -- Store current results for export (only if not an error string)
  if type(results) == "table" then
    state.current_results = results
    if not opts.history_position then
      state.live_display_opts = opts
    end
  else
    state.current_results = nil
    state.current_widths = nil
  end
  state.table_top_line = nil

  -- Handle error messages (when results is a string)
  if type(results) == "string" then
    table.insert(lines, "")
    table.insert(lines, " ✖ Query execution failed")
    table.insert(lines, "")

    local max_width = 80
    for _, line in ipairs(vim.split(results, "\n")) do
      if #line <= max_width then
        table.insert(lines, " " .. line)
      else
        -- Simple word wrapping
        local current_line = ""
        for word in line:gmatch("%S+") do
          if #current_line + #word + 1 <= max_width then
            current_line = current_line .. (current_line == "" and "" or " ") .. word
          else
            if current_line ~= "" then
              table.insert(lines, " " .. current_line)
            end
            current_line = word
          end
        end
        if current_line ~= "" then
          table.insert(lines, " " .. current_line)
        end
      end
    end

    table.insert(lines, "")

    set_results_lines(buf, lines)
    if query_line_count > 0 then
      highlights.apply_query_highlights(buf, query_line_count)
    end
    highlights.apply_error_highlights(buf, query_line_count, #lines)
    set_results_winbar(build_results_winbar(opts, "error", "AbcqlError"))
    return
  end

  -- Handle write queries (INSERT, UPDATE, DELETE)
  if results.query_type == "write" then
    table.insert(lines, "")
    table.insert(lines, " ✓ Query executed successfully")
    table.insert(lines, "")

    local affected = results.affected_rows or 0
    local summary_parts = {}

    if results.matched_rows and results.matched_rows > 0 then
      table.insert(summary_parts, string.format("%d matched", results.matched_rows))
      table.insert(summary_parts, string.format("%d changed", results.changed_rows or 0))
    else
      local row_word = affected == 1 and "row" or "rows"
      table.insert(summary_parts, string.format("%d %s affected", affected, row_word))
    end

    if results.warnings and results.warnings > 0 then
      table.insert(summary_parts, string.format("%d warnings", results.warnings))
    end

    if results.duration_ms then
      table.insert(summary_parts, format_duration(results.duration_ms))
    end

    local summary = table.concat(summary_parts, " • ")
    table.insert(lines, " " .. summary)
    table.insert(lines, "")

    set_results_lines(buf, lines)
    if query_line_count > 0 then
      highlights.apply_query_highlights(buf, query_line_count)
    end
    highlights.apply_write_highlights(buf, query_line_count, #lines)
    set_results_winbar(build_results_winbar(opts, summary, "AbcqlSuccess"))
    return
  end

  -- Handle SELECT queries and other result sets
  if not results.headers or #results.headers == 0 then
    table.insert(lines, " No results")
    set_results_lines(buf, lines)
    set_results_winbar(build_results_winbar(opts, "no results", "AbcqlFooter"))
    return
  end

  local format = require("abcql.ui.format")
  local rows = results.rows or {}
  local widths = format.calculate_column_widths(results.headers, rows, ui_config().cell_max_width)

  -- Store widths for cell detection (used by the K popup and cell motions)
  state.current_widths = widths
  state.table_top_line = #lines + 1

  table.insert(lines, format.create_top_border(widths))
  table.insert(lines, format.format_row(results.headers, widths))
  table.insert(lines, format.create_separator(widths))

  if #rows == 0 then
    local inner_width = vim.fn.strdisplaywidth(format.format_row(results.headers, widths)) - 2
    table.insert(
      lines,
      format.border.vertical .. format.pad_right(" No rows returned", inner_width) .. format.border.vertical
    )
    table.insert(lines, format.create_bottom_border(widths))
  else
    for _, row in ipairs(rows) do
      table.insert(lines, format.format_row(row, widths))
    end
    table.insert(lines, format.create_bottom_border(widths))
  end

  -- Track where the table ends for footer highlighting
  local table_end_line = #lines

  -- Compact footer: "2 rows • 45ms"
  local footer_parts = {}
  if results.truncated then
    table.insert(footer_parts, string.format("showing first %s (max_rows limit)", format.format_row_count(#rows)))
  else
    table.insert(footer_parts, format.format_row_count(#rows))
  end
  if results.duration_ms then
    table.insert(footer_parts, format_duration(results.duration_ms))
  end
  local summary = table.concat(footer_parts, " • ")
  table.insert(lines, " " .. summary)

  set_results_lines(buf, lines)

  -- Apply syntax highlighting
  if query_line_count > 0 then
    highlights.apply_query_highlights(buf, query_line_count)
  end
  highlights.apply_highlights(buf, results, query_line_count, widths)

  -- Highlight footer lines
  for i = table_end_line, #lines - 1 do
    highlights.apply_footer_highlight(buf, i)
  end

  set_results_winbar(build_results_winbar(opts, summary, results.truncated and "AbcqlTruncated" or "AbcqlFooter"))
end

--- Get the current query results (for export functionality)
--- @return QueryResult|nil The current results, or nil if none available
function UI.get_current_results()
  return state.current_results
end

--- Whether the results panel is currently visible
--- @return boolean
function UI.results_visible()
  return state.results_win ~= nil and vim.api.nvim_win_is_valid(state.results_win)
end

--- Whether the tree panel is currently visible
--- @return boolean
function UI.tree_visible()
  return state.datasource_tree_win ~= nil and vim.api.nvim_win_is_valid(state.datasource_tree_win)
end

--- Editor buffer currently anchoring the layout (nil when closed)
--- @return number|nil
function UI.get_editor_buf()
  return state.editor_buf
end

return UI
