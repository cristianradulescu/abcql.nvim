--- One persistent `abcql-backend serve` process: a single database connection kept open across
--- runs (protocol in backend/session.go). The Lua side only frames lines, matches replies to
--- requests by id and tracks the connection state the backend reports; it never reconnects.
--- When the connection is lost the session is dead for good and the next run opens a new one.
---@class abcql.BackendSession
---@field state table|nil Last `session` object reported by the backend (in_transaction, autocommit, ...)
---@field dead boolean The session is over: lost, closed or never opened
---@field busy boolean An exec is awaiting its reply
---@field datasource_name string|nil Set by the owner (abcql.db.session)
---@field on_update fun(session: abcql.BackendSession)|nil Called after every reply and when the session ends
---@field on_lost fun(message: string)|nil Called when the process ends with no request waiting for the news
local Session = {}
Session.__index = Session

local Backend = require("abcql.backend")

--- A session writing request lines through `write`; replies arrive through `feed`.
--- @param write fun(line: string)
--- @return abcql.BackendSession
function Session.new(write)
  return setmetatable({ write = write, parts = {}, next_id = 0, pending = {}, dead = false, busy = false }, Session)
end

--- Route one decoded reply to the request it answers (the open reply has no id: 0).
--- @param line string
function Session:dispatch(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.session then
    self.state = msg.session
  end
  if msg.session_lost then
    self.dead = true
  end
  local id = msg.id or 0
  local callback = self.pending[id]
  self.pending[id] = nil
  if callback then
    callback(msg)
  end
  if self.on_update then
    self.on_update(self)
  end
end

--- Feed a chunk of stdout. Chunks end anywhere (a large result spans many) and may hold several
--- lines; a reply is one line, handled once its newline arrives.
--- @param chunk string
function Session:feed(chunk)
  local nl = chunk:find("\n", 1, true)
  while nl do
    table.insert(self.parts, chunk:sub(1, nl - 1))
    local line = table.concat(self.parts)
    self.parts = {}
    if line ~= "" then
      self:dispatch(line)
    end
    chunk = chunk:sub(nl + 1)
    nl = chunk:find("\n", 1, true)
  end
  if chunk ~= "" then
    table.insert(self.parts, chunk)
  end
end

--- The process is gone: every waiting request fails, and nothing may use the session again.
--- @param reason string
function Session:ended(reason)
  local expected = self.dead -- already lost, refused or closed: the news is out
  self.dead = true
  local waiting = false
  for id, callback in pairs(self.pending) do
    self.pending[id] = nil
    waiting = true
    callback({ error = reason, session_lost = true })
  end
  if self.on_update then
    self.on_update(self)
  end
  if not waiting and not expected and self.on_lost then
    self.on_lost(reason)
  end
end

--- @param op string
--- @param fields table|nil
--- @param callback fun(msg: table)
function Session:request(op, fields, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  local body = vim.json.encode(vim.tbl_extend("force", { id = id, op = op }, fields or {}))
  self.pending[id] = callback
  if not pcall(self.write, body .. "\n") then
    self.pending[id] = nil
    callback({ error = "the session is not running", session_lost = true })
  end
end

--- Run statements on the session's connection. The callback gets the batch response (also when a
--- statement failed part-way: `results`, `failed_index`, `error`) or, for a failure not tied to a
--- statement (busy, lost, refused), `nil` and the error. Same contract as `Backend.invoke`.
--- @param statements { sql: string, max_rows: number? }[]
--- @param timeout_ms number|nil
--- @param callback fun(response: table|nil, err: string|nil)
function Session:exec(statements, timeout_ms, callback)
  if self.dead then
    callback(nil, "the persistent session is closed")
    return
  end
  if self.busy then
    callback(nil, "session busy: a statement is still running")
    return
  end
  self.busy = true
  self:request("exec", { statements = statements, timeout_ms = timeout_ms }, function(msg)
    self.busy = false
    if type(msg.error) == "string" and msg.error ~= "" and msg.failed_index == nil then
      callback(nil, msg.error)
    else
      callback(msg, nil)
    end
  end)
end

--- Blocking `exec`, for the prompts on exit and detach.
--- @return table|nil response
--- @return string|nil err
function Session:exec_sync(statements, timeout_ms)
  local done, response, err
  self:exec(statements, timeout_ms, function(r, e)
    done, response, err = true, r, e
  end)
  if not vim.wait((timeout_ms or 30000) + 5000, function()
    return done
  end, 10) then
    return nil, "timed out waiting for the session"
  end
  return response, err
end

--- Interrupt the running statement; the connection and any open transaction stay. While the
--- session is still opening there is no statement, and cancelling abandons the open.
function Session:cancel()
  if self.opening then
    self.proc:kill(15)
  else
    self:request("cancel", nil, function() end)
  end
end

--- End the session and wait for the process: closing the connection makes the server roll back
--- whatever transaction is open. Never commits.
function Session:close()
  if self.dead and not self.proc then
    return
  end
  self.dead = true
  if self.proc then
    pcall(self.write, vim.json.encode({ id = 0, op = "close" }) .. "\n")
    pcall(self.proc.write, self.proc, nil)
    -- wait() kills the process if it doesn't exit in time; the connection closes either way.
    self.proc:wait(2000)
  end
end

--- Start `abcql-backend serve` and open the connection. The callback gets the session once the
--- backend has connected and read the transaction state, or the error that refused it (no
--- PROCESS privilege, unreachable server, ...); the session object is returned immediately so a
--- run still opening can be cancelled.
--- @param request table Connection fields as built by the adapter
--- @param callback fun(session: abcql.BackendSession|nil, err: string|nil)
--- @return abcql.BackendSession
function Session.start(request, callback)
  local path, path_err = Backend.executable_path()
  local self = Session.new(function() end)
  self.opening = true
  self.pending[0] = function(msg)
    self.opening = false
    if type(msg.error) == "string" and msg.error ~= "" then
      self.dead = true
      callback(nil, msg.error)
    else
      callback(self, nil)
    end
  end

  if not path then
    self.dead = true
    vim.schedule(function()
      self.pending[0] = nil
      callback(nil, path_err)
    end)
    return self
  end

  self.proc = vim.system({ path, "serve" }, {
    stdin = true,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          self:feed(data)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      local detail = vim.trim(result.stderr or "")
      self.opening = false
      self:ended(
        "Session lost: the backend process ended"
          .. (detail ~= "" and (" (" .. detail .. ")") or "")
          .. ". The server rolls back an open transaction when its connection ends, so nothing was committed."
      )
    end)
  end)
  self.write = function(line)
    self.proc:write(line)
  end
  self.write(vim.json.encode(request) .. "\n")
  return self
end

return Session
