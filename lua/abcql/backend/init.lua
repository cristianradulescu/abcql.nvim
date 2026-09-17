---@class abcql.Backend
local M = {}

--- Resolve the path to the abcql-backend binary.
--- Checks the user-configured `backend.path` override first, then falls back
--- to `bin/abcql-backend` relative to the plugin's own runtime directory.
--- @return string|nil path
function M.get_path()
  local ok, config = pcall(require, "abcql.config")
  local configured = ok and config.backend and config.backend.path
  if configured and configured ~= "" then
    return configured
  end

  local found = vim.api.nvim_get_runtime_file("bin/abcql-backend", false)
  return found[1]
end

--- @param path string|nil
--- @return string
local function missing_binary_error(path)
  local suffix = "Run `make build` in the abcql.nvim plugin directory, "
    .. 'or add build = "make build" to your plugin manager spec.'

  if path then
    return "abcql-backend not found or not executable at: " .. path .. ". " .. suffix
  end
  return "abcql-backend binary not found. " .. suffix
end

--- Parse a vim.system() completion result into (response, err).
--- @param result vim.SystemCompleted
--- @return table|nil response
--- @return string|nil err
local function parse_result(result)
  local ok, decoded = pcall(vim.json.decode, result.stdout or "")

  if ok and type(decoded) == "table" then
    if decoded.error and decoded.error ~= "" then
      return nil, decoded.error
    end
    return decoded, nil
  end

  local err = result.stderr
  if not err or err == "" then
    err = "abcql-backend exited with code " .. tostring(result.code)
  end
  return nil, err
end

--- Default timeout (ms) passed to vim.system, kept comfortably above the
--- request's own timeout_ms so the backend gets a chance to report its own
--- timeout error before the process is killed outright.
--- @param request table
--- @return number
local function process_timeout(request)
  return (request.timeout_ms or 30000) + 5000
end

--- Invoke abcql-backend asynchronously with a JSON request.
--- Returns the vim.system handle so callers can cancel the query with
--- `handle:kill()`; a killed process reports the error "Query cancelled".
--- @param request table Request matching the Go backend's protocol (see backend/protocol.go)
--- @param callback fun(response: table|nil, err: string|nil)
--- @return vim.SystemObj|nil handle
function M.invoke(request, callback)
  local path = M.get_path()
  if not path or vim.fn.executable(path) ~= 1 then
    callback(nil, missing_binary_error(path))
    return nil
  end

  local ok, body = pcall(vim.json.encode, request)
  if not ok then
    callback(nil, "Failed to encode backend request: " .. tostring(body))
    return nil
  end

  return vim.system({ path, "exec" }, {
    stdin = body,
    text = true,
    timeout = process_timeout(request),
  }, function(result)
    vim.schedule(function()
      if result.signal and result.signal ~= 0 and (result.stdout == nil or result.stdout == "") then
        callback(nil, "Query cancelled")
        return
      end
      callback(parse_result(result))
    end)
  end)
end

--- Invoke abcql-backend synchronously (blocking) with a JSON request.
--- @param request table Request matching the Go backend's protocol
--- @return table|nil response
--- @return string|nil err
function M.invoke_sync(request)
  local path = M.get_path()
  if not path or vim.fn.executable(path) ~= 1 then
    return nil, missing_binary_error(path)
  end

  local ok, body = pcall(vim.json.encode, request)
  if not ok then
    return nil, "Failed to encode backend request: " .. tostring(body)
  end

  local result = vim
    .system({ path, "exec" }, {
      stdin = body,
      text = true,
      timeout = process_timeout(request),
    })
    :wait()

  return parse_result(result)
end

return M
