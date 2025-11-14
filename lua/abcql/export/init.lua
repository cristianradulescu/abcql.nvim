---@class abcql.export
local Export = {}

---@alias ExportResult { success: boolean, filepath: string?, error: string? }
---@alias ExportOptions { filepath: string? }

local Registry = require("abcql.export.registry")
local CSV = require("abcql.export.csv")
local TSV = require("abcql.export.tsv")
local JSON = require("abcql.export.json")

-- Register built-in formats
Registry.register("csv", CSV.export)
Registry.register("tsv", TSV.export)
Registry.register("json", JSON.export)

--- Generate a default filename with timestamp
--- @param format string The export format (e.g., "csv", "json")
--- @return string filepath The generated filepath
local function generate_filename(format)
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local filename = string.format("query_%s.%s", timestamp, format)
  local cwd = vim.fn.getcwd()
  return cwd .. "/" .. filename
end

--- Export QueryResult to a file in the specified format
--- @param format string The export format (e.g., "csv", "json", "tsv")
--- @param results QueryResult The query results to export
--- @param opts? ExportOptions Optional parameters (filepath)
--- @return ExportResult Result object with success status, filepath, or error
function Export.export(format, results, opts)
  opts = opts or {}

  -- Validate format
  if not format or format == "" then
    return {
      success = false,
      error = "Export format is required",
    }
  end

  -- Check if format is registered
  if not Registry.has(format) then
    local available = table.concat(Registry.list(), ", ")
    return {
      success = false,
      error = string.format("Unknown export format '%s'. Available formats: %s", format, available),
    }
  end

  -- Validate results
  if not results or type(results) ~= "table" then
    return {
      success = false,
      error = "Invalid or missing results data",
    }
  end

  -- Get formatter for this format
  local formatter = Registry.get(format)

  -- Convert results to lines using the formatter
  local lines, err = formatter(results)
  if err then
    return {
      success = false,
      error = string.format("Export formatting failed: %s", err),
    }
  end

  if not lines or #lines == 0 then
    return {
      success = false,
      error = "Formatter produced no output",
    }
  end

  -- Determine filepath
  local filepath = opts.filepath or generate_filename(format)

  -- Write to file
  local write_ok, write_err = pcall(vim.fn.writefile, lines, filepath)
  if not write_ok then
    return {
      success = false,
      error = string.format("Failed to write file: %s", write_err),
    }
  end

  return {
    success = true,
    filepath = filepath,
  }
end

--- Export current query results from the UI
--- @param format string The export format
--- @param opts? ExportOptions Optional parameters
--- @return ExportResult Result object
function Export.export_current(format, opts)
  local UI = require("abcql.ui")
  local current_results = UI.get_current_results()

  if not current_results then
    return {
      success = false,
      error = "No query results available to export. Run a query first.",
    }
  end

  local result = Export.export(format, current_results, opts)

  -- Notify user of the result
  if result.success then
    vim.notify(string.format("Exported to: %s", result.filepath), vim.log.levels.INFO)
  else
    vim.notify(string.format("Export failed: %s", result.error), vim.log.levels.ERROR)
  end

  return result
end

--- Convenience function to export to CSV
--- @param results QueryResult The query results to export
--- @param filepath? string Optional custom filepath
--- @return ExportResult Result object
function Export.export_csv(results, filepath)
  return Export.export("csv", results, { filepath = filepath })
end

--- Convenience function to export to TSV
--- @param results QueryResult The query results to export
--- @param filepath? string Optional custom filepath
--- @return ExportResult Result object
function Export.export_tsv(results, filepath)
  return Export.export("tsv", results, { filepath = filepath })
end

--- Convenience function to export to JSON
--- @param results QueryResult The query results to export
--- @param filepath? string Optional custom filepath
--- @return ExportResult Result object
function Export.export_json(results, filepath)
  return Export.export("json", results, { filepath = filepath })
end

--- Register a custom export format
--- @param name string The format name
--- @param formatter fun(results: QueryResult): string[]?, string? Function that converts results to lines
function Export.register_format(name, formatter)
  Registry.register(name, formatter)
end

--- Get list of available export formats
--- @return string[] List of format names
function Export.list_formats()
  return Registry.list()
end

return Export
