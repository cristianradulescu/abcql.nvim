local Backend = require("abcql.backend")
local Statements = require("abcql.db.statements")

---@class abcql.db.Query
local Query = {}

---@alias QueryResult { headers: string[], rows: table[], row_count: number, query_type: string?, affected_rows: number?, matched_rows: number?, changed_rows: number?, warnings: number?, duration_ms: number?, truncated: boolean? }

--- Currently running query, if any
--- @type { handle: table|nil, query: string, datasource: Datasource, started: number }|nil
local running = nil

--- Map a raw abcql-backend response into the QueryResult shape used by the rest of the plugin
--- @param response table Decoded JSON response from abcql-backend
--- @return QueryResult
local function to_query_result(response)
  return {
    headers = response.headers or {},
    rows = response.rows or {},
    row_count = response.row_count or 0,
    query_type = response.query_type,
    affected_rows = response.affected_rows,
    matched_rows = response.matched_rows,
    changed_rows = response.changed_rows,
    warnings = response.warnings,
    duration_ms = response.duration_ms,
    truncated = response.truncated == true,
  }
end

--- Execute a query asynchronously via abcql-backend
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param callback fun(results: QueryResult|nil, err: string|nil) Called with parsed results or error
--- @param opts? table Optional parameters passed to adapter's build_backend_request
--- @return table|nil handle vim.system handle (nil when the backend could not be started)
function Query.execute_async(adapter, query, callback, opts)
  local request = adapter:build_backend_request(query, opts or {})

  return Backend.invoke(request, function(response, err)
    if err then
      callback(nil, err)
      return
    end

    callback(to_query_result(response), nil)
  end)
end

--- Execute a query synchronously (blocking) via abcql-backend
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param opts? table Optional parameters
--- @return QueryResult|nil results Parsed results
--- @return string|nil error Error message if failed
function Query.execute_sync(adapter, query, opts)
  local request = adapter:build_backend_request(query, opts or {})

  local response, err = Backend.invoke_sync(request)
  if err then
    return nil, err
  end

  return to_query_result(response), nil
end

--- Split a buffer into statements, honouring the `query.treesitter` setting.
--- @param bufnr number|nil
--- @return abcql.Statement[]
function Query.get_statements(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, config = pcall(require, "abcql.config")
  local use_ts = not ok or type(config.query) ~= "table" or config.query.treesitter ~= false
  if use_ts then
    return Statements.split_buffer(bufnr)
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  return Statements.scan(text)
end

--- Extract the SQL statement at the cursor position
--- @param bufnr number|nil Buffer number (defaults to current buffer)
--- @return string The SQL statement text (without trailing semicolon), or "" if none
function Query.get_query_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local stmt = Statements.at_line(Query.get_statements(bufnr), cursor_line)
  return stmt and stmt.text or ""
end

--- Text of the last visual selection in the current buffer
--- @return string
function Query.get_selection_query()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  if #lines == 0 then
    return ""
  end
  local mode = vim.fn.visualmode()
  if mode == "v" then
    local end_col = end_pos[3]
    if end_col >= #lines[#lines] then
      end_col = #lines[#lines]
    end
    lines[#lines] = lines[#lines]:sub(1, end_col)
    lines[1] = lines[1]:sub(start_pos[3])
  end
  local text = table.concat(lines, "\n")
  return vim.trim((text:gsub(";%s*$", "")))
end

--- Decide whether a statement needs an interactive confirmation.
--- Datasource `confirm` overrides the global `query.confirm` policy.
--- @param datasource Datasource
--- @param sql string
--- @return boolean
function Query.should_confirm(datasource, sql)
  local policy = datasource.confirm
  if policy == nil then
    local ok, config = pcall(require, "abcql.config")
    policy = ok and type(config.query) == "table" and config.query.confirm or "writes"
  end
  if policy == "never" then
    return false
  elseif policy == "always" then
    return true
  end
  return Statements.is_write(sql)
end

--- Show a statement preview in a floating window and prompt for execution
--- @param query string The SQL to preview
--- @param title string Window title
--- @param on_confirm function Called when the user confirms
--- @param on_reject function|nil Called when the user cancels
local function show_confirmation_prompt(query, title, on_confirm, on_reject)
  local buf = vim.api.nvim_create_buf(false, true)

  local lines = vim.split(query, "\n")
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "sql"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " (<CR> run, q cancel) ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true

  local decided = false
  local function close(confirmed)
    if decided then
      return
    end
    decided = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if confirmed then
      on_confirm()
    elseif on_reject then
      on_reject()
    end
  end

  vim.keymap.set("n", "<CR>", function()
    close(true)
  end, { buffer = buf, desc = "Execute query" })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close(false)
    end, { buffer = buf, desc = "Cancel" })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close(false)
      end)
    end,
  })
end

--- Whether a query is currently executing
--- @return boolean
function Query.is_running()
  return running ~= nil
end

--- Cancel the running query, if any
--- @return boolean cancelled
function Query.cancel()
  if not running then
    vim.notify("abcql: no query is running", vim.log.levels.INFO)
    return false
  end
  if running.handle and running.handle.kill then
    running.handle:kill(15)
  end
  return true
