local Cache = require("abcql.lsp.cache")
local Server = require("abcql.lsp.server")

---@class abcql.LSP
---@field private cache abcql.lsp.Cache Shared cache instance
---@field private servers table<string, abcql.lsp.Server> In-process servers by datasource name
---@field private clients table<string, number> LSP client ids by datasource name
---@field private buffers table<number, string> Datasource name by attached buffer
local LSP = {}
LSP.__index = LSP

local CLIENT_NAME = "abcql-lsp"

--- Global LSP instance
---@type abcql.LSP|nil
local instance = nil

--- Get or create the global LSP instance
---@return abcql.LSP
local function get_instance()
  if not instance then
    instance = setmetatable({}, LSP)
    rawset(instance, "cache", Cache.new())
    rawset(instance, "servers", {})
    rawset(instance, "clients", {})
    rawset(instance, "buffers", {})
  end
  return instance
end

--- Commands exposed to the client for code actions
---@param datasource Datasource
---@return table<string, fun(command: table, ctx: table)>
local function build_commands(datasource)
  return {
    ["abcql.run"] = function(command)
      local arg = command.arguments and command.arguments[1] or {}
      local ok, bufnr = pcall(vim.uri_to_bufnr, arg.uri or "")
      if not ok or not arg.line then
        return
      end
      local statements = require("abcql.db.query").get_statements(bufnr)
      local stmt = require("abcql.db.statements").at_line(statements, arg.line)
      if stmt then
        require("abcql.db.query").run(stmt.text, datasource)
      end
    end,
    ["abcql.browse"] = function(command)
      local arg = command.arguments and command.arguments[1] or {}
      if arg.sql then
        require("abcql.db.query").run(arg.sql, datasource, { confirm = false })
      end
    end,
  }
end

--- Start (or reuse) the in-process LSP client for a datasource and attach the buffer
---@param bufnr number Buffer number
---@param datasource Datasource Datasource to use
---@param callback fun(err: string|nil) Called when LSP is ready or on error
function LSP.start(bufnr, datasource, callback)
  local self = get_instance()

  -- Detach from a previous datasource's client, if any
  if self.buffers[bufnr] and self.buffers[bufnr] ~= datasource.name then
    LSP.stop(bufnr)
  end

  if not self.cache:has_cache(datasource.name) then
    vim.notify("abcql: loading schema for " .. datasource.name .. "…", vim.log.levels.INFO)

    self.cache:load_schema(datasource.name, datasource.adapter, function(err)
      if err then
        vim.notify("Failed to load schema: " .. err, vim.log.levels.ERROR)
        callback(err)
        return
      end
      self:start_server(bufnr, datasource, callback)
    end)
  else
    self:start_server(bufnr, datasource, callback)
  end
end

--- Get (creating if needed) the server for a datasource
---@param datasource Datasource
---@return abcql.lsp.Server
function LSP:server_for(datasource)
  local server = self.servers[datasource.name]
  if not server then
    server = Server.new(self.cache, datasource.name, datasource.adapter)
    self.servers[datasource.name] = server
  end
  return server
end

--- Attach a buffer to the datasource's client, creating the client on first use
---@param bufnr number Buffer number
---@param datasource Datasource Datasource to use
---@param callback fun(err: string|nil) Callback when ready
function LSP:start_server(bufnr, datasource, callback)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback("buffer is no longer valid")
    return
  end

  local server = self:server_for(datasource)

  local client_id = vim.lsp.start({
    name = CLIENT_NAME,
    settings = { datasource = datasource.name },
    commands = build_commands(datasource),
    cmd = function(dispatchers)
      server:set_dispatchers(dispatchers)
      local closing = false
      return {
        request = function(method, params, request_callback, notify_reply_callback)
          local result, err

          if method == "initialize" then
            result = server:handle_initialize(params)
          elseif method == "textDocument/completion" then
            result = server:handle_completion(params)
          elseif method == "textDocument/hover" then
            result = server:handle_hover(params)
          elseif method == "textDocument/documentSymbol" then
            result = server:handle_document_symbol(params)
          elseif method == "textDocument/codeAction" then
            result = server:handle_code_action(params)
          elseif method == "workspace/symbol" then
            result = server:handle_workspace_symbol(params)
          elseif method == "shutdown" then
            result = server:handle_shutdown()
          else
            err = { code = -32601, message = "Method not found: " .. method }
          end

          if request_callback then
            vim.schedule(function()
              request_callback(err, result)
            end)
          end
          if notify_reply_callback then
            notify_reply_callback(1)
          end
          return true, 1
        end,
        notify = function(method, params)
          if method == "exit" then
            closing = true
          else
            server:handle_notification(method, params)
          end
          return true
        end,
        is_closing = function()
          return closing
        end,
        terminate = function()
          closing = true
        end,
      }
    end,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == config.name and client.settings and client.settings.datasource == config.settings.datasource
    end,
  })

  if not client_id then
    callback("Failed to start LSP client")
    return
  end

  self.clients[datasource.name] = client_id
  self.buffers[bufnr] = datasource.name

  -- Clean up when buffer is deleted to prevent stale entries
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      LSP.stop(bufnr)
    end,
  })

  callback(nil)
