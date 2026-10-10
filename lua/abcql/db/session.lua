--- Persistent sessions: one `abcql-backend serve` process (one database connection) per SQL
--- buffer, opened on the first run when the buffer's datasource is in persistent mode. The
--- guiding rule is to fail safe: a session that ends for any reason ends in a ROLLBACK by the
--- server, never a COMMIT, and an open transaction is never dropped without asking first
--- (Rollback is the default answer).
local BackendSession = require("abcql.backend.session")

---@class abcql.db.Sessions
local Sessions = {}

--- @type table<number, abcql.BackendSession>
local sessions = {}

--- Prompt seam (specs replace it): (message, "&A\n&B", default) -> choice number, 0 if dismissed.
Sessions.confirm = function(message, choices, default)
  return vim.fn.confirm(message, choices, default)
end

local AUGROUP = vim.api.nvim_create_augroup("abcql_session", { clear = true })

--- "persistent" or "oneshot": datasource `session` > `query.session` > "oneshot".
--- @param datasource Datasource
--- @return "persistent"|"oneshot"
function Sessions.mode(datasource)
  local ok, config = pcall(require, "abcql.config")
  local global = ok and type(config.query) == "table" and config.query.session or nil
  local own = datasource.session
  if own == "persistent" or own == "oneshot" then
    return own
  end
  if global == "persistent" then
    return global
  end
  return "oneshot"
end

--- Why a persistent datasource can't be used, if it can't. The caller shows this instead of
--- quietly running one-shot: the user asked for a session.
--- @param datasource Datasource
--- @return string|nil
function Sessions.refusal(datasource)
  local engine = datasource.adapter and datasource.adapter.ENGINE or "mysql"
  if engine ~= "mysql" then
    return string.format("Persistent sessions are MySQL-only; datasource '%s' is %s.", datasource.name, engine)
  end
  return nil
end

--- @param bufnr number
--- @return abcql.BackendSession|nil
function Sessions.get(bufnr)
  return sessions[bufnr]
end

--- State of the buffer's live session, as reported by the server after its last reply.
--- @param bufnr number
--- @return table|nil
function Sessions.state(bufnr)
  local session = sessions[bufnr]
  return session and not session.dead and session.state or nil
end

--- Whether the buffer's session on this datasource has an open transaction.
--- @param bufnr number
--- @param datasource Datasource
--- @return boolean
function Sessions.in_transaction(bufnr, datasource)
  local session = sessions[bufnr]
  local state = Sessions.state(bufnr)
  return state ~= nil and session.datasource_name == datasource.name and state.in_transaction == true
end

--- @param bufnr number
local function refresh_winbar(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    require("abcql.db").refresh_winbar(bufnr)
  end
end

--- Winbar segment for a session's state: the open transaction, autocommit off, or a database
--- other than the datasource's.
--- @param state table|nil
--- @param datasource_db string|nil
--- @return string
function Sessions.winbar_text(state, datasource_db)
  if not state then
    return ""
  end
  local text = " %#AbcqlTabInactive#session%*"
  if state.in_transaction then
    local locked = (state.rows_locked or 0) > 0 and string.format(", %d locked", state.rows_locked) or ""
    text = text .. string.format(" %%#AbcqlTransaction# TX ● %d rows%s %%*", state.rows_modified or 0, locked)
  elseif state.autocommit == false then
    text = text .. " %#AbcqlWarning#autocommit off%*"
  end
  local db = state.database
  if type(db) == "string" and db ~= "" and db ~= datasource_db then
    text = text .. " %#AbcqlDatasource#→ " .. db:gsub("%%", "%%%%") .. "%*"
  end
  return text
end

--- The buffer's live session, opening it first when there is none.
--- @param bufnr number
--- @param datasource Datasource
--- @param request table Connection request built by the datasource's adapter
--- @param callback fun(session: abcql.BackendSession|nil, err: string|nil)
function Sessions.ensure(bufnr, datasource, request, callback)
  local existing = sessions[bufnr]
  if existing and not existing.dead then
    if existing.datasource_name ~= datasource.name then
      callback(
        nil,
        string.format(
          "This buffer's persistent session is on '%s'; close it (:AbcqlSessionClose) to use '%s'.",
          existing.datasource_name,
          datasource.name
        )
      )
      return
    end
    callback(existing, nil)
    return
  end

  local refusal = Sessions.refusal(datasource)
  if refusal then
    callback(nil, refusal)
    return
  end

  local session
  session = BackendSession.start(request, function(opened, err)
    if opened then
      callback(opened, nil)
    else
      if sessions[bufnr] == session then
        sessions[bufnr] = nil
      end
      callback(nil, err)
    end
  end)
  if session.dead then
    return
  end
  session.datasource_name = datasource.name
  session.on_update = function(s)
    if s.dead and sessions[bufnr] == s then
      sessions[bufnr] = nil
    end
    refresh_winbar(bufnr)
  end
  session.on_lost = function(message)
    vim.notify("abcql: " .. message, vim.log.levels.WARN)
  end
  sessions[bufnr] = session

  vim.api.nvim_clear_autocmds({ group = AUGROUP, buffer = bufnr })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = AUGROUP,
    buffer = bufnr,
    once = true,
    callback = function()
      Sessions.close(bufnr, { can_cancel = false })
    end,
  })
