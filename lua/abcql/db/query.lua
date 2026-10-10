local Backend = require("abcql.backend")
local Limit = require("abcql.db.limit")
local Sessions = require("abcql.db.session")
local Statements = require("abcql.db.statements")
local Status = require("abcql.ui.status")

---@class abcql.db.Query
local Query = {}

---@alias QueryResult { headers: string[], rows: table[], row_count: number, query_type: string?, affected_rows: number?, matched_rows: number?, changed_rows: number?, warnings: number?, duration_ms: number?, truncated: boolean?, auto_limit: number? }

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

--- Map a batch response (or error) from the backend or a session onto `execute_batch_async`'s callback.
--- @param callback fun(results: QueryResult[]|nil, err: string|nil, failed_index: number|nil)
--- @return fun(response: table|nil, err: string|nil)
local function batch_handler(callback)
  return function(response, err)
    if not response then
      callback(nil, err, nil)
      return
    end

    local results = {}
    for _, result in ipairs(response.results or {}) do
      table.insert(results, to_query_result(result))
    end
    local failed = response.failed_index and response.failed_index + 1 or nil
    callback(results, type(response.error) == "string" and response.error ~= "" and response.error or nil, failed)
  end
end

--- Execute several statements in one backend request: they run in order on a
--- single connection, so a transaction, `SET @var` or temporary table carries
--- over from one to the next. Stops at the first error.
--- @param request table Backend request built by the adapter (connection fields, timeout); its `sql` is replaced
--- @param statements { sql: string, max_rows: number }[] Per-statement row cap (0 = uncapped)
--- @param callback fun(results: QueryResult[]|nil, err: string|nil, failed_index: number|nil) `results` holds the
--- statements that succeeded (also on failure, when `failed_index` is the 1-based number of the one that did not)
--- @return table|nil handle vim.system handle (nil when the backend could not be started)
function Query.execute_batch_async(request, statements, callback)
  request.sql = nil
  request.max_rows = nil
  request.statements = statements

  return Backend.invoke(request, batch_handler(callback))
end

--- Like `execute_batch_async`, but through the buffer's persistent session when its datasource
--- is in persistent mode (opened on first use), so the statements share the session's connection
--- across runs. A refused session (SQLite, no PROCESS privilege, ...) is an error, never a
--- fallback to a one-shot run.
--- @param bufnr number Buffer whose session runs them
--- @param datasource Datasource
--- @param request table Backend request built by the adapter
--- @param statements { sql: string, max_rows: number }[]
--- @param callback fun(results: QueryResult[]|nil, err: string|nil, failed_index: number|nil)
--- @return table|nil handle Has `kill`
function Query.execute_batch(bufnr, datasource, request, statements, callback)
  if Sessions.mode(datasource) == "persistent" then
    return Sessions.exec(bufnr, datasource, request, statements, batch_handler(callback))
  end
  return Query.execute_batch_async(request, statements, callback)
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
--- @return string text Trimmed selection
--- @return number|nil blank_lines Leading blank lines that were trimmed
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
  -- Leading blank lines are dropped too; say how many, so line numbers stay right.
  local _, blank_lines = text:match("^%s*"):gsub("\n", "")
  return vim.trim((text:gsub(";%s*$", ""))), blank_lines
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

--- Whether the dangerous-statement lint is on for a datasource: the
--- datasource's `lint_dangerous` flag overrides `query.lint_dangerous`.
--- @param datasource Datasource|nil
--- @return boolean
function Query.lint_dangerous_enabled(datasource)
  if datasource and datasource.lint_dangerous ~= nil then
    return datasource.lint_dangerous ~= false
  end
  local ok, config = pcall(require, "abcql.config")
  return not (ok and type(config.query) == "table" and config.query.lint_dangerous == false)
end

--- First statement in `sql` that affects every row (see Statements.dangerous)
--- @param sql string One or more statements
--- @return abcql.DangerousStatement|nil
function Query.find_dangerous(sql)
  for _, stmt in ipairs(Statements.scan(sql)) do
    local danger = Statements.dangerous(stmt.text)
    if danger then
      return danger
    end
  end
  return nil
end

