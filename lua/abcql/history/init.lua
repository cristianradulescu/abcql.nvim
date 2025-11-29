--- Query history module for navigating through previously executed queries
---@class abcql.history.History
local History = {}

local Storage = require("abcql.history.storage")

-- Configuration
local MAX_HISTORY_ENTRIES = 100

-- In-memory state
local state = {
  -- Cached list of entry IDs (newest first)
  index = nil,
  -- Current position in history (0 = live/latest result, 1+ = history position)
  position = 0,
  -- Currently loaded entry (cached to avoid re-reading file)
  current_entry = nil,
}

--- Refresh the index from disk
---@return string[] index Array of entry IDs
local function refresh_index()
  state.index = Storage.list_entries()
  return state.index
end

--- Get the current index, refreshing if needed
---@return string[] index Array of entry IDs
local function get_index()
  if not state.index then
    refresh_index()
  end
  return state.index
end

--- Save a query execution to history
---@param query string The SQL query that was executed
---@param datasource_name string Name of the datasource
---@param database string|nil Database name
---@param result table|nil The query result (nil if error)
---@param error string|nil Error message (nil if success)
---@return boolean success True if saved successfully
function History.save(query, datasource_name, database, result, error)
  local entry = {
    id = Storage.generate_id(),
    timestamp = os.time(),
    query = query,
    datasource = datasource_name,
    database = database,
    result = result,
    error = error,
  }

  local ok, err = Storage.write_entry(entry)
  if not ok then
    vim.notify("Failed to save query history: " .. err, vim.log.levels.WARN)
    return false
  end

  -- Invalidate cached index so it gets refreshed on next access
  state.index = nil

  -- Reset position to latest
  state.position = 0
  state.current_entry = nil

  -- Prune old entries
  Storage.prune(MAX_HISTORY_ENTRIES)

  return true
end

--- Get the total number of history entries
---@return number count Number of entries in history
function History.count()
  return #get_index()
end

--- Check if currently viewing the latest (live) result
---@return boolean is_latest True if at position 0 (latest)
function History.is_at_latest()
  return state.position == 0
end

--- Get current position info
---@return number position Current position (0 = latest)
---@return number total Total number of history entries
function History.get_position()
  return state.position, History.count()
end

--- Load a history entry by position
---@param position number Position in history (1 = most recent saved, 2 = second most recent, etc.)
---@return table|nil entry The history entry, or nil if not found
local function load_at_position(position)
  local index = get_index()
  if position < 1 or position > #index then
    return nil
  end

  local id = index[position]
  local entry, err = Storage.read_entry(id)
  if not entry then
    vim.notify("Failed to load history entry: " .. (err or "unknown error"), vim.log.levels.WARN)
    return nil
  end

  return entry
end

--- Navigate to the previous query in history (older)
---@return table|nil entry The history entry to display, or nil if at end
function History.go_back()
  local index = get_index()
  local new_position = state.position + 1

  if new_position > #index then
    vim.notify("No more history", vim.log.levels.INFO)
    return nil
  end

  local entry = load_at_position(new_position)
  if entry then
    state.position = new_position
    state.current_entry = entry
  end

  return entry
end

--- Navigate to the next query in history (newer)
---@return table|nil entry The history entry to display, or nil if at latest
---@return boolean is_latest True if navigated back to latest (live) result
function History.go_forward()
  if state.position <= 0 then
    vim.notify("Already at latest result", vim.log.levels.INFO)
    return nil, true
  end

  local new_position = state.position - 1

  if new_position == 0 then
    -- Back to live result
    state.position = 0
    state.current_entry = nil
    return nil, true
  end

  local entry = load_at_position(new_position)
  if entry then
    state.position = new_position
    state.current_entry = entry
  end

  return entry, false
end

--- Get the current history entry (if viewing history)
---@return table|nil entry The current history entry, or nil if at latest
function History.current()
  if state.position == 0 then
    return nil
  end
  return state.current_entry
end

--- Reset to latest (live) result
function History.reset_to_latest()
  state.position = 0
  state.current_entry = nil
end

--- Clear all history
---@return number deleted Number of entries deleted
function History.clear()
  local deleted = Storage.clear_all()
  state.index = nil
  state.position = 0
  state.current_entry = nil
  return deleted
end

--- Get a preview of recent history entries (for potential picker UI)
---@param limit number|nil Maximum number of entries to return (default 20)
---@return table[] entries Array of {id, timestamp, query_preview, datasource}
function History.get_recent(limit)
  limit = limit or 20
  local index = get_index()
  local entries = {}

  for i = 1, math.min(limit, #index) do
    local entry = load_at_position(i)
    if entry then
      local query_preview = entry.query:gsub("\n", " "):sub(1, 50)
      if #entry.query > 50 then
        query_preview = query_preview .. "..."
      end
      table.insert(entries, {
        id = entry.id,
        timestamp = entry.timestamp,
        query_preview = query_preview,
        datasource = entry.datasource,
        success = entry.error == nil,
      })
    end
  end

  return entries
end

return History