end

--- Run statements through the buffer's session. The callback has the contract of
--- `Backend.invoke`. The returned handle's `kill` interrupts the statement (the session stays).
--- @param bufnr number
--- @param datasource Datasource
--- @param request table
--- @param statements { sql: string, max_rows: number? }[]
--- @param callback fun(response: table|nil, err: string|nil)
--- @return { kill: fun() }
function Sessions.exec(bufnr, datasource, request, statements, callback)
  Sessions.ensure(bufnr, datasource, request, function(session, err)
    if not session then
      callback(nil, err)
      return
    end
    session:exec(statements, request.timeout_ms, callback)
  end)
  return {
    kill = function()
      local session = sessions[bufnr]
      if session then
        session:cancel()
      end
    end,
  }
end

--- Send COMMIT or ROLLBACK through the buffer's session (an explicit user command).
--- @param bufnr number
--- @param verb "COMMIT"|"ROLLBACK"
function Sessions.finish_transaction(bufnr, verb)
  local session = sessions[bufnr]
  if not session or session.dead then
    vim.notify("abcql: this buffer has no persistent session", vim.log.levels.WARN)
    return
  end
  session:exec({ { sql = verb, max_rows = 0 } }, nil, function(response, err)
    err = err or (response and type(response.error) == "string" and response.error ~= "" and response.error) or nil
    if err then
      vim.notify(string.format("abcql: %s failed: %s", verb, err), vim.log.levels.ERROR)
    else
      vim.notify(verb == "COMMIT" and "abcql: transaction committed" or "abcql: transaction rolled back")
    end
  end)
end

--- End the buffer's session. With a transaction open, asks Commit / Rollback / Cancel first
--- (Rollback is the default; no Cancel when the buffer or Neovim is going away anyway).
--- @param bufnr number
--- @param opts { can_cancel: boolean }
--- @return boolean proceed false when the user chose Cancel
function Sessions.close(bufnr, opts)
  local session = sessions[bufnr]
  if not session then
    return true
  end

  local state = not session.dead and session.state or nil
  if state and state.in_transaction then
    local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    local message = string.format(
      "abcql: %s has an open transaction on '%s' (%d rows modified, %d locked).",
      name ~= "" and vim.fn.fnamemodify(name, ":t") or "buffer " .. bufnr,
      session.datasource_name,
      state.rows_modified or 0,
      state.rows_locked or 0
    )
    -- Distinct hotkeys: confirm() takes the first match, and Commit must never answer a `c` meant for Cancel.
    local choices = opts.can_cancel and "C&ommit\n&Rollback\n&Cancel" or "C&ommit\n&Rollback"
    local choice = Sessions.confirm(message, choices, 2)
    if opts.can_cancel and (choice == 3 or choice == 0) then
      return false
    end
    if choice == 1 then
      local response, err = session:exec_sync({ { sql = "COMMIT", max_rows = 0 } })
      err = err or (response and type(response.error) == "string" and response.error ~= "" and response.error) or nil
      if err then
        vim.notify("abcql: COMMIT failed, the transaction is rolled back: " .. err, vim.log.levels.ERROR)
      end
    end
  end

  sessions[bufnr] = nil
  session:close()
  refresh_winbar(bufnr)
  return true
end

--- End every session (asking about open transactions); stops at the first Cancel.
--- @param opts { can_cancel: boolean }
--- @return boolean proceed
function Sessions.close_all(opts)
  local bufnrs = vim.tbl_keys(sessions)
  table.sort(bufnrs)
  for _, bufnr in ipairs(bufnrs) do
    if not Sessions.close(bufnr, opts) then
      return false
    end
  end
  return true
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = AUGROUP,
  callback = function()
    Sessions.close_all({ can_cancel = false })
  end,
})

return Sessions
