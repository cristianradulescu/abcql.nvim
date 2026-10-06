--- Local sort/filter view over a QueryResult.
---
--- A view never changes the result itself: it computes which rows of `results.rows` are visible
--- and in what order (a list of indices). The results pane renders through it, and cell features
--- and export resolve rows through it, so they always act on what the user sees.
local View = {}

--- @class abcql.ViewFilter
--- @field kind "eq"|"neq"|"null"|"not_null"|"text"
--- @field col number|nil Column index (nil for a text filter matching any column)
--- @field value string|nil Cell value for eq/neq
--- @field text string|nil Search text for a text filter

--- @class abcql.View
--- @field sort { col: number, dir: "asc"|"desc" }|nil
--- @field filters abcql.ViewFilter[]

View.SORT_INDICATOR = { asc = " ▲", desc = " ▼" }

--- @return abcql.View
function View.new()
  return { sort = nil, filters = {} }
end

--- Whether a view changes anything (sort or at least one filter)
--- @param view abcql.View|nil
--- @return boolean
function View.is_active(view)
  return view ~= nil and (view.sort ~= nil or #view.filters > 0)
end

--- NULL cells arrive as the string "NULL" (or nil)
--- @param cell any
--- @return boolean
local function is_null(cell)
  return cell == nil or cell == vim.NIL or cell == "NULL"
end

--- @param cell any
--- @return string
local function cell_text(cell)
  if is_null(cell) then
    return "NULL"
  end
  return tostring(cell)
end

--- Parse a decimal number (no hex: binary cells are rendered as 0x… and must stay strings)
--- @param str string
--- @return number|nil
local function parse_number(str)
  if not str:match("^%s*[-+]?%d*%.?%d+[eE]?[-+]?%d*%s*$") then
    return nil
  end
  return tonumber(str)
end

--- Whether every non-NULL cell of a column is a number (an all-NULL column counts as text)
--- @param rows table[]
--- @param col number
--- @return boolean
local function column_is_numeric(rows, col)
  local seen = false
  for _, row in ipairs(rows) do
    local cell = row[col]
    if not is_null(cell) then
      if parse_number(tostring(cell)) == nil then
        return false
      end
      seen = true
    end
  end
  return seen
end

--- @param row table
--- @param filter abcql.ViewFilter
--- @param ncols number
--- @return boolean
local function matches(row, filter, ncols)
  local kind = filter.kind
  if kind == "null" then
    return is_null(row[filter.col])
  elseif kind == "not_null" then
    return not is_null(row[filter.col])
  elseif kind == "eq" then
    return not is_null(row[filter.col]) and tostring(row[filter.col]) == filter.value
  elseif kind == "neq" then
    return is_null(row[filter.col]) or tostring(row[filter.col]) ~= filter.value
  elseif kind == "text" then
    local needle = filter.text:lower()
    if filter.col then
      return cell_text(row[filter.col]):lower():find(needle, 1, true) ~= nil
    end
    for i = 1, ncols do
      if cell_text(row[i]):lower():find(needle, 1, true) then
        return true
      end
    end
    return false
  end
  return true
end

--- Compute the visible rows: indices into results.rows, filtered then sorted
--- @param results table QueryResult ({headers, rows})
--- @param view abcql.View|nil
--- @return number[]
function View.compute(results, view)
  local rows = results.rows or {}
  local ncols = #(results.headers or {})
  local indices = {}
  for i, row in ipairs(rows) do
    local keep = true
    for _, filter in ipairs(view and view.filters or {}) do
      if not matches(row, filter, ncols) then
        keep = false
        break
      end
    end
    if keep then
      table.insert(indices, i)
    end
  end

  local sort = view and view.sort
  if not sort or #indices < 2 then
    return indices
  end

  local col = sort.col
  local numeric = column_is_numeric(rows, col)
  local keys = {}
  for _, i in ipairs(indices) do
    local cell = rows[i][col]
    if not is_null(cell) then
      keys[i] = numeric and parse_number(tostring(cell)) or tostring(cell)
    end
  end
  local desc = sort.dir == "desc"

  table.sort(indices, function(a, b)
    local ka, kb = keys[a], keys[b]
    if ka == kb then
      return a < b -- stable: ties keep the original order
    end
    -- NULLs first ascending, last descending
    if ka == nil then
      return not desc
    elseif kb == nil then
      return desc
    end
    if desc then
      return ka > kb
    end
    return ka < kb
  end)
  return indices
end

--- Materialize the visible rows (for export)
--- @param results table QueryResult
--- @param indices number[]
--- @return table[]
function View.rows(results, indices)
  local out = {}
  for _, i in ipairs(indices) do
    table.insert(out, results.rows[i])
  end
  return out
end

--- Cycle the sort on a column: asc → desc → off; another column starts at asc
--- @param view abcql.View
--- @param col number
function View.cycle_sort(view, col)
  local sort = view.sort
  if not sort or sort.col ~= col then
    view.sort = { col = col, dir = "asc" }
  elseif sort.dir == "asc" then
    view.sort = { col = col, dir = "desc" }
  else
    view.sort = nil
  end
end

--- Filter on the value of a cell: keep (exclude=false) or drop (exclude=true) equal rows
--- @param col number
--- @param cell any
--- @param exclude boolean|nil
--- @return abcql.ViewFilter
function View.cell_filter(col, cell, exclude)
  if is_null(cell) then
    return { kind = exclude and "not_null" or "null", col = col }
  end
  return { kind = exclude and "neq" or "eq", col = col, value = tostring(cell) }
end

--- Parse text filter input: `text` matches any column, `col:text` one column (case-insensitive
--- column name). A prefix that isn't a column name is part of the text (e.g. `12:30`).
--- @param input string|nil
--- @param headers string[]
--- @return abcql.ViewFilter|nil
function View.parse_text_filter(input, headers)
  if input == nil or input == "" then
    return nil
  end
  local name, rest = input:match("^([^:]+):(.*)$")
  if name then
    local wanted = vim.trim(name):lower()
    for i, header in ipairs(headers or {}) do
      if tostring(header):lower() == wanted then
        if rest == "" then
          return nil
        end
        return { kind = "text", col = i, text = rest }
      end
    end
  end
  return { kind = "text", text = input }
end

--- @param view abcql.View
--- @param filter abcql.ViewFilter|nil
function View.add_filter(view, filter)
  if filter then
    table.insert(view.filters, filter)
  end
end

--- Remove the most recently added filter
--- @param view abcql.View
--- @return boolean removed
function View.pop_filter(view)
  return table.remove(view.filters) ~= nil
end

--- Drop all filters and the sort
--- @param view abcql.View
function View.clear(view)
  view.sort = nil
  view.filters = {}
end

--- @param value string
--- @return string
local function quote(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

--- Human-readable form of a filter, e.g. `status = 'active'`
--- @param filter abcql.ViewFilter
--- @param headers string[]
--- @return string
function View.describe_filter(filter, headers)
  local name = filter.col and tostring(headers[filter.col] or ("#" .. filter.col)) or nil
  local kind = filter.kind
  if kind == "eq" then
    return string.format("%s = %s", name, quote(filter.value))
  elseif kind == "neq" then
    return string.format("%s != %s", name, quote(filter.value))
  elseif kind == "null" then
    return name .. " IS NULL"
  elseif kind == "not_null" then
    return name .. " IS NOT NULL"
  elseif name then
    return string.format("%s contains %s", name, quote(filter.text))
  end
  return "contains " .. quote(filter.text)
end

--- Footer/winbar parts describing the view: "filter: …", "sorted by col ▼"
--- @param view abcql.View|nil
--- @param headers string[]
--- @return string[]
function View.describe(view, headers)
  local parts = {}
  if not view then
    return parts
  end
  if #view.filters > 0 then
    local descs = {}
    for _, filter in ipairs(view.filters) do
      table.insert(descs, View.describe_filter(filter, headers))
    end
    table.insert(parts, "filter: " .. table.concat(descs, " AND "))
  end
  if view.sort then
    local name = tostring(headers[view.sort.col] or ("#" .. view.sort.col))
    table.insert(parts, "sorted by " .. name .. View.SORT_INDICATOR[view.sort.dir])
  end
  return parts
end

--- Header labels with the sort indicator on the sorted column
--- @param headers string[]
--- @param view abcql.View|nil
--- @return string[]
function View.header_labels(headers, view)
  local labels = {}
  for i, header in ipairs(headers) do
    labels[i] = tostring(header)
  end
  if view and view.sort and labels[view.sort.col] then
    labels[view.sort.col] = labels[view.sort.col] .. View.SORT_INDICATOR[view.sort.dir]
  end
  return labels
end

return View
