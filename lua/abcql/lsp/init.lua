local Cache = require("abcql.lsp.cache")
local Server = require("abcql.lsp.server")

---@class abcql.LSP
---@field private cache abcql.lsp.Cache Shared cache instance
---@field private servers table<number, { client_id: number, datasource_name: string }> LSP clients by buffer
local LSP = {}
LSP.__index = LSP

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
  end
  return instance
end

--- Start LSP for a buffer with a datasource
---@param bufnr number Buffer number
---@param datasource Datasource Datasource to use
---@param callback fun(err: string|nil) Called when LSP is ready or on error
function LSP.start(bufnr, datasource, callback)
  local self = get_instance()

  -- Stop existing LSP if any
  if self.servers[bufnr] then
    LSP.stop(bufnr)
  end

  -- Load schema if not cached
  if not self.cache:has_cache(datasource.name) then
    vim.notify("Loading schema for " .. datasource.name .. "...", vim.log.levels.INFO)

    self.cache:load_schema(datasource.name, datasource.adapter, function(err)
      if err then
        vim.notify("Failed to load schema: " .. err, vim.log.levels.ERROR)
        callback(err)
        return
      end

      vim.notify("Schema loaded for " .. datasource.name, vim.log.levels.INFO)

      -- Start LSP server
      self:start_server(bufnr, datasource, callback)
    end)
  else
    -- Schema already cached, start server immediately
    self:start_server(bufnr, datasource, callback)
  end
end

--- Start the LSP server for a buffer (internal method)
---@param bufnr number Buffer number
---@param datasource Datasource Datasource to use
---@param callback fun(err: string|nil) Callback when ready
function LSP:start_server(bufnr, datasource, callback)
  local server = Server.new(self.cache, datasource.name, datasource.adapter, bufnr)

  -- Create LSP client with custom RPC client object
  local client_id = vim.lsp.start({
    name = "abcql-lsp",
    cmd = function(dispatchers)
      -- Return a custom RPC client object that implements the required interface
      return {
        -- Handle LSP requests
        request = function(method, params, request_callback, notify_reply_callback)
          local result, err

          -- Route the method to the appropriate server handler
          if method == "initialize" then
            result = server:handle_initialize(params)
          elseif method == "textDocument/completion" then
            result = server:handle_completion(params)
          elseif method == "shutdown" then
            result = server:handle_shutdown()
          else
            -- Return error for unsupported methods
            err = { code = -32601, message = "Method not found: " .. method }
          end

          -- Schedule callback to avoid reentrancy issues
          if request_callback then
            vim.schedule(function()
              request_callback(err, result)
            end)
          end

          -- Notify that request is no longer pending
          if notify_reply_callback then
            notify_reply_callback(1) -- message_id
          end

          return true, 1 -- success, message_id
        end,

        -- Handle LSP notifications (fire-and-forget messages)
        notify = function(method, params)
          -- Most in-process servers don't need to handle notifications
          -- We could handle things like textDocument/didChange here if needed
          return true
        end,

        -- Check if the RPC connection is closing
        is_closing = function()
          return false
        end,

        -- Cleanup when LSP client stops
        terminate = function()
          -- Any cleanup can be done here
        end,
      }
    end,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == "abcql-lsp" and client.config.root_dir == config.root_dir
    end,
  })

  if not client_id then
    callback("Failed to start LSP client")
    return
  end

  self.servers[bufnr] = {
    client_id = client_id,
    datasource_name = datasource.name,
  }

  callback(nil)
end

--- Stop LSP for a buffer
---@param bufnr number Buffer number
function LSP.stop(bufnr)
  local self = get_instance()
  local server_info = self.servers[bufnr]

  if server_info then
    vim.lsp.stop_client(server_info.client_id)
    self.servers[bufnr] = nil
  end
end

--- Refresh schema cache for a datasource
---@param datasource_name string Name of the datasource
---@param adapter abcql.db.adapter.Adapter Database adapter
---@param callback fun(err: string|nil) Called when refresh is complete
function LSP.refresh_schema(datasource_name, adapter, callback)
  local self = get_instance()

  -- Clear existing cache
  self.cache:clear(datasource_name)

  -- Reload schema
  vim.notify("Refreshing schema for " .. datasource_name .. "...", vim.log.levels.INFO)
  self.cache:load_schema(datasource_name, adapter, function(err)
    if err then
      vim.notify("Failed to refresh schema: " .. err, vim.log.levels.ERROR)
      callback(err)
      return
    end

    vim.notify("Schema refreshed for " .. datasource_name, vim.log.levels.INFO)
    callback(nil)
  end)
end

--- Check if LSP is running for a buffer
---@param bufnr number Buffer number
---@return boolean True if LSP is running
function LSP.is_running(bufnr)
  local self = get_instance()
  return self.servers[bufnr] ~= nil
end

--- Get the datasource name for a buffer's LSP
---@param bufnr number Buffer number
---@return string|nil Datasource name, or nil if not running
function LSP.get_datasource_name(bufnr)
  local self = get_instance()
  local server_info = self.servers[bufnr]
  return server_info and server_info.datasource_name or nil
end

return LSP
