---@class abcql.lsp.Parser
local Parser = {}

---@alias ContextType "DATABASE"|"TABLE"|"COLUMN"|"KEYWORD"

---@class ParseContext
---@field type ContextType Type of completion context
---@field database string|nil Database name if qualified
---@field table string|nil Table name if qualified
---@field partial string Partial text being completed
---@field resolved_from_alias string|nil Original alias that was resolved to table name

---@class AliasMapping
---@field table_name string Actual table name
---@field alias string Alias used in query
---@field database string|nil Optional database qualifier

--- SQL keywords that should trigger table completion
local TABLE_KEYWORDS = {
  "FROM",
  "JOIN",
  "INTO",
  "UPDATE",
  "LEFT JOIN",
  "RIGHT JOIN",
  "INNER JOIN",
  "OUTER JOIN",
  "FULL JOIN",
  "CROSS JOIN",
}

--- SQL keywords that should trigger column completion
local COLUMN_KEYWORDS = {
  "SELECT",
  "WHERE",
  "ORDER BY",
  "GROUP BY",
  "HAVING",
  "SET",
  "ON",
  "AND",
  "OR",
}

--- Parse SQL context at cursor position
---@param line string The current line text
---@param cursor_col number Cursor column position (1-based)
---@param full_query string|nil Optional full query text for alias resolution
---@return ParseContext Context information for completion
function Parser.parse_context(line, cursor_col, full_query)
  local before_cursor = line:sub(1, cursor_col - 1)
  local partial = Parser.extract_partial_word(before_cursor)

  -- Check for qualified identifier (database.table or table.column)
  local qualifier, dot_partial = before_cursor:match("([%w_]+)%.([%w_]*)$")
  if qualifier and dot_partial ~= nil then
    -- NEW: Try to resolve as alias first (if full query provided)
    if full_query then
      local table_name, database = Parser.resolve_alias(qualifier, full_query)
      if table_name then
        -- It's an alias! Return COLUMN context with resolved table
        return {
          type = "COLUMN",
          database = database,
          table = table_name,
          partial = dot_partial,
          resolved_from_alias = qualifier,
        }
      end
    end

    -- Check if this is a database qualifier (db.|)
    -- We need to determine if qualifier is a database or table name
    -- For now, we'll check if it appears after FROM/JOIN keywords
    local before_qualifier = before_cursor:match("^(.*)%s+" .. qualifier .. "%.")
    if before_qualifier and Parser.is_after_table_keyword(before_qualifier) then
      return {
        type = "TABLE",
        database = qualifier,
        table = nil,
        partial = dot_partial,
      }
    else
      -- Assume it's a table qualifier (table.|)
      return {
        type = "COLUMN",
        database = nil,
        table = qualifier,
        partial = dot_partial,
      }
    end
  end

  -- Check for USE statement (database context)
  if before_cursor:match("%s*USE%s+[%w_]*$") then
    return {
      type = "DATABASE",
      database = nil,
      table = nil,
      partial = partial,
    }
  end

  -- Check if after table keyword (FROM, JOIN, etc.)
  if Parser.is_after_table_keyword(before_cursor) then
    return {
      type = "TABLE",
      database = nil,
      table = nil,
      partial = partial,
    }
  end

  -- Check if after column keyword (SELECT, WHERE, etc.)
  if Parser.is_after_column_keyword(before_cursor) then
    return {
      type = "COLUMN",
      database = nil,
      table = nil,
      partial = partial,
    }
  end

  -- Default to keyword completion
  return {
    type = "KEYWORD",
    database = nil,
    table = nil,
    partial = partial,
  }
end

--- Extract the partial word being typed at the end of text
---@param text string Text before cursor
---@return string Partial word
function Parser.extract_partial_word(text)
  local word = text:match("([%w_]*)$")
  return word or ""
end

--- Check if cursor is after a table keyword
---@param text string Text before cursor
---@return boolean True if after table keyword
function Parser.is_after_table_keyword(text)
  local upper_text = text:upper()
  for _, keyword in ipairs(TABLE_KEYWORDS) do
    -- Match: <keyword> <word> OR <keyword>$ (ends with keyword)
    if
      upper_text:match("%s" .. keyword .. "%s+[%w_]*$")
      or upper_text:match("^" .. keyword .. "%s+[%w_]*$")
      or upper_text:match("%s" .. keyword .. "$")
      or upper_text:match("^" .. keyword .. "$")
    then
      return true
    end
  end
  return false
end

--- Check if cursor is after a column keyword
---@param text string Text before cursor
---@return boolean True if after column keyword
function Parser.is_after_column_keyword(text)
  local upper_text = text:upper()
  for _, keyword in ipairs(COLUMN_KEYWORDS) do
    if upper_text:match("%s" .. keyword .. "%s+[%w_]*$") or upper_text:match("^" .. keyword .. "%s+[%w_]*$") then
      return true
    end
  end

  -- Also check for comma-separated list in SELECT
  if upper_text:match("SELECT%s+.*,%s*[%w_]*$") then
    return true
  end

  return false
end

--- Extract table names referenced in the query
---@param text string SQL query text
---@return string[] Array of table names (without aliases)
function Parser.extract_table_names(text)
  local tables = {}
  local upper_text = text:upper()

  -- Match FROM clause tables
  for table_name in upper_text:gmatch("FROM%s+([%w_%.]+)") do
    -- Remove database qualifier if present
    local name = table_name:match("%.([%w_]+)$") or table_name
    table.insert(tables, name:lower())
  end

  -- Match JOIN clause tables
  for table_name in upper_text:gmatch("JOIN%s+([%w_%.]+)") do
    local name = table_name:match("%.([%w_]+)$") or table_name
    table.insert(tables, name:lower())
  end

  return tables
