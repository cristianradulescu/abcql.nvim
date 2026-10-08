---@class abcql.export
local Export = {}

---@alias ExportResult { success: boolean, filepath: string?, clipboard: boolean?, lines: integer?, error: string? }
---@alias ExportScope "all"|"cell"|"row"|"column"
---@alias ExportTarget { col: integer?, row: any[]? } -- the result cell an export scope is taken from: column index, row values
---@alias ExportContext { table: string?, adapter: abcql.db.adapter.Adapter? } -- where the results came from: the one table the query read (nil when unclear) and the datasource adapter
---@alias ExportOptions { filepath: string?, clipboard: boolean?, context: ExportContext? }

local Registry = require("abcql.export.registry")
local CSV = require("abcql.export.csv")
local TSV = require("abcql.export.tsv")
local JSON = require("abcql.export.json")
local Values = require("abcql.export.values")
local Rows = require("abcql.export.rows")
local Markdown = require("abcql.export.markdown")
local Insert = require("abcql.export.insert")

-- Register built-in formats
Registry.register("csv", CSV.export, "comma-separated table, RFC 4180 quoting")
Registry.register("tsv", TSV.export, "tab-separated table")
Registry.register("json", JSON.export, "array of objects (needs jq)")
Registry.register("values", Values.export, "one comma-separated line for IN (...)")
Registry.register("rows", Rows.export, "one value per line")
Registry.register("markdown", Markdown.export, "GitHub-style pipe table")
Registry.register("insert", Insert.export, "INSERT INTO statement (<table> placeholder if unclear)")

-- File extension per format when it differs from the format name
local EXTENSIONS = { markdown = "md", insert = "sql" }

--- Generate a default filename with timestamp
--- @param format string The export format (e.g., "csv", "json")
--- @return string filepath The generated filepath
local function generate_filename(format)
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local filename = string.format("query_%s.%s", timestamp, EXTENSIONS[format] or format)
  local cwd = vim.fn.getcwd()
  return cwd .. "/" .. filename
end

