---@class abcql.lsp.Completion
local Completion = {}

--- Common SQL keywords
local SQL_KEYWORDS = {
  "SELECT",
  "FROM",
  "WHERE",
  "JOIN",
  "LEFT JOIN",
  "RIGHT JOIN",
  "INNER JOIN",
  "OUTER JOIN",
  "ON",
  "AND",
  "OR",
  "NOT",
  "IN",
  "EXISTS",
  "BETWEEN",
  "LIKE",
  "IS",
  "NULL",
  "ORDER BY",
  "GROUP BY",
  "HAVING",
  "LIMIT",
  "OFFSET",
  "INSERT",
  "INTO",
  "VALUES",
  "UPDATE",
  "SET",
  "DELETE",
  "CREATE",
  "ALTER",
  "DROP",
  "TABLE",
  "DATABASE",
  "INDEX",
  "VIEW",
  "AS",
  "DISTINCT",
  "COUNT",
  "SUM",
  "AVG",
  "MAX",
  "MIN",
  "CASE",
  "WHEN",
  "THEN",
  "ELSE",
  "END",
  "UNION",
  "ALL",
  "ASC",
  "DESC",
  "USE",
  "SHOW",
  "SHOW CREATE TABLE",
  "DESCRIBE",
}

--- LSP completion item kinds
local CompletionItemKind = {
  Text = 1,
  Method = 2,
  Function = 3,
  Constructor = 4,
  Field = 5,
  Variable = 6,
  Class = 7,
  Interface = 8,
  Module = 9,
  Property = 10,
  Unit = 11,
  Value = 12,
  Enum = 13,
  Keyword = 14,
  Snippet = 15,
  Color = 16,
  File = 17,
  Reference = 18,
  Folder = 19,
  EnumMember = 20,
  Constant = 21,
  Struct = 22,
  Event = 23,
  Operator = 24,
  TypeParameter = 25,
}
Completion.Kind = CompletionItemKind

--- Sort groups: lower sorts first. Items from the statement's own tables
--- come before the schema-wide fallback, keywords last.
Completion.RANK = { PRIMARY = 0, SECONDARY = 1, KEYWORD = 2 }