end

--- Extract table names and their aliases from SQL query
---@param text string SQL query text
---@return AliasMapping[] Array of table-alias mappings
function Parser.extract_table_aliases(text)
  local temp_mappings = {} -- Store with position for sorting
  local upper_text = text:upper()
  local original_text = text

  -- Helper to extract database and table from qualified name
  local function parse_table_reference(ref)
    local db, tbl = ref:match("^([%w_]+)%.([%w_]+)$")
    if db and tbl then
      return tbl, db
    end
    return ref, nil
  end

  -- Helper to get original case for identifier
  local function get_original_case(pos, length)
    return original_text:sub(pos, pos + length - 1)
  end

  -- Helper to add mapping with deduplication
  local function add_mapping(position, table_name, alias, database)
    -- Check if already exists
    for _, m in ipairs(temp_mappings) do
      if m.alias:lower() == alias:lower() and m.table_name:lower() == table_name:lower() then
        return -- Already exists
      end
    end
    table.insert(temp_mappings, {
      position = position,
      table_name = table_name:lower(),
      alias = alias:lower(),
      database = database and database:lower() or nil,
    })
  end

  -- Pattern 1: FROM table_name AS alias
  -- Example: FROM users AS u, FROM mydb.users AS u
  for match_start, table_ref, alias_upper in upper_text:gmatch("()FROM%s+([%w_%.]+)%s+AS%s+([%w_]+)") do
    local table_name, database = parse_table_reference(table_ref)
    local alias_start = match_start + #"FROM" + #table_ref + #"AS" + 3
    local alias = get_original_case(alias_start, #alias_upper)
    add_mapping(match_start, table_name, alias, database)
  end

  -- Pattern 2: FROM table_name alias (without AS)
  -- Example: FROM users u, FROM mydb.users u
  for match_start, table_ref, alias_upper in upper_text:gmatch("()FROM%s+([%w_%.]+)%s+([%w_]+)%s*[,;]?%s*[JWGOLHS]?") do
    if not Parser.is_sql_keyword(alias_upper) then
      local table_name, database = parse_table_reference(table_ref)
      local search_pattern = "FROM%s+[%w_%.]+%s+"
      local _, alias_start = upper_text:find(search_pattern, match_start)
      if alias_start then
        local alias = get_original_case(alias_start + 1, #alias_upper)
        add_mapping(match_start, table_name, alias, database)
      end
    end
  end

  -- Pattern 3: JOIN table_name AS alias
  -- Example: JOIN orders AS o, LEFT JOIN mydb.orders AS o
  for match_start, table_ref, alias_upper in upper_text:gmatch("()JOIN%s+([%w_%.]+)%s+AS%s+([%w_]+)") do
    local table_name, database = parse_table_reference(table_ref)
    local alias_start = match_start + #"JOIN" + #table_ref + #"AS" + 3
    local alias = get_original_case(alias_start, #alias_upper)
    add_mapping(match_start, table_name, alias, database)
  end

  -- Pattern 4: JOIN table_name alias (without AS)
  -- Example: JOIN orders o, LEFT JOIN orders o
  for match_start, table_ref, alias_upper in upper_text:gmatch("()JOIN%s+([%w_%.]+)%s+([%w_]+)%s*[,;]?%s*[OJWGOLHS]?") do
    if not Parser.is_sql_keyword(alias_upper) then
      local table_name, database = parse_table_reference(table_ref)
      local search_pattern = "JOIN%s+[%w_%.]+%s+"
      local _, alias_start = upper_text:find(search_pattern, match_start)
      if alias_start then
        local alias = get_original_case(alias_start + 1, #alias_upper)
        add_mapping(match_start, table_name, alias, database)
      end
    end
  end

  -- Sort by position in query (left to right)
  table.sort(temp_mappings, function(a, b)
    return a.position < b.position
  end)

  -- Convert to final format (remove position field)
  local mappings = {}
  for _, m in ipairs(temp_mappings) do
    table.insert(mappings, {
      table_name = m.table_name,
      alias = m.alias,
      database = m.database,
    })
  end

  return mappings
end

--- Check if a word is a SQL keyword
---@param word string Word to check (should be uppercase)
---@return boolean True if word is a SQL keyword
function Parser.is_sql_keyword(word)
  local keywords = {
    "WHERE",
    "AND",
    "OR",
    "ON",
    "USING",
    "GROUP",
    "ORDER",
    "HAVING",
    "LIMIT",
    "OFFSET",
    "UNION",
    "INTERSECT",
    "EXCEPT",
    "SELECT",
    "FROM",
    "JOIN",
    "LEFT",
    "RIGHT",
    "INNER",
    "OUTER",
    "CROSS",
    "FULL",
    "AS",
    "IN",
    "EXISTS",
    "BETWEEN",
    "LIKE",
    "IS",
    "NULL",
    "NOT",
    "SET",
    "VALUES",
    "INTO",
    "UPDATE",
    "INSERT",
    "DELETE",
    "CREATE",
    "ALTER",
    "DROP",
    "TABLE",
    "DATABASE",
    "INDEX",
    "VIEW",
  }
  for _, kw in ipairs(keywords) do
    if word == kw then
      return true
    end
  end
  return false
end

--- Resolve an alias to its actual table name
---@param alias string The alias to resolve
---@param query_text string Full query text for context
---@return string|nil, string|nil table_name, database
function Parser.resolve_alias(alias, query_text)
  local mappings = Parser.extract_table_aliases(query_text)
  local alias_lower = alias:lower()

  for _, mapping in ipairs(mappings) do
    if mapping.alias == alias_lower then
      return mapping.table_name, mapping.database
    end
  end

  return nil, nil
end

return Parser
