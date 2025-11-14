---@class abcql.export.Registry
local Registry = {}

---@alias ExportFormatter fun(results: QueryResult): string[], string? -- Returns lines and optional error

-- Internal storage for registered formats
local formats = {}

--- Register a new export format
--- @param name string The format name (e.g., "csv", "json", "tsv")
--- @param formatter ExportFormatter Function that converts QueryResult to array of lines
function Registry.register(name, formatter)
  if type(name) ~= "string" or name == "" then
    error("Format name must be a non-empty string")
  end

  if type(formatter) ~= "function" then
    error("Formatter must be a function")
  end

  formats[name] = formatter
end

--- Get a registered format formatter
--- @param name string The format name
--- @return ExportFormatter|nil formatter The formatter function, or nil if not found
function Registry.get(name)
  return formats[name]
end

--- Check if a format is registered
--- @param name string The format name
--- @return boolean
function Registry.has(name)
  return formats[name] ~= nil
end

--- Get all registered format names
--- @return string[] List of format names
function Registry.list()
  local names = {}
  for name, _ in pairs(formats) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Clear all registered formats (mainly for testing)
function Registry.clear()
  formats = {}
end

return Registry