--- Why running these statements would silently COMMIT the buffer's open transaction (persistent
--- sessions), or nil. Uses the transaction state the server last reported.
--- @param bufnr number|nil
--- @param datasource Datasource
--- @param sql string One statement
--- @return string|nil reason
function Query.implicit_commit(bufnr, datasource, sql)
  if not bufnr or not Sessions.in_transaction(bufnr, datasource) then
    return nil
  end
  local keyword = Statements.implicit_commit(sql)
  if not keyword then
    return nil
  end
  return string.format(
    "%s implicitly COMMITs the open transaction (%d rows modified)",
    keyword,
    Sessions.state(bufnr).rows_modified or 0
  )
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
--- A dangerous statement (UPDATE/DELETE without WHERE, TRUNCATE) is always
--- confirmed, even with `opts.confirm = false`, unless the lint is disabled.
--- `opts.dangerous_confirmed` means the caller already confirmed it (a buffer run's upfront prompt).
--- A statement that would implicitly COMMIT the session's open transaction is confirmed the same way.
--- `opts.mark` (`abcql.ui.StatusMark`) is the statement's line range, coloured by outcome.
--- `opts.bufnr` is the buffer whose persistent session runs it (ignored for one-shot datasources).
--- @param opts? { bufnr?: number, confirm?: boolean, dangerous_confirmed?: boolean, mark?: abcql.ui.StatusMark, on_done?: fun(results: QueryResult|nil, err: string|nil) }
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

  local function refuse(err)
    Status.done(opts.mark, err)
    UI.display(err, nil, { query = sql, datasource = datasource })
    finish(nil, err)
  end

  local persistent = opts.bufnr ~= nil and Sessions.mode(datasource) == "persistent"
  local refusal = persistent and Sessions.refusal(datasource)
  if refusal then
    refuse(refusal)
    return
  end

  if datasource.readonly and Statements.is_write(sql) then
    refuse(string.format("Datasource '%s' is readonly; refusing to run a write statement.", datasource.name))
    return
  end

  local function execute()
    local database = datasource.adapter and datasource.adapter.config and datasource.adapter.config.database
    local job = { query = sql, datasource = datasource, started = vim.uv.hrtime() }
    running = job
    UI.set_running(sql, datasource)
    Status.running(opts.mark)

    -- A statement bounded by a LIMIT (its own or the auto-LIMIT) is returned
    -- in full; max_rows only caps statements without one.
    local limit = Limit.for_datasource(datasource)
    local sent_sql, limit_status = Limit.apply(sql, limit)
    local exec_opts = limit_status and { max_rows = 0 } or nil

    local function on_result(results, err)
      if running == job then
        running = nil
      end
      UI.clear_running()
      Status.done(opts.mark, err)
      if results and limit_status == "added" then
        results.auto_limit = limit
      end

      local _, history_id = History.save(sql, datasource.name, database, results, err)

      local display_opts = { datasource = datasource, query = sql, sent_query = sent_sql, history_id = history_id }
      if err then
        UI.display(err, nil, display_opts)
      else
        UI.display(results, nil, display_opts)
        Query.after_schema_change(sql, datasource)
      end
      finish(results, err)
    end

    local handle
    if persistent then
      local request = datasource.adapter:build_backend_request(sent_sql, exec_opts)
      handle = Query.execute_batch(
        opts.bufnr,
        datasource,
        request,
        { { sql = sent_sql, max_rows = request.max_rows } },
        function(results, err)
          on_result(results and results[1], err)
        end
      )
    else
      handle = Query.execute_async(datasource.adapter, sent_sql, on_result, exec_opts)
    end

    -- The callback may already have run (e.g. backend binary missing), in
    -- which case the job is finished and there is nothing to track.
    if running == job then
      job.handle = handle
    end
  end

  -- A statement touching every row is confirmed whatever the policy says.
  local danger = not opts.dangerous_confirmed and Query.lint_dangerous_enabled(datasource) and Query.find_dangerous(sql)
    or nil
  local commit = not opts.dangerous_confirmed and Query.implicit_commit(opts.bufnr, datasource, sql) or nil
  local needs_confirm = opts.confirm
  if needs_confirm == nil then
    needs_confirm = Query.should_confirm(datasource, sql)
  end

  if needs_confirm or danger or commit then
    local title
    if danger or commit then
      local reasons = { danger and danger.message, commit }
      title = string.format(
        "%s — run on %s?",
        table.concat(
          vim.tbl_filter(function(r)
            return r
          end, reasons),
          "; "
        ),
        datasource.name
      )
    else
      local kind = Statements.is_write(sql) and "Run write statement" or "Run query"
      title = string.format("%s on %s?", kind, datasource.name)
    end
    show_confirmation_prompt(sql, title, execute, function()
      finish(nil, "cancelled")
    end)
  else
    execute()
  end
end

--- Statement keywords that change the schema and invalidate the cached one
local SCHEMA_KEYWORDS = { CREATE = true, ALTER = true, DROP = true, RENAME = true }

--- After a successful DDL statement, refresh the datasource's schema cache
--- (completion, hover, diagnostics) and the tree.
--- @param sql string
--- @param datasource Datasource
function Query.after_schema_change(sql, datasource)
  local keyword = Statements.first_keyword(sql)
  if not keyword or not SCHEMA_KEYWORDS[keyword] then
    return
  end

  local LSP = require("abcql.lsp")
  if LSP.has_schema(datasource.name) then
    LSP.refresh_schema(datasource.name, datasource.adapter, function() end)
  end

  local ok, Tree = pcall(require, "abcql.ui.tree")
  if ok then
    Tree.reset()
  end
  local ok_ui, UI = pcall(require, "abcql.ui")
  if ok_ui and UI.refresh_tree then
    UI.refresh_tree()
  end
end

--- Resolve the buffer's datasource, then run the given SQL.
--- @param sql string
--- @param opts? table Passed through to Query.run
--- @param mark? abcql.ui.StatusMark Lines to colour with the run status
local function run_in_current_buffer(sql, opts, mark)
  if Statements.is_blank(sql) then
    vim.notify("abcql: no query at cursor", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  require("abcql.db").ensure_datasource(bufnr, function(datasource)
    if not datasource then
      return
    end
    Query.run(sql, datasource, vim.tbl_extend("force", { mark = mark, bufnr = bufnr }, opts or {}))
  end)
end

--- Execute the SQL statement located at the current cursor position
function Query.execute_query_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local stmt = Statements.at_line(Query.get_statements(bufnr), vim.api.nvim_win_get_cursor(0)[1])
  run_in_current_buffer(
    stmt and stmt.text or "",
    nil,
    stmt and { bufnr = bufnr, start_line = stmt.start_line, end_line = stmt.end_line }
  )
end

--- Run statements as one batch on a single backend connection, so session state
--- (transactions, variables, temporary tables) carries over. Everything that can
--- refuse or rewrite a statement (readonly, prompts, auto-LIMIT) has happened
--- before this. The results panel ends up showing the last statement's result,
--- or the error of the one that failed (the batch stops there); every executed
--- statement is saved to history.
--- @param bufnr number
--- @param datasource Datasource
--- @param statements abcql.Statement[]
local function run_batch(bufnr, datasource, statements)
  local UI = require("abcql.ui")
  local History = require("abcql.history")

  if running then
    vim.notify("abcql: a query is already running (:AbcqlQueryCancel to stop it)", vim.log.levels.WARN)
    return
  end

  local adapter = datasource.adapter
  local database = adapter and adapter.config and adapter.config.database
  local request = adapter:build_backend_request("", {})
  local limit = Limit.for_datasource(datasource)

  -- A statement bounded by a LIMIT (its own or the auto-LIMIT) is returned in
  -- full; max_rows only caps statements without one.
  local sent, to_send, limits = {}, {}, {}
  for i, stmt in ipairs(statements) do
    local sent_sql, limit_status = Limit.apply(stmt.text, limit)
    sent[i] = sent_sql
    limits[i] = limit_status
    to_send[i] = { sql = sent_sql, max_rows = limit_status and 0 or request.max_rows }
  end
  local sent_batch = table.concat(sent, ";\n") .. ";"
  local whole = {
    bufnr = bufnr,
    start_line = statements[1].start_line,
    end_line = statements[#statements].end_line,
  }
  local function mark_of(stmt)
    return { bufnr = bufnr, start_line = stmt.start_line, end_line = stmt.end_line }
  end

  local job = { query = sent_batch, datasource = datasource, started = vim.uv.hrtime() }
  running = job
  UI.set_running(sent_batch, datasource)
  Status.running(whole)

  local handle = Query.execute_batch(bufnr, datasource, request, to_send, function(results, err, failed)
    if running == job then
      running = nil
    end
    UI.clear_running()
    results = results or {}

    local history_id, _
    for i, result in ipairs(results) do
      if limits[i] == "added" then
        result.auto_limit = limit
      end
      _, history_id = History.save(statements[i].text, datasource.name, database, result, nil)
    end

    -- The statement shown: the one that failed, else the last one that ran.
    -- An error naming no statement (the process was killed, the connection
    -- failed) can't say how far the batch got, so it covers the whole batch.
    local stmt = statements[failed or #results]
    local mark = stmt and mark_of(stmt) or whole
    local text = stmt and stmt.text
      or table.concat(
        vim.tbl_map(function(s)
          return s.text
        end, statements),
        ";\n"
      )
    if err then
      -- Killing the process or timing out only drops the connection: the
      -- statement that was running may still complete on the server.
      if err == "Query cancelled" then
        err = "Query cancelled; statements up to and including the one that was running may have been applied"
      elseif err:lower():find("timeout", 1, true) or err:lower():find("deadline", 1, true) then
        err = err .. " (the statement may still complete on the server)"
      end
      _, history_id = History.save(text, datasource.name, database, nil, err)
    end
    stmt = stmt or statements[1]
    Status.done(mark, err)
    UI.display(err or results[#results], nil, {
      datasource = datasource,
      query = text,
      sent_query = sent_batch,
      history_id = history_id,
    })

    -- Without a failing statement any of them may have completed (a DDL one
    -- changes the schema); the check is a no-op for the rest.
    for i = 1, (err and not failed) and #statements or #results do
      Query.after_schema_change(statements[i].text, datasource)
    end
    if failed then
      vim.notify(
        string.format("abcql: stopped at statement %d/%d (line %d)", failed, #statements, stmt.start_line),
        vim.log.levels.WARN
      )
    elseif not err then
      vim.notify(string.format("abcql: ran %d statement(s)", #statements), vim.log.levels.INFO)
    end
  end)

  if running == job then
    job.handle = handle
  end
end

--- Run several statements as one batch (see run_batch) after the readonly
--- guard and the confirmation prompts.
--- @param bufnr number Buffer whose datasource runs them
--- @param statements abcql.Statement[]
local function run_statements(bufnr, statements)
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

    local refusal = Sessions.mode(datasource) == "persistent" and Sessions.refusal(datasource)
    if refusal then
      require("abcql.ui").display(refusal, nil, { datasource = datasource })
      return
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

    -- Dangerous statements are confirmed once, before anything runs, so a
    -- declined prompt never leaves a half-executed batch.
    local dangers = {}
    if Query.lint_dangerous_enabled(datasource) then
      for _, stmt in ipairs(statements) do
        local danger = Statements.dangerous(stmt.text)
        if danger then
          table.insert(dangers, string.format("-- line %d: %s", stmt.start_line, danger.message))
        end
      end
    end

    local commits = {}
    for _, stmt in ipairs(statements) do
      local reason = Query.implicit_commit(bufnr, datasource, stmt.text)
      if reason then
        table.insert(commits, string.format("-- line %d: %s", stmt.start_line, reason))
      end
    end

    local function run_all()
      run_batch(bufnr, datasource, statements)
    end

    local preview = {}
    for _, stmt in ipairs(statements) do
      table.insert(preview, (stmt.text:gsub("%s+", " ")))
    end
    local needs_confirm = writes > 0 and Query.should_confirm(datasource, "update")
      or Query.should_confirm(datasource, "select")
    if #dangers > 0 or #commits > 0 then
      local flags = {}
      if #dangers > 0 then
        table.insert(flags, string.format("%d dangerous statement(s)", #dangers))
      end
      if #commits > 0 then
        table.insert(flags, string.format("%d implicit COMMIT(s)", #commits))
      end
      show_confirmation_prompt(
        table.concat(vim.list_extend(dangers, commits), "\n") .. "\n\n" .. table.concat(preview, ";\n") .. ";",
        string.format("Run %d statement(s) on %s? %s", #statements, datasource.name, table.concat(flags, ", ")),
        run_all
      )
    elseif needs_confirm then
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

--- Execute the visually selected text. Several statements run as one batch on
--- a single connection, like a buffer run.
function Query.execute_selection()
  local sql, blank_lines = Query.get_selection_query()
  if sql == "" then
    vim.notify("abcql: no selection", vim.log.levels.WARN)
    return
  end
  local statements = Statements.scan(sql)
  if #statements <= 1 then
    run_in_current_buffer(sql, nil, {
      bufnr = vim.api.nvim_get_current_buf(),
      start_line = vim.fn.getpos("'<")[2],
      end_line = vim.fn.getpos("'>")[2],
    })
    return
  end
  -- Report buffer line numbers, not selection-relative ones.
  local offset = vim.fn.getpos("'<")[2] - 1 + blank_lines
  for _, stmt in ipairs(statements) do
    stmt.start_line = stmt.start_line + offset
    stmt.end_line = stmt.end_line + offset
  end
  run_statements(vim.api.nvim_get_current_buf(), statements)
end

--- Execute every statement in the current buffer as one batch on a single
--- connection, stopping at the first error. The results panel ends up showing
--- the last statement.
function Query.execute_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local statements = Query.get_statements(bufnr)
  if #statements == 0 then
    vim.notify("abcql: no statements in buffer", vim.log.levels.WARN)
    return
  end
  run_statements(bufnr, statements)
end

return Query