end

--- Execute a statement against a datasource: readonly guard, confirmation,
--- running indicator, history and results display.
--- @param sql string
--- @param datasource Datasource
--- @param opts? { confirm?: boolean, on_done?: fun(results: QueryResult|nil, err: string|nil) }
function Query.run(sql, datasource, opts)
  opts = opts or {}
  local UI = require("abcql.ui")
  local History = require("abcql.history")

  local function finish(results, err)
    if opts.on_done then
      opts.on_done(results, err)
    end
  end

  if Statements.is_blank(sql) then
    vim.notify("abcql: nothing to execute", vim.log.levels.WARN)
    finish(nil, "empty statement")
    return
  end

  if running then
    vim.notify("abcql: a query is already running (:AbcqlQueryCancel to stop it)", vim.log.levels.WARN)
    finish(nil, "busy")
    return
  end

  if datasource.readonly and Statements.is_write(sql) then
    local err = string.format("Datasource '%s' is readonly; refusing to run a write statement.", datasource.name)
    UI.display(err, nil, { query = sql, datasource = datasource })
    finish(nil, err)
    return
  end

  local function execute()
    local database = datasource.adapter and datasource.adapter.config and datasource.adapter.config.database
    local job = { query = sql, datasource = datasource, started = vim.uv.hrtime() }
    running = job
    UI.set_running(sql, datasource)

    local handle = Query.execute_async(datasource.adapter, sql, function(results, err)
      if running == job then
        running = nil
      end
      UI.clear_running()

      History.save(sql, datasource.name, database, results, err)

      local display_opts = { datasource = datasource, query = sql }
      if err then
        UI.display(err, nil, display_opts)
      else
        UI.display(results, nil, display_opts)
      end
      finish(results, err)
    end)

    -- The callback may already have run (e.g. backend binary missing), in
    -- which case the job is finished and there is nothing to track.
    if running == job then
      job.handle = handle
    end
  end

  local needs_confirm = opts.confirm
  if needs_confirm == nil then
    needs_confirm = Query.should_confirm(datasource, sql)
  end

  if needs_confirm then
    local kind = Statements.is_write(sql) and "Run write statement" or "Run query"
    show_confirmation_prompt(sql, string.format("%s on %s?", kind, datasource.name), execute, function()
      finish(nil, "cancelled")
    end)
  else
    execute()
  end
end

--- Resolve the buffer's datasource, then run the given SQL.
--- @param sql string
--- @param opts? table Passed through to Query.run
local function run_in_current_buffer(sql, opts)
  if Statements.is_blank(sql) then
    vim.notify("abcql: no query at cursor", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  require("abcql.db").ensure_datasource(bufnr, function(datasource)
    if not datasource then
      return
    end
    Query.run(sql, datasource, opts)
  end)
end

--- Execute the SQL statement located at the current cursor position
function Query.execute_query_at_cursor()
  run_in_current_buffer(Query.get_query_at_cursor())
end

--- Execute the visually selected text as a single statement
function Query.execute_selection()
  local sql = Query.get_selection_query()
  if sql == "" then
    vim.notify("abcql: no selection", vim.log.levels.WARN)
    return
  end
  run_in_current_buffer(sql)
end

--- Execute every statement in the current buffer sequentially, stopping at
--- the first error. The results panel ends up showing the last statement.
function Query.execute_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local statements = Query.get_statements(bufnr)
  if #statements == 0 then
    vim.notify("abcql: no statements in buffer", vim.log.levels.WARN)
    return
  end

  require("abcql.db").ensure_datasource(bufnr, function(datasource)
    if not datasource then
      return
    end

    local writes = 0
    for _, stmt in ipairs(statements) do
      if Statements.is_write(stmt.text) then
        writes = writes + 1
      end
    end

    if datasource.readonly and writes > 0 then
      require("abcql.ui").display(
        string.format(
          "Datasource '%s' is readonly; the buffer contains %d write statement(s).",
          datasource.name,
          writes
        ),
        nil,
        { datasource = datasource }
      )
      return
    end

    local function run_all()
      local index = 0
      local function step()
        index = index + 1
        local stmt = statements[index]
        if not stmt then
          vim.notify(string.format("abcql: ran %d statement(s)", #statements), vim.log.levels.INFO)
          return
        end
        Query.run(stmt.text, datasource, {
          confirm = false,
          on_done = function(_, err)
            if err then
              vim.notify(
                string.format("abcql: stopped at statement %d/%d (line %d)", index, #statements, stmt.start_line),
                vim.log.levels.WARN
              )
              return
            end
            step()
          end,
        })
      end
      step()
    end

    local preview = {}
    for _, stmt in ipairs(statements) do
      table.insert(preview, (stmt.text:gsub("%s+", " ")))
    end
    local needs_confirm = writes > 0 and Query.should_confirm(datasource, "update")
      or Query.should_confirm(datasource, "select")
    if needs_confirm then
      show_confirmation_prompt(
        table.concat(preview, ";\n") .. ";",
        string.format("Run %d statement(s) (%d write) on %s?", #statements, writes, datasource.name),
        run_all
      )
    else
      run_all()
    end
  end)
end

return Query
