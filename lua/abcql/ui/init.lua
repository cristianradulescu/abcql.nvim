---@class abcql.UI
local UI = {}

---@alias abcql.UI.LayoutOpts { editor_buf: number?, editor_buf_owned: boolean? }
---@alias abcql.UI.DisplayOpts { query: string?, sent_query: string?, datasource: Datasource?, history_position: string?, executed_at: integer? }

-- Augroup for all UI-related autocmds (WinClosed, BufEnter guards)
local AUGROUP = vim.api.nvim_create_augroup("abcql_ui", { clear = true })

local RESULTS_BUF_NAME = "[abcql] Query Results"
local OUTPUT_BUF_NAME = "[abcql] Query Output"

-- State management for the abcql UI
-- This table tracks all buffers, windows, and visibility state for the UI components
local state = {
  -- Buffer IDs for the main components
  editor_buf = nil,
  editor_buf_owned = false,
  results_buf = nil,
  datasource_tree_buf = nil,

  -- The results window has two tabs: "result" shows results_buf (the table), "output" shows
  -- output_buf (the executed query and its outcome)
  output_buf = nil,
  results_tab = "result",

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

  -- Local sort/filter over current_results (abcql.ui.view) and the indices it leaves visible,
  -- in display order; cell features and export resolve rows through visible_rows
  current_view = nil,
  visible_rows = nil,

  -- Display options of the result on screen (live or history), used to re-render it
  display_opts = nil,

  -- Column widths for current results (for cell detection)
  current_widths = nil,

  -- 1-indexed buffer line of the table's top border (cells start 3 lines below)
  table_top_line = nil,

  -- Winbar text for the results window (context of the displayed result), and the arguments it
  -- was built from so switching tabs can rebuild it
  results_winbar = "",
  winbar_args = nil,

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

--- Right-aligned results winbar hint pointing at the `g?` keys legend
local RESULTS_KEYS_HINT = "%= %#AbcqlFooter#g? keys %*"

--- Set the results window winbar (no-op when the window is hidden)
--- @param text string Already-escaped winbar text
local function set_results_winbar(text)
  state.results_winbar = text
  if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.wo[state.results_win].winbar = text
  end
end

--- "name/database" label of the datasource a result came from
--- @param ds Datasource|nil
--- @return string|nil
local function datasource_label(ds)
  if not (ds and ds.name) then
    return nil
  end
  local db = ds.adapter and ds.adapter.config and ds.adapter.config.database
  if db and db ~= "" then
    return ds.name .. "/" .. db
  end
  return ds.name
end

--- Build the results winbar: the Result/Output tabs, then the context of the displayed result
--- @param opts abcql.UI.DisplayOpts
--- @param summary string Result summary (row count, duration...)
--- @param summary_group string Highlight group for the summary
--- @return string
local function build_results_winbar(opts, summary, summary_group)
  local tabs = {}
  for _, tab in ipairs({ { "result", "Result" }, { "output", "Output" } }) do
    local group = state.results_tab == tab[1] and "AbcqlTabActive" or "AbcqlTabInactive"
    table.insert(tabs, "%#" .. group .. "# " .. tab[2] .. " %*")
  end
  -- %< truncates the context, never the tabs, when the window is too narrow
  local parts = { table.concat(tabs) .. "%<" }
  local label = datasource_label(opts.datasource)
  if label then
    local group = opts.datasource.highlight or "AbcqlDatasource"
    table.insert(parts, "%#" .. group .. "#" .. escape_statusline(label) .. "%*")
  end
  if opts.history_position then
    table.insert(parts, "%#AbcqlQueryLabel#" .. escape_statusline(opts.history_position) .. "%*")
  end
  table.insert(parts, "%#" .. summary_group .. "#" .. escape_statusline(summary) .. "%*")
  return table.concat(parts, " %#AbcqlBorder#•%* ") .. RESULTS_KEYS_HINT
end

--- Build and set the results winbar, remembering its arguments for tab switches
--- @param opts abcql.UI.DisplayOpts
--- @param summary string
--- @param summary_group string
local function update_results_winbar(opts, summary, summary_group)
  state.winbar_args = { opts, summary, summary_group }
  set_results_winbar(build_results_winbar(opts, summary, summary_group))
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

--- Create the output buffer (the Output tab: executed query and its outcome)
--- @return number buf Buffer ID
local function create_output_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, OUTPUT_BUF_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  -- SQL highlighting without setting 'filetype', which would attach SQL language servers
  if not pcall(vim.treesitter.start, buf, "sql") then
    vim.bo[buf].syntax = "sql"
  end
  return buf
end

--- Buffer shown by a results tab
--- @param tab "result"|"output"
--- @return number|nil
local function tab_buf(tab)
  return tab == "output" and state.output_buf or state.results_buf
end

--- Show a tab in the results window (remembered while the window is hidden)
--- @param tab "result"|"output"
local function show_results_tab(tab)
  state.results_tab = tab
  local win, buf = state.results_win, tab_buf(tab)
  if win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf) then
    if vim.api.nvim_win_get_buf(win) ~= buf then
      vim.wo[win].winfixbuf = false
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].winfixbuf = true
    end
    -- The query reads better wrapped; table rows must not wrap
    vim.wo[win].wrap = tab == "output"
  end
  if state.winbar_args then
    set_results_winbar(build_results_winbar(unpack(state.winbar_args)))
  end
