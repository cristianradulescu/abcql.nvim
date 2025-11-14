---@class abcql.export.JSON
local JSON = {}

--- Check if jq command is available on the system
--- @return boolean available True if jq is available
local function is_jq_available()
  local result = vim.fn.executable("jq")
  return result == 1
end

--- Convert QueryResult to JSON array of objects using jq
--- @param results QueryResult The query results to export
--- @return string[]? lines Array containing JSON output, or nil if error
--- @return string? error Error message if failed
function JSON.export(results)
  -- Validate input
  if not results then
    return nil, "No results to export"
  end

  if type(results) ~= "table" then
    return nil, "Invalid results format"
  end

  -- Check if results has headers
  if not results.headers or type(results.headers) ~= "table" then
    return nil, "Results missing headers"
  end

  -- Check if results has rows
  if not results.rows or type(results.rows) ~= "table" then
    return nil, "Results missing rows"
  end

  -- Check if jq is available
  if not is_jq_available() then
    return nil, "jq command not found. Please install jq to export JSON format."
  end

  -- Build JSON objects manually (simple approach without external dependencies)
  local objects = {}

  for _, row in ipairs(results.rows) do
    local obj_parts = {}
    for i, header in ipairs(results.headers) do
      local value = row[i]
      -- Escape JSON string value
      local json_value
      if value == nil then
        json_value = "null"
      elseif type(value) == "number" then
        json_value = tostring(value)
      elseif type(value) == "boolean" then
        json_value = value and "true" or "false"
      else
        -- String - escape special characters
        local str = tostring(value)
        str = str:gsub("\\", "\\\\") -- Escape backslash
        str = str:gsub('"', '\\"') -- Escape double quote
        str = str:gsub("\n", "\\n") -- Escape newline
        str = str:gsub("\r", "\\r") -- Escape carriage return
        str = str:gsub("\t", "\\t") -- Escape tab
        json_value = '"' .. str .. '"'
      end

      table.insert(obj_parts, string.format('"%s":%s', header, json_value))
    end
    table.insert(objects, "{" .. table.concat(obj_parts, ",") .. "}")
  end

  local json_array = "[" .. table.concat(objects, ",") .. "]"

  -- Use jq to format the JSON nicely
  local jq_result = vim
    .system({ "jq", "." }, {
      text = true,
      stdin = json_array,
    })
    :wait()

  if jq_result.code ~= 0 then
    return nil, "jq formatting failed: " .. (jq_result.stderr or "Unknown error")
  end

  -- Split output into lines
  local lines = vim.split(jq_result.stdout or "", "\n")

  -- Remove trailing empty line if present
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end

  return lines, nil
end

return JSON
