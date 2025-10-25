---@class abcql.db.Query
local Query = {}

--- Execute a query asynchronously using vim.system
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param callback fun(results: table|nil, err: string|nil) Called with parsed results or error
--- @param opts? table Optional parameters passed to adapter's get_args
function Query.execute_async(adapter, query, callback, opts)
  opts = opts or {}

  -- Get CLI command and arguments from adapter
  local cmd = adapter:get_command()
  local args = adapter:get_args(query, opts)

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

      -- Parse output using adapter
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
      }, nil)
    end)
  end)
end

--- Execute a query synchronously (blocking)
--- @param adapter abcql.db.adapter.Adapter The database adapter
--- @param query string The SQL query to execute
--- @param opts? table Optional parameters
--- @return table|nil results Parsed results
--- @return string|nil error Error message if failed
function Query.execute_sync(adapter, query, opts)
  opts = opts or {}

  local cmd = adapter:get_command()
  local args = adapter:get_args(query, opts)

  -- Execute synchronously
  local result = vim.system({ cmd, unpack(args) }, {
    text = true,
    timeout = opts.timeout or 30000,
  }):wait()

  if result.code ~= 0 then
    local error_msg = result.stderr or "Command failed with exit code " .. result.code
    return nil, error_msg
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
  }, nil
end

return Query