end

--- Switch the results window between the Result and Output tabs
local function toggle_results_tab()
  show_results_tab(state.results_tab == "output" and "result" or "output")
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

--- Index of the column whose cell contains a byte offset on a table line
--- @param col number 0-indexed byte position
--- @return number|nil
local function column_at_byte(col)
  for i, range in ipairs(cell_byte_ranges()) do
    if col >= range.start and col < range.stop then
      return i
    end
  end
  return nil
end

--- Number of data rows currently rendered (rows left visible by the view)
--- @return number
local function visible_row_count()
  return #(state.visible_rows or {})
end

--- Column under the cursor on any line of the table (header and border lines included)
--- @return number|nil
local function column_at_cursor()
  local results = state.current_results
  if not results or not results.headers or #results.headers == 0 or not state.table_top_line then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  -- top border, header, separator, data rows (or the "no rows" line), bottom border
  local table_end_line = state.table_top_line + 3 + math.max(visible_row_count(), 1)
  if cursor[1] < state.table_top_line or cursor[1] > table_end_line then
    return nil
  end
  return column_at_byte(cursor[2])
end

--- Get the cell content at the current cursor position in the results buffer
--- @return { row_idx: number, col_idx: number, header: string, value: any }|nil Cell info or nil if not on a data cell; row_idx indexes results.rows
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
  local data_end_line = data_start_line + visible_row_count() - 1

  if line_num < data_start_line or line_num > data_end_line then
    return nil -- Not on a data row
  end

  local row_idx = state.visible_rows[line_num - data_start_line + 1]
  local row = row_idx and results.rows[row_idx]
  if not row then
    return nil
  end

  local col_idx = column_at_byte(col)
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
  local row_count = visible_row_count()
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
    executed_at = entry.timestamp,
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

--- The view of the displayed table result, or nil (with a notice) when there is no table
--- @return abcql.View|nil
local function table_view()
  local results = state.current_results
  if not results or not results.headers or #results.headers == 0 or not state.current_view then
    vim.notify("abcql: no result table to sort or filter", vim.log.levels.INFO)
    return nil
  end
  return state.current_view
end

--- Cycle the sort (asc → desc → off) on the column under the cursor
local function sort_by_cursor_column()
  local view = table_view()
  if not view then
    return
  end
  local col = column_at_cursor()
  if not col then
    vim.notify("abcql: no column under cursor", vim.log.levels.INFO)
    return
  end
  require("abcql.ui.view").cycle_sort(view, col)
  UI.refresh_view()
end

