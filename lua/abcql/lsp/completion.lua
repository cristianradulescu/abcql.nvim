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

--- Generate completion items for databases
---@param databases string[] Array of database names
---@param partial string Partial text to filter by
---@return table[] Array of LSP completion items
function Completion.create_database_items(databases, partial)
  local items = {}
  local partial_lower = partial:lower()

  for _, db in ipairs(databases) do
    if db:lower():find(partial_lower, 1, true) then
      local priority = 1
      if db:lower():sub(1, #partial_lower) == partial_lower then
        priority = 0 -- Prefix match gets higher priority
      end

      table.insert(items, {
        label = db,
        kind = CompletionItemKind.Module,
        detail = "Database",
        documentation = "Database: " .. db,
        insertText = db,
        sortText = string.format("%d_%s", priority, db),
        filterText = db,
      })
    end
  end

  return items
end

--- Generate completion items for tables
---@param tables string[] Array of table names
---@param partial string Partial text to filter by
---@param database string|nil Optional database name for detail
---@return table[] Array of LSP completion items
function Completion.create_table_items(tables, partial, database)
  local items = {}
  local partial_lower = partial:lower()

  for _, table_name in ipairs(tables) do
    if table_name:lower():find(partial_lower, 1, true) then
      local priority = 1
      if table_name:lower():sub(1, #partial_lower) == partial_lower then
        priority = 0
      end

      local detail = "Table"
      if database then
        detail = "Table in database: " .. database
      end

      table.insert(items, {
        label = table_name,
        kind = CompletionItemKind.Class,
        detail = detail,
        documentation = "Type: TABLE",
        insertText = table_name,
        sortText = string.format("%d_%s", priority, table_name),
        filterText = table_name,
      })
    end
  end

  return items
end

--- Generate completion items for columns
---@param columns ColumnInfo[] Array of column info
---@param partial string Partial text to filter by
---@param table_name string|nil Optional table name for detail
---@param alias string|nil Optional alias that was used to reference the table
---@return table[] Array of LSP completion items
function Completion.create_column_items(columns, partial, table_name, alias)
  local items = {}
  local partial_lower = partial:lower()

  for _, col in ipairs(columns) do
    if col.name:lower():find(partial_lower, 1, true) then
      local priority = 1
      if col.name:lower():sub(1, #partial_lower) == partial_lower then
        priority = 0
      end

      local detail = col.type
      local documentation = "Type: " .. col.type

      if alias and table_name and alias ~= table_name then
        -- Show alias -> table mapping
        detail = col.type .. " (" .. alias .. " → " .. table_name .. ")"
        documentation = "Type: " .. col.type .. "\nTable: " .. table_name .. " (alias: " .. alias .. ")"
      elseif table_name then
        detail = col.type .. " (" .. table_name .. ")"
        documentation = "Type: " .. col.type .. "\nTable: " .. table_name
      end

      table.insert(items, {
        label = col.name,
        kind = CompletionItemKind.Field,
        detail = detail,
        documentation = documentation,
        insertText = col.name,
        sortText = string.format("%d_%s", priority, col.name),
        filterText = col.name,
      })
    end
  end

  return items
end

--- Generate completion items for SQL keywords
---@param partial string Partial text to filter by
---@return table[] Array of LSP completion items
function Completion.create_keyword_items(partial)
  local items = {}
  local partial_upper = partial:upper()

  for _, keyword in ipairs(SQL_KEYWORDS) do
    if keyword:find(partial_upper, 1, true) then
      local priority = 1
      if keyword:sub(1, #partial_upper) == partial_upper then
        priority = 0
      end

      table.insert(items, {
        label = keyword,
        kind = CompletionItemKind.Keyword,
        detail = "SQL Keyword",
        documentation = "SQL keyword: " .. keyword,
        insertText = keyword,
        sortText = string.format("%d_%s", priority, keyword),
        filterText = keyword,
      })
    end
  end

  return items
end

--- Generate completion items for all tables across databases
---@param all_tables table<string, string[]> Tables by database
---@param partial string Partial text to filter by
---@return table[] Array of LSP completion items
function Completion.create_all_table_items(all_tables, partial)
  local items = {}
  for database, tables in pairs(all_tables) do
    local db_items = Completion.create_table_items(tables, partial, database)
    vim.list_extend(items, db_items)
  end
  return items
end

--- Generate completion items for all columns from multiple tables
---@param cache abcql.lsp.Cache Cache instance
---@param datasource_name string Datasource name
---@param table_names string[] Array of table names to get columns from
---@param database string|nil Optional database name
---@param partial string Partial text to filter by
---@return table[] Array of LSP completion items
function Completion.create_columns_from_tables(cache, datasource_name, table_names, database, partial)
  local items = {}
  local seen = {} -- Track seen column names to avoid duplicates

  for _, table_name in ipairs(table_names) do
    -- Try to get columns with database qualifier first
    local columns = nil
    if database then
      columns = cache:get_columns(datasource_name, database, table_name)
    else
      -- Try to find table in any database
      local all_tables = cache:get_all_tables(datasource_name)
      if all_tables then
        for db, tables in pairs(all_tables) do
          for _, tbl in ipairs(tables) do
            if tbl == table_name then
              columns = cache:get_columns(datasource_name, db, table_name)
              if columns then
                break
              end
            end
          end
          if columns then
            break
          end
        end
      end
    end

    if columns then
      for _, col in ipairs(columns) do
        -- Only add if we haven't seen this column name yet
        if not seen[col.name] then
          seen[col.name] = true
          local col_items = Completion.create_column_items({ col }, partial, table_name)
          vim.list_extend(items, col_items)
        end
      end
    end
  end

  return items
end

return Completion
