--- Storage module for query history persistence
--- Handles file I/O operations for saving and loading history entries
---@class abcql.history.Storage
local Storage = {}

local HISTORY_DIR = ".abcql/query_history"
local MAX_ROWS_TO_SAVE = 1000 -- Limit rows saved per query to manage disk space

--- Get the history directory path
---@return string The absolute path to the history directory
function Storage.get_history_dir()
  return vim.fn.getcwd() .. "/" .. HISTORY_DIR
end

--- Ensure the history directory exists
---@return boolean success True if directory exists or was created
---@return string|nil error Error message if failed
function Storage.ensure_dir()
  local dir = Storage.get_history_dir()
  if vim.fn.isdirectory(dir) == 1 then
    return true, nil
  end

  local ok = vim.fn.mkdir(dir, "p")
  if ok == 0 then
    return false, "Failed to create history directory: " .. dir
  end

  return true, nil
end

--- Generate a unique ID for a history entry
---@return string id Unique identifier (timestamp-based)
function Storage.generate_id()
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local random_suffix = string.format("%03d", math.random(0, 999))
  return timestamp .. "_" .. random_suffix
end

--- Get the file path for a history entry
---@param id string The entry ID
---@return string path The full file path
function Storage.get_entry_path(id)
  return Storage.get_history_dir() .. "/" .. id .. ".json"
end

--- Encode a Lua table to JSON string
---@param data table The data to encode
---@return string|nil json The JSON string, or nil on error
---@return string|nil error Error message if encoding failed
local function encode_json(data)
  local ok, result = pcall(vim.fn.json_encode, data)
  if not ok then
    return nil, "JSON encoding failed: " .. tostring(result)
  end
  return result, nil
end

--- Decode a JSON string to Lua table
---@param json string The JSON string to decode
---@return table|nil data The decoded data, or nil on error
---@return string|nil error Error message if decoding failed
local function decode_json(json)
  local ok, result = pcall(vim.fn.json_decode, json)
  if not ok then
    return nil, "JSON decoding failed: " .. tostring(result)
  end
  return result, nil
end

--- Truncate result rows if they exceed the maximum
---@param result table The query result
---@return table result The potentially truncated result
local function truncate_rows(result)
  if not result or not result.rows then
    return result
  end

  if #result.rows <= MAX_ROWS_TO_SAVE then
    return result
  end

  -- Create a copy with truncated rows
  local truncated = vim.deepcopy(result)
  truncated.rows = {}
  for i = 1, MAX_ROWS_TO_SAVE do
    truncated.rows[i] = result.rows[i]
  end
  truncated.truncated = true
  truncated.original_row_count = result.row_count

  return truncated
end

--- Write a history entry to disk
---@param entry table The history entry to save
---@return boolean success True if saved successfully
---@return string|nil error Error message if failed
function Storage.write_entry(entry)
  local ok, err = Storage.ensure_dir()
  if not ok then
    return false, err
  end

  -- Truncate large result sets
  if entry.result then
    entry.result = truncate_rows(entry.result)
  end

  local json, encode_err = encode_json(entry)
  if not json then
    return false, encode_err
  end

  local path = Storage.get_entry_path(entry.id)
  local file, open_err = io.open(path, "w")
  if not file then
    return false, "Failed to open file for writing: " .. tostring(open_err)
  end

  file:write(json)
  file:close()

  return true, nil
end

--- Read a history entry from disk
---@param id string The entry ID to load
---@return table|nil entry The loaded entry, or nil on error
---@return string|nil error Error message if failed
function Storage.read_entry(id)
  local path = Storage.get_entry_path(id)

  local file, open_err = io.open(path, "r")
  if not file then
    return nil, "Failed to open history file: " .. tostring(open_err)
  end

  local content = file:read("*a")
  file:close()

  if not content or content == "" then
    return nil, "Empty history file"
  end

  local entry, decode_err = decode_json(content)
  if not entry then
    return nil, decode_err
  end

  return entry, nil
end

--- List all history entry IDs sorted by timestamp (newest first)
---@return string[] ids Array of entry IDs
function Storage.list_entries()
  local dir = Storage.get_history_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local entries = {}
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return {}
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "file" and name:match("%.json$") then
      local id = name:gsub("%.json$", "")
      table.insert(entries, id)
    end
  end

  -- Sort by ID (which is timestamp-based) in descending order (newest first)
  table.sort(entries, function(a, b)
    return a > b
  end)

  return entries
end

--- Delete a history entry
---@param id string The entry ID to delete
---@return boolean success True if deleted successfully
---@return string|nil error Error message if failed
function Storage.delete_entry(id)
  local path = Storage.get_entry_path(id)
  local ok, err = os.remove(path)
  if not ok then
    return false, "Failed to delete history entry: " .. tostring(err)
  end
  return true, nil
end

--- Prune old entries, keeping only the most recent ones
---@param max_entries number Maximum number of entries to keep
---@return number deleted Number of entries deleted
function Storage.prune(max_entries)
  local entries = Storage.list_entries()
  local deleted = 0

  if #entries <= max_entries then
    return 0
  end

  -- Delete oldest entries (they are at the end since list is sorted newest first)
  for i = max_entries + 1, #entries do
    local ok = Storage.delete_entry(entries[i])
    if ok then
      deleted = deleted + 1
    end
  end

  return deleted
end

--- Clear all history entries
---@return number deleted Number of entries deleted
function Storage.clear_all()
  local entries = Storage.list_entries()
  local deleted = 0

  for _, id in ipairs(entries) do
    local ok = Storage.delete_entry(id)
    if ok then
      deleted = deleted + 1
    end
  end

  return deleted
end

return Storage
