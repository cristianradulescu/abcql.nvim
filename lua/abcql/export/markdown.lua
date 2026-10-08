---@class abcql.export.Markdown
local Markdown = {}

--- Make a value safe inside a table cell: pipes are escaped, line breaks become `<br>`
--- @param value any
--- @return string
local function sanitize_cell(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  local str = tostring(value):gsub("\\", "\\\\"):gsub("|", "\\|"):gsub("\r?\n", "<br>"):gsub("\r", "<br>")
  return str
end

--- Format cells as one padded table row
--- @param cells string[]
--- @param widths integer[]
--- @return string
local function format_row(cells, widths)
  local out = {}
  for i, cell in ipairs(cells) do
    out[i] = cell .. string.rep(" ", widths[i] - vim.fn.strdisplaywidth(cell))
  end
  return "| " .. table.concat(out, " | ") .. " |"
end

--- Export QueryResult as a GitHub-flavored Markdown table (for PRs, issues and chat)
--- @param results QueryResult
--- @return string[]|nil lines
--- @return string|nil err
function Markdown.export(results)
  if not results or not results.headers or not results.rows then
    return nil, "Invalid results data"
  end

  local count = #results.headers
  local header = {}
  local widths = {}
  for i = 1, count do
    header[i] = sanitize_cell(results.headers[i])
    widths[i] = math.max(3, vim.fn.strdisplaywidth(header[i]))
  end

  local body = {}
  for r, row in ipairs(results.rows) do
    local cells = {}
    for i = 1, count do
      cells[i] = sanitize_cell(row[i])
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(cells[i]))
    end
    body[r] = cells
  end

  local divider = {}
  for i = 1, count do
    divider[i] = string.rep("-", widths[i])
  end

  local lines = { format_row(header, widths), "| " .. table.concat(divider, " | ") .. " |" }
  for _, cells in ipairs(body) do
    table.insert(lines, format_row(cells, widths))
  end
  return lines
end

return Markdown