--- Keep (or drop, with exclude) the rows whose column equals the cell under the cursor
--- @param exclude boolean
local function filter_by_cell(exclude)
  local view = table_view()
  if not view then
    return
  end
  local cell = get_cell_at_cursor()
  if not cell then
    vim.notify("abcql: no cell under cursor", vim.log.levels.INFO)
    return
  end
  local View = require("abcql.ui.view")
  View.add_filter(view, View.cell_filter(cell.col_idx, cell.value, exclude))
  UI.refresh_view()
end

--- Prompt for a text filter (`text` or `col:text`)
local function filter_by_text()
  local view = table_view()
  if not view then
    return
  end
  vim.ui.input({ prompt = "Filter (text or column:text): " }, function(input)
    local View = require("abcql.ui.view")
    -- The result may have changed while the prompt was open
    if state.current_view ~= view then
      return
    end
    local filter = View.parse_text_filter(input, state.current_results.headers)
    if filter then
      View.add_filter(view, filter)
      UI.refresh_view()
    end
  end)
end

--- Remove the most recently added filter
local function pop_filter()
  local view = table_view()
  if not view then
    return
  end
  if require("abcql.ui.view").pop_filter(view) then
    UI.refresh_view()
  else
    vim.notify("abcql: no filter to remove", vim.log.levels.INFO)
  end
end

--- Drop all filters and the sort
local function clear_view()
  local view = table_view()
  if not view then
    return
  end
  require("abcql.ui.view").clear(view)
  UI.refresh_view()
end

--- Keys of the results window, grouped as the `g?` legend shows them. Each entry is
--- { keys, action, description }; several keys in one entry share the action. Groups marked
--- `output` are bound in the Output tab too, the others only in the Result tab (the table).
--- @type { title: string, output: boolean?, maps: { [1]: string[], [2]: function, [3]: string }[] }[]
local RESULTS_KEYMAPS = {
  {
    title = "Tabs",
    output = true,
    maps = {
      { { "o" }, toggle_results_tab, "switch between Result and Output (executed query)" },
    },
  },
  {
    title = "Cells",
    maps = {
      { { "K", "<CR>" }, show_cell_popup, "show full cell content (y yanks it)" },
      { { "yc" }, yank_cell, "yank cell" },
      { { "yr" }, yank_row, "yank row (tab-separated)" },
      {
        { "<Tab>" },
        function()
          move_cell(1)
        end,
        "next cell",
      },
      {
        { "<S-Tab>" },
        function()
          move_cell(-1)
        end,
        "previous cell",
      },
    },
  },
  {
    title = "Sort & filter",
    maps = {
      { { "s" }, sort_by_cursor_column, "sort by column (asc/desc/off)" },
      {
        { "=" },
        function()
          filter_by_cell(false)
        end,
        "keep rows equal to this cell",
      },
      {
        { "!" },
        function()
          filter_by_cell(true)
        end,
        "drop rows equal to this cell",
      },
      { { "f" }, filter_by_text, "filter rows by text (text or col:text)" },
      { { "F" }, pop_filter, "remove last filter" },
      { { "X" }, clear_view, "clear filters and sort" },
    },
  },
  {
    title = "History",
    output = true,
    maps = {
      { { "<C-o>", "[h" }, history_go_back, "previous query in history" },
      { { "<C-i>", "]h" }, history_go_forward, "next query in history" },
    },
  },
  {
    title = "Query",
    output = true,
    maps = {
      {
        { "<C-c>" },
        function()
          require("abcql.db.query").cancel()
        end,
        "cancel running query",
      },
    },
  },
}