end

--- Detach a buffer from its datasource client; the client stops when no buffer uses it
---@param bufnr number Buffer number
function LSP.stop(bufnr)
  local self = get_instance()
  local datasource_name = self.buffers[bufnr]
  if not datasource_name then
    return
  end
  self.buffers[bufnr] = nil

  local client_id = self.clients[datasource_name]
  if not client_id then
    return
  end
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    self.clients[datasource_name] = nil
    return
  end

  if vim.api.nvim_buf_is_valid(bufnr) and vim.lsp.buf_is_attached(bufnr, client_id) then
    vim.lsp.buf_detach_client(bufnr, client_id)
  end

  local remaining = 0
  for other, name in pairs(self.buffers) do
    if name == datasource_name and vim.api.nvim_buf_is_valid(other) then
      remaining = remaining + 1
    end
  end
  if remaining == 0 then
    client:stop()
    self.clients[datasource_name] = nil
  end
end

--- Refresh schema cache for a datasource and re-run diagnostics on its buffers
---@param datasource_name string Name of the datasource
---@param adapter abcql.db.adapter.Adapter Database adapter
---@param callback fun(err: string|nil) Called when refresh is complete
function LSP.refresh_schema(datasource_name, adapter, callback)
  local self = get_instance()

  self.cache:clear(datasource_name)

  vim.notify("abcql: refreshing schema for " .. datasource_name .. "…", vim.log.levels.INFO)
  self.cache:load_schema(datasource_name, adapter, function(err)
    if err then
      vim.notify("Failed to refresh schema: " .. err, vim.log.levels.ERROR)
      callback(err)
      return
    end

    local server = self.servers[datasource_name]
    if server then
      for bufnr, name in pairs(self.buffers) do
        if name == datasource_name and vim.api.nvim_buf_is_valid(bufnr) then
          server:schedule_diagnostics(vim.uri_from_bufnr(bufnr))
        end
      end
    end
    callback(nil)
  end)
end

--- Whether the schema of a datasource is cached
---@param datasource_name string
---@return boolean
function LSP.has_schema(datasource_name)
  return get_instance().cache:has_cache(datasource_name)
end

--- Check if LSP is running for a buffer
---@param bufnr number Buffer number
---@return boolean True if LSP is running
function LSP.is_running(bufnr)
  local self = get_instance()
  local name = self.buffers[bufnr]
  return name ~= nil and self.clients[name] ~= nil and vim.lsp.get_client_by_id(self.clients[name]) ~= nil
end

--- Get the datasource name for a buffer's LSP
---@param bufnr number Buffer number
---@return string|nil Datasource name, or nil if not running
function LSP.get_datasource_name(bufnr)
  return get_instance().buffers[bufnr]
end

--- Client id for a datasource (nil when not started)
---@param datasource_name string
---@return number|nil
function LSP.get_client_id(datasource_name)
  return get_instance().clients[datasource_name]
end

--- The in-process server for a datasource (nil when never started)
---@param datasource_name string
---@return abcql.lsp.Server|nil
function LSP.get_server(datasource_name)
  return get_instance().servers[datasource_name]
end

return LSP
