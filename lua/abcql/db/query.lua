---@class abcql.db.Query
local Query = {}

---@alias QueryResult {
--- headers: string[],
--- rows: table[],
--- row_count: number,
--- query_type: string?,
--- affected_rows: number?,
--- matched_rows: number?,
--- changed_rows: number?,
--- warnings: number? }

--- Execute a query asynchronously using vim.system
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param callback fun(results: QueryResult|nil, err: string|nil) Called with parsed results or error
--- @param opts? table Optional parameters passed to adapter's get_args
function Query.execute_async(adapter, query, callback, opts)
  opts = opts or {}

  -- Get CLI command and arguments from adapter
  local cmd = adapter:get_command()
  local args = adapter:get_args(query, opts)

  -- Detect if this is a write query
  local is_write = adapter.is_write_query and adapter:is_write_query(query) or false

  -- Execute command asynchronously
  vim.system({ cmd, unpack(args) }, {
    text = true,
    timeout = opts.timeout or 30000, -- 30 second default timeout
  }, function(result)
    vim.schedule(function()
      -- Check for execution errors
      if result.code ~= 0 then
        local error_msg = result.stderr or "Command failed with exit code " .. result.code
        callback(nil, error_msg)
        return
      end

      -- Handle write queries differently
      if is_write and adapter.parse_write_output then
        local ok, write_result = pcall(adapter.parse_write_output, adapter, result.stdout or "")
        if not ok then
          callback(nil, "Failed to parse write output: " .. tostring(write_result))
          return
        end

        callback({
          headers = {},
          rows = {},
          row_count = 0,
          query_type = "write",
          affected_rows = write_result.affected_rows,
          matched_rows = write_result.matched_rows,
          changed_rows = write_result.changed_rows,
          warnings = write_result.warnings,
        }, nil)
        return
      end

      -- Parse output using adapter (for SELECT queries)
      local ok, parsed = pcall(adapter.parse_output, adapter, result.stdout or "")
      if not ok then
        callback(nil, "Failed to parse output: " .. tostring(parsed))
        return
      end

      -- Separate headers from rows (first row is usually headers)
      local headers = {}
      local rows = {}

      if #parsed > 0 then
        if not opts.skip_column_names then
          headers = parsed[1]
          for i = 2, #parsed do
            table.insert(rows, parsed[i])
          end
        else
          rows = parsed
        end
      end

      callback({
        headers = headers,
        rows = rows,
        row_count = #rows,
        query_type = "select",
      }, nil)
    end)
  end)
end

--- Execute a query synchronously (blocking)
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param opts? table Optional parameters
--- @return QueryResult|nil results Parsed results
--- @return string|nil error Error message if failed
function Query.execute_sync(adapter, query, opts)
  opts = opts or {}

  local cmd = adapter:get_command()
  local args = adapter:get_args(query, opts)

  -- Detect if this is a write query
  local is_write = adapter.is_write_query and adapter:is_write_query(query) or false

  -- Execute synchronously
  local result = vim
    .system({ cmd, unpack(args) }, {
      text = true,
      timeout = opts.timeout or 30000,
    })
    :wait()

  if result.code ~= 0 then
    local error_msg = result.stderr or "Command failed with exit code " .. result.code
    return nil, error_msg
  end

  -- Handle write queries differently
  if is_write and adapter.parse_write_output then
    local ok, write_result = pcall(adapter.parse_write_output, adapter, result.stdout or "")
    if not ok then
      return nil, "Failed to parse write output: " .. tostring(write_result)
    end

    return {
      headers = {},
      rows = {},
      row_count = 0,
      query_type = "write",
      affected_rows = write_result.affected_rows,
      matched_rows = write_result.matched_rows,
      changed_rows = write_result.changed_rows,
      warnings = write_result.warnings,
    },
      nil
  end

  local ok, parsed = pcall(adapter.parse_output, adapter, result.stdout or "")
  if not ok then
    return nil, "Failed to parse output: " .. tostring(parsed)
  end

  local headers = {}
  local rows = {}

  if #parsed > 0 then
    if not opts.skip_column_names then
      headers = parsed[1]
      for i = 2, #parsed do
        table.insert(rows, parsed[i])
      end
    else
      rows = parsed
    end
  end

  return {
    headers = headers,
    rows = rows,
    row_count = #rows,
    query_type = "select",
  }, nil
end

--- Extract the SQL query at the cursor position based on semicolon delimiters
--- @param bufnr number|nil Buffer number (defaults to current buffer)
--- @return string The SQL query text (semicolon-delimited)
function Query.get_query_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local start_line = 1
  local end_line = #lines

  for i = cursor_line - 1, 1, -1 do
    if lines[i] and lines[i]:match(";%s*$") then
      start_line = i + 1
      break
    end
  end

  for i = cursor_line, #lines do
    if lines[i] and lines[i]:match(";%s*$") then
      end_line = i
      break
    end
  end

  local query_lines = {}
  for i = start_line, end_line do
    if lines[i] then
      table.insert(query_lines, lines[i])
    end
  end

  local query = table.concat(query_lines, "\n")
  return query:gsub(";%s*$", "")
end

--- Show query preview in a floating window and prompt for execution
--- @param query string The SQL query to preview
--- @param on_confirm function Callback to execute when user confirms
--- @param on_reject function Callback to execute when user cancels
local function show_query_confirmation_prompt(query, on_confirm, on_reject)
  -- Create a scratch buffer for the preview
  local buf = vim.api.nvim_create_buf(false, true)

  -- Split query into lines and set in buffer
  local lines = vim.split(query, "\n")
  -- Trim leading/trailing empty lines
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "filetype", "sql")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  -- Calculate window size based on content
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

  -- Create centered floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Execute Query? (<CR>=Yes, q=No) ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value("wrap", true, { win = win })

  -- Keybinding: Enter to confirm and execute
  vim.keymap.set("n", "<CR>", function()
    vim.api.nvim_win_close(win, true)
    on_confirm()
  end, { buffer = buf, desc = "Execute query" })

  -- Keybinding: q to cancel
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
    on_reject()
  end, { buffer = buf, desc = "Cancel" })

  -- Keybinding: Escape to cancel
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
    vim.notify("Query execution cancelled.", vim.log.levels.INFO)
  end, { buffer = buf, desc = "Cancel" })
end

--- Execute the SQL query located at the current cursor position
function Query.execute_query_at_cursor()
  local query_at_cursor = Query.get_query_at_cursor()
  if query_at_cursor ~= "" then
    -- Show query preview in floating window
    show_query_confirmation_prompt(query_at_cursor, function()
      vim.notify("Executing query:\n" .. query_at_cursor, vim.log.levels.INFO)
      local active_datasource = require("abcql.db").get_active_datasource(vim.api.nvim_get_current_buf())
      Query.execute_async(active_datasource.adapter, query_at_cursor, function(results, err)
        if err then
          vim.notify("Query execution failed: " .. err, vim.log.levels.ERROR)
          return
        end

        require("abcql.ui").display(results)
      end)
    end, function() end)
  else
    vim.notify("No query found at cursor", vim.log.levels.WARN)
  end
end

return Query