--- Show a floating legend of the results buffer keys (built from RESULTS_KEYMAPS)
local function show_results_legend()
  local lines, marks = {}, {}
  local key_width = 0
  for _, group in ipairs(RESULTS_KEYMAPS) do
    for _, m in ipairs(group.maps) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(table.concat(m[1], " ")))
    end
  end

  for i, group in ipairs(RESULTS_KEYMAPS) do
    if i > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, " " .. group.title)
    table.insert(marks, { #lines - 1, "AbcqlHeader", 0, -1 })
    for _, m in ipairs(group.maps) do
      local keys = table.concat(m[1], " ")
      local pad = string.rep(" ", key_width - vim.fn.strdisplaywidth(keys))
      table.insert(lines, "   " .. keys .. pad .. "  " .. m[3])
      table.insert(marks, { #lines - 1, "Special", 3, 3 + #keys })
    end
  end
  table.insert(lines, "")
  table.insert(lines, " q / <Esc> / g? close")
  table.insert(marks, { #lines - 1, "AbcqlFooter", 0, -1 })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local highlights = require("abcql.ui.highlights")
  for _, mark in ipairs(marks) do
    highlights.add(buf, mark[2], mark[1], mark[3], mark[4])
  end

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 1, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " abcql results keys ",
    title_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

--- Setup keymaps for a results window buffer
--- @param buf number Buffer ID
--- @param output boolean|nil The Output tab's buffer: only the groups marked `output`
local function setup_results_keymaps(buf, output)
  for _, group in ipairs(RESULTS_KEYMAPS) do
    if group.output or not output then
      for _, m in ipairs(group.maps) do
        for _, lhs in ipairs(m[1]) do
          vim.keymap.set("n", lhs, m[2], { buffer = buf, desc = "abcql: " .. m[3] })
        end
      end
    end
  end
  vim.keymap.set("n", "g?", show_results_legend, { buffer = buf, desc = "abcql: show results keys" })
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
  if not (state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf)) then
    state.output_buf = create_output_buffer()
    setup_results_keymaps(state.output_buf, true)
  end

  local current_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("rightbelow split")
  state.results_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.results_win, tab_buf(state.results_tab))
  apply_panel_win_options(state.results_win, { sidescroll = true })
  vim.wo[state.results_win].wrap = state.results_tab == "output"
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
  state.output_buf = create_output_buffer()
  state.datasource_tree_buf = create_data_source_tree_buffer()

  setup_results_keymaps(state.results_buf)
  setup_results_keymaps(state.output_buf, true)
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

  state.results_tab = "result"
  update_results_winbar({}, "no query yet", "AbcqlFooter")
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

      if win == state.results_win and buf ~= state.results_buf and buf ~= state.output_buf then
        redirect(state.results_win, tab_buf(state.results_tab))
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

  if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
    vim.api.nvim_buf_delete(state.output_buf, { force = true })
  end

  if state.datasource_tree_buf and vim.api.nvim_buf_is_valid(state.datasource_tree_buf) then
    vim.api.nvim_buf_delete(state.datasource_tree_buf, { force = true })
  end

  -- Reset state
  state.editor_buf = nil
  state.editor_buf_owned = false
  state.results_buf = nil
  state.output_buf = nil
  state.results_tab = "result"
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
  state.winbar_args = nil
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

--- Render the Output tab: where and when the query ran, the SQL as sent, and its outcome
--- @param opts abcql.UI.DisplayOpts
--- @param outcome string[] Outcome lines (summary, or the error message)
--- @param outcome_group string Highlight group for the outcome
local function render_output(opts, outcome, outcome_group)
  local buf = state.output_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local context = {}
  local label = datasource_label(opts.datasource)
  if label then
    table.insert(context, label)
  end
  if opts.history_position then
    table.insert(context, opts.history_position)
  end
  if opts.executed_at then
    table.insert(context, os.date("%Y-%m-%d %H:%M:%S", opts.executed_at))
  end

  local lines = {}
  if #context > 0 then
    table.insert(lines, "-- " .. table.concat(context, " • "))
  end
  if opts.sent_query and opts.sent_query ~= opts.query then
    table.insert(lines, "-- sent with an auto LIMIT (the editor keeps the query as written)")
  end
  local sql = vim.trim(opts.sent_query or opts.query or "")
  if sql ~= "" then
    vim.list_extend(lines, vim.split(sql, "\n"))
  end
  table.insert(lines, "")
  local outcome_start = #lines
  for _, line in ipairs(outcome) do
    table.insert(lines, "-- " .. line)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local highlights = require("abcql.ui.highlights")
  highlights.clear(buf)
  for i = outcome_start, #lines - 1 do
    highlights.add(buf, outcome_group, i, 0, -1)
  end
end

--- Set the results winbar and the Output tab for a result's outcome
--- @param opts abcql.UI.DisplayOpts
--- @param summary string Short outcome for the winbar
--- @param group string Highlight group for the outcome
--- @param outcome string[]|nil Outcome lines for the Output tab (default: the summary)
local function show_outcome(opts, summary, group, outcome)
  update_results_winbar(opts, summary, group)
  render_output(opts, outcome or { summary }, group)
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
    update_results_winbar(
      opts,
      string.format("running… %s  (<C-c> cancel)", format_duration(elapsed)),
      "AbcqlRunning"
    )
    vim.cmd("redrawstatus")
  end
  render_output(opts, { "running… (<C-c> cancel)" }, "AbcqlRunning")
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
--- @param keep_position boolean|nil Leave the cursor/scroll position alone (re-rendering the same result)
local function set_results_lines(buf, lines, keep_position)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if not keep_position and state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
    vim.api.nvim_win_set_cursor(state.results_win, { 1, 0 })
    vim.api.nvim_win_call(state.results_win, function()
      vim.cmd("normal! zt0")
    end)
  end
end

--- Render a result (or error string) into the results buffer, through state.current_view for tables.
--- Updates the table geometry (current_widths, table_top_line, visible_rows) but not which result
--- is current.
--- @param buf number
--- @param results QueryResult|string
--- @param opts abcql.UI.DisplayOpts
--- @param keep_position boolean|nil Keep the cursor/scroll position (re-rendering the same result)
local function render(buf, results, opts, keep_position)
  -- Clear previous highlights
  local highlights = require("abcql.ui.highlights")
  highlights.clear(buf)

  local lines = {}

  state.table_top_line = nil
  state.visible_rows = nil
  if type(results) ~= "table" then
    state.current_widths = nil
  end

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
    highlights.apply_error_highlights(buf, 0, #lines)
    show_outcome(opts, "error", "AbcqlError", vim.list_extend({ "error:" }, vim.split(results, "\n")))
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
    highlights.apply_write_highlights(buf, 0, #lines)
    show_outcome(opts, summary, "AbcqlSuccess")
    return
  end

  -- Handle SELECT queries and other result sets
  if not results.headers or #results.headers == 0 then
    table.insert(lines, " No results")
    set_results_lines(buf, lines)
    show_outcome(opts, "no results", "AbcqlFooter")
    return
  end

  local format = require("abcql.ui.format")
  local View = require("abcql.ui.view")
  local all_rows = results.rows or {}
  local view = state.current_view
  local visible = View.compute(results, view)
  local rows = View.rows(results, visible)
  -- The sort indicator is part of the header text, so the widths account for it
  local header_labels = View.header_labels(results.headers, view)
  -- Widths come from every loaded row, so the layout doesn't jump while filtering
  local widths = format.calculate_column_widths(header_labels, all_rows, ui_config().cell_max_width)

  -- Store geometry for cell detection (used by the K popup and cell motions)
  state.current_widths = widths
  state.table_top_line = #lines + 1
  state.visible_rows = visible

  table.insert(lines, format.create_top_border(widths))
  table.insert(lines, format.format_row(header_labels, widths))
  table.insert(lines, format.create_separator(widths))

  if #rows == 0 then
    local inner_width = vim.fn.strdisplaywidth(format.format_row(header_labels, widths)) - 2
    local message = #all_rows == 0 and " No rows returned" or " No rows match the filter"
    table.insert(lines, format.border.vertical .. format.pad_right(message, inner_width) .. format.border.vertical)
    table.insert(lines, format.create_bottom_border(widths))
  else
    for _, row in ipairs(rows) do
      table.insert(lines, format.format_row(row, widths))
    end
    table.insert(lines, format.create_bottom_border(widths))
  end

  -- Track where the table ends for footer highlighting
  local table_end_line = #lines

  -- Compact footer: "2 rows • 45ms", or "12 of 1,000 rows • filter: … • sorted by … ▲" with a view
  local footer_parts = {}
  local filtered = view ~= nil and #view.filters > 0
  local loaded = format.format_row_count(#all_rows)
  if results.truncated then
    loaded = string.format("first %s (max_rows limit)", loaded)
  end
  if filtered then
    table.insert(footer_parts, string.format("%s of %s", format.format_number(#rows), loaded))
  elseif results.truncated then
    table.insert(footer_parts, "showing " .. loaded)
  else
    table.insert(footer_parts, loaded)
  end
  vim.list_extend(footer_parts, View.describe(view, results.headers))
  -- The statement was sent with an added LIMIT: at that count the result may be partial.
  local limit_hit = results.auto_limit ~= nil and #all_rows >= results.auto_limit
  if results.auto_limit then
    table.insert(footer_parts, string.format("auto LIMIT %d", results.auto_limit))
  end
  if results.duration_ms then
    table.insert(footer_parts, format_duration(results.duration_ms))
  end
  local summary = table.concat(footer_parts, " • ")
  table.insert(lines, " " .. summary)

  set_results_lines(buf, lines, keep_position)

  -- Apply syntax highlighting
  highlights.apply_highlights(buf, { headers = header_labels, rows = rows }, 0, widths)

  -- Highlight footer lines
  for i = table_end_line, #lines - 1 do
    highlights.apply_footer_highlight(buf, i)
  end

  local summary_hl = (results.truncated or limit_hit) and "AbcqlTruncated" or "AbcqlFooter"
  show_outcome(opts, summary, summary_hl)
end

--- Display query results or errors in the results buffer
--- @param results QueryResult|string Results object with columns, rows, and optional metadata, or error message string
--- @param results_title string? Optional buffer name override (kept for backwards compatibility)
--- @param opts abcql.UI.DisplayOpts? Display options: query for the Output tab, datasource for the winbar
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

  -- A new result is shown in the Result tab; the Output tab tells when it ran
  opts = vim.tbl_extend("keep", opts, { executed_at = os.time() })
  show_results_tab("result")

  -- Store current results for export (only if not an error string); a new result starts with
  -- no sort or filter

  if type(results) == "table" then
    state.current_results = results
    state.current_view = require("abcql.ui.view").new()
    if not opts.history_position then
      state.live_display_opts = opts
    end
  else
    state.current_results = nil
    state.current_view = nil
  end
  state.display_opts = opts

  render(buf, results, opts)
end

--- Re-render the displayed result after its view (sort/filter) changed, keeping the cursor on
--- the same line and column
function UI.refresh_view()
  local buf = state.results_buf
  if not state.current_results or not state.current_view or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = state.results_win
  local has_win = win ~= nil and vim.api.nvim_win_is_valid(win)
  local saved, col_idx
  if has_win then
    saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    col_idx = column_at_byte(saved.col) -- before re-rendering: uses the old widths
  end

  render(buf, state.current_results, state.display_opts or {}, true)

  if has_win then
    local line = math.min(saved.lnum, vim.api.nvim_buf_line_count(buf))
    local range = col_idx and cell_byte_ranges()[col_idx]
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = saved.topline, leftcol = saved.leftcol })
    end)
    vim.api.nvim_win_set_cursor(win, { line, range and range.start or 0 })
  end
end

--- Get the current query results (for export functionality)
--- @return QueryResult|nil The current results, or nil if none available
function UI.get_current_results()
  return state.current_results
end

--- Get the displayed result as the user sees it: the current results with only the rows left
--- visible by the sort/filter view, in display order
--- @return QueryResult|nil results
--- @return boolean filtered True when the view hides some of the loaded rows
function UI.get_visible_results()
  local results = state.current_results
  if not results or not state.visible_rows then
    return results, false
  end
  local visible = vim.tbl_extend("force", {}, results)
  visible.rows = require("abcql.ui.view").rows(results, state.visible_rows)
  return visible, #visible.rows < #(results.rows or {})
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