--- Export QueryResult to a file (or the clipboard) in the specified format
--- @param format string The export format (e.g., "csv", "json", "tsv")
--- @param results QueryResult The query results to export
--- @param opts? ExportOptions Optional parameters (filepath; clipboard = true copies to the `"` and `+` registers instead of writing a file)
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
  local lines, err = formatter(results, opts.context)
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

  if opts.clipboard then
    -- a single line (e.g. a value list) pastes inline; several lines paste as whole lines
    local text, regtype = lines, "l"
    if #lines == 1 then
      text, regtype = lines[1], "v"
    end
    vim.fn.setreg('"', text, regtype)
    vim.fn.setreg("+", text, regtype)
    return {
      success = true,
      clipboard = true,
      lines = #lines,
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

--- Narrow results down to a scope, as a QueryResult of its own so any formatter can export it
--- @param results QueryResult
--- @param scope ExportScope "all" (everything), or one "cell", "row" or "column" of `target`
--- @param target? ExportTarget
--- @return QueryResult? subset
--- @return string? err
function Export.slice(results, scope, target)
  target = target or {}
  if scope == "all" then
    return results
  elseif scope == "cell" then
    if not (target.col and target.row) then
      return nil, "No cell under cursor"
    end
    return { headers = { results.headers[target.col] }, rows = { { target.row[target.col] } } }
  elseif scope == "row" then
    if not target.row then
      return nil, "No row under cursor"
    end
    return { headers = results.headers, rows = { target.row } }
  elseif scope == "column" then
    if not (target.col and results.headers[target.col]) then
      return nil, "No column under cursor"
    end
    local rows = {}
    for i, row in ipairs(results.rows) do
      rows[i] = { row[target.col] }
    end
    return { headers = { results.headers[target.col] }, rows = rows }
  end
  return nil, string.format("Unknown export scope '%s'", tostring(scope))
end

--- Ask which export format to use
--- @param prompt string
--- @param callback fun(format: string)
local function select_format(prompt, callback)
  vim.ui.select(Registry.list(), {
    prompt = prompt,
    format_item = function(name)
      local description = Registry.description(name)
      return description and string.format("%-9s %s", name, description) or name
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

--- Where the displayed result came from: the datasource adapter and, when the query read exactly
--- one table, its name (formats like "insert" use it; joins and unknown queries leave it nil)
--- @return ExportContext
local function source_context()
  local opts = require("abcql.ui").get_display_opts()
  local sql = opts.sent_query or opts.query
  local names = sql and require("abcql.lsp.parser").extract_table_names(sql) or {}
  return {
    table = #names == 1 and names[1] or nil,
    adapter = opts.datasource and opts.datasource.adapter or nil,
  }
end

--- Export (part of) the current query results from the UI, to a file or the clipboard.
--- This is the single entry point for the export commands and the results yank keys.
--- @param format? string The export format; asked for with vim.ui.select when nil or empty
--- @param opts? ExportOptions|{ scope: ExportScope? } scope defaults to "all"; the cell/row/column is taken at the cursor
--- @return ExportResult? result Result object (nil when the format is still being asked for)
function Export.export_current(format, opts)
  opts = opts or {}
  local scope = opts.scope or "all"
  local UI = require("abcql.ui")
  -- Export what the user sees: the sorted/filtered view, not the full loaded result
  local visible, filtered = UI.get_visible_results()

  if not visible then
    local result = { success = false, error = "No query results available to export. Run a query first." }
    vim.notify(string.format("Export failed: %s", result.error), vim.log.levels.ERROR)
    return result
  end

  -- Resolve the scope now: the format picker may move the cursor away from the results window
  local data, scope_err = Export.slice(visible, scope, UI.get_cursor_target())
  if not data then
    vim.notify(string.format("Export failed: %s", scope_err), vim.log.levels.ERROR)
    return { success = false, error = scope_err }
  end

  opts = vim.tbl_extend("keep", opts, { context = source_context() })

  if not format or format == "" then
    select_format(opts.clipboard and "Copy as:" or "Export as:", function(choice)
      Export.finish(choice, data, opts, scope, filtered and #visible.rows or nil)
    end)
    return nil
  end
  return Export.finish(format, data, opts, scope, filtered and #visible.rows or nil)
end

--- Ask whether to open an exported file; it opens in the editor window so the results/tree
--- panels (pinned with winfixbuf) keep their buffers
--- @param filepath string
local function offer_to_open(filepath)
  vim.ui.select(
    { "Yes", "No" },
    { prompt = "Open " .. vim.fn.fnamemodify(filepath, ":t") .. " in editor?" },
    function(choice)
      if choice ~= "Yes" then
        return
      end
      local UI = require("abcql.ui")
      local win = UI.get_editor_win()
      if win then
        vim.api.nvim_set_current_win(win)
      end
      vim.cmd.edit(vim.fn.fnameescape(filepath))
    end
  )
end

--- Export already-resolved data and tell the user how it went
--- @param format string
--- @param data QueryResult
--- @param opts ExportOptions
--- @param scope ExportScope
--- @param filtered_rows? integer Row count of the filtered view, when the view is filtered
--- @return ExportResult
function Export.finish(format, data, opts, scope, filtered_rows)
  local result = Export.export(format, data, opts)
  if not result.success then
    vim.notify(string.format("Export failed: %s", result.error), vim.log.levels.ERROR)
    return result
  end

  local note = ""
  if filtered_rows and (scope == "all" or scope == "column") then
    local total = #require("abcql.ui").get_current_results().rows
    note = string.format(" (filtered view: %d of %d rows)", filtered_rows, total)
  end
  if result.clipboard then
    local what = scope == "all" and "results" or scope
    vim.notify(string.format("Copied %s as %s to clipboard%s", what, format, note), vim.log.levels.INFO)
  else
    vim.notify(string.format("Exported to: %s%s", result.filepath, note), vim.log.levels.INFO)
    offer_to_open(result.filepath)
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
--- @param description? string Short description shown in the format picker
function Export.register_format(name, formatter, description)
  Registry.register(name, formatter, description)
end

--- Get list of available export formats
--- @return string[] List of format names
function Export.list_formats()
  return Registry.list()
end

return Export