--- Whether `name` matches the partial, and with which priority
--- @param name string
--- @param partial_lower string
--- @return number|nil priority 0 for prefix match, 1 for substring match, nil for no match
local function match_priority(name, partial_lower)
  local lower = name:lower()
  if partial_lower == "" or lower:sub(1, #partial_lower) == partial_lower then
    return 0
  end
  if lower:find(partial_lower, 1, true) then
    return 1
  end
  return nil
end

--- Build one completion item
--- @param opts { label: string, kind: number, detail: string, documentation: string, partial: string, rank: number?, insertText: string?, insertTextFormat: number?, labelDetails: table? }
--- @return table|nil
local function make_item(opts)
  local priority = match_priority(opts.label, opts.partial:lower())
  if not priority then
    return nil
  end
  return {
    label = opts.label,
    labelDetails = opts.labelDetails,
    kind = opts.kind,
    detail = opts.detail,
    documentation = opts.documentation,
    insertText = opts.insertText or opts.label,
    insertTextFormat = opts.insertTextFormat,
    sortText = string.format("%d%d_%s", opts.rank or Completion.RANK.PRIMARY, priority, opts.label:lower()),
    filterText = opts.label,
  }
end

--- Generate completion items for databases
---@param databases string[] Array of database names
---@param partial string Partial text to filter by
---@param rank number|nil Sort group
---@return table[] Array of LSP completion items
function Completion.create_database_items(databases, partial, rank)
  local items = {}
  for _, db in ipairs(databases) do
    local item = make_item({
      label = db,
      kind = CompletionItemKind.Module,
      detail = "Database",
      documentation = "Database: " .. db,
      partial = partial,
      rank = rank,
    })
    if item then
      table.insert(items, item)
    end
  end
  return items
end

--- Generate completion items for tables
---@param tables string[] Array of table names
---@param partial string Partial text to filter by
---@param database string|nil Optional database name for detail
---@param rank number|nil Sort group
---@return table[] Array of LSP completion items
function Completion.create_table_items(tables, partial, database, rank)
  local items = {}
  for _, table_name in ipairs(tables) do
    local item = make_item({
      label = table_name,
      kind = CompletionItemKind.Class,
      detail = database and ("Table in database: " .. database) or "Table",
      documentation = "Type: TABLE",
      labelDetails = database and { description = database } or nil,
      partial = partial,
      rank = rank,
    })
    if item then
      table.insert(items, item)
    end
  end
  return items
end

--- Generate completion items for columns
---@param columns ColumnInfo[] Array of column info
---@param partial string Partial text to filter by
---@param table_name string|nil Optional table name for detail
---@param alias string|nil Optional alias that was used to reference the table
---@param rank number|nil Sort group
---@return table[] Array of LSP completion items
function Completion.create_column_items(columns, partial, table_name, alias, rank)
  local items = {}
  for _, col in ipairs(columns) do
    local detail = col.type
    local documentation = "Type: " .. col.type
    if alias and table_name and alias ~= table_name then
      detail = col.type .. " (" .. alias .. " → " .. table_name .. ")"
      documentation = "Type: " .. col.type .. "\nTable: " .. table_name .. " (alias: " .. alias .. ")"
    elseif table_name then
      detail = col.type .. " (" .. table_name .. ")"
      documentation = "Type: " .. col.type .. "\nTable: " .. table_name
    end

    local item = make_item({
      label = col.name,
      kind = CompletionItemKind.Field,
      detail = detail,
      documentation = documentation,
      labelDetails = table_name and { description = table_name } or nil,
      partial = partial,
      rank = rank,
    })
    if item then
      table.insert(items, item)
    end
  end
  return items
end

--- Generate completion items for SQL keywords
---@param partial string Partial text to filter by
---@param rank number|nil Sort group (defaults to KEYWORD)
---@return table[] Array of LSP completion items
function Completion.create_keyword_items(partial, rank)
  local items = {}
  for _, keyword in ipairs(SQL_KEYWORDS) do
    local item = make_item({
      label = keyword,
      kind = CompletionItemKind.Keyword,
      detail = "SQL Keyword",
      documentation = "SQL keyword: " .. keyword,
      partial = partial,
      rank = rank or Completion.RANK.KEYWORD,
    })
    if item then
      table.insert(items, item)
    end
  end
  return items
end

--- Generate completion items for all tables across databases
---@param all_tables table<string, string[]> Tables by database
---@param partial string Partial text to filter by
---@param rank number|nil Sort group
---@return table[] Array of LSP completion items
function Completion.create_all_table_items(all_tables, partial, rank)
  local items = {}
  for database, tables in pairs(all_tables) do
    vim.list_extend(items, Completion.create_table_items(tables, partial, database, rank))
  end
  return items
end

--- Snippet items that expand `INSERT INTO <table>` into a full statement with
--- the table's columns as tab stops.
---@param cache abcql.lsp.Cache
---@param datasource_name string
---@param all_tables table<string, string[]>
---@param partial string
---@return table[]
function Completion.create_insert_snippet_items(cache, datasource_name, all_tables, partial)
  local items = {}
  for database, tables in pairs(all_tables) do
    for _, table_name in ipairs(tables) do
      local columns = cache:get_columns(datasource_name, database, table_name)
      if columns and #columns > 0 and match_priority(table_name, partial:lower()) then
        local names, stops = {}, {}
        for i, col in ipairs(columns) do
          table.insert(names, col.name)
          table.insert(stops, string.format("${%d:%s}", i, col.name))
        end
        table.insert(items, {
          label = table_name .. " (…) VALUES (…)",
          kind = CompletionItemKind.Snippet,
          detail = "INSERT template for " .. table_name,
          documentation = "Columns: " .. table.concat(names, ", "),
          insertText = string.format(
            "%s (%s)\nVALUES (%s)",
            table_name,
            table.concat(names, ", "),
            table.concat(stops, ", ")
          ),
          insertTextFormat = 2,
          sortText = string.format("%d1_%s", Completion.RANK.PRIMARY, table_name:lower()),
          filterText = table_name,
        })
      end
    end
  end
  return items
end

--- Generate completion items for all columns from multiple tables
---@param cache abcql.lsp.Cache Cache instance
---@param datasource_name string Datasource name
---@param table_names string[] Array of table names to get columns from
---@param database string|nil Optional database name
---@param partial string Partial text to filter by
---@param rank number|nil Sort group
---@return table[] Array of LSP completion items
function Completion.create_columns_from_tables(cache, datasource_name, table_names, database, partial, rank)
  local items = {}
  local seen = {} -- Track seen column names to avoid duplicates

  for _, table_name in ipairs(table_names) do
    local db, real_name = cache:find_table(datasource_name, table_name, database)
    local columns = db and cache:get_columns(datasource_name, db, real_name) or nil
    if columns then
      for _, col in ipairs(columns) do
        if not seen[col.name] then
          seen[col.name] = true
          vim.list_extend(items, Completion.create_column_items({ col }, partial, real_name, nil, rank))
        end
      end
    end
  end

  return items
end

return Completion
