---@class abcql.lsp.Parser
local Parser = {}

---@alias ContextType "DATABASE"|"TABLE"|"COLUMN"|"KEYWORD"

---@class ParseContext
---@field type ContextType Type of completion context
---@field database string|nil Database name if qualified
---@field table string|nil Table name if qualified
---@field partial string Partial text being completed
---@field resolved_from_alias string|nil Original alias that was resolved to table name
---@field clause string|nil Uppercased clause keyword the cursor is in (FROM, WHERE, INTO, ...)

---@class AliasMapping
---@field table_name string Actual table name
---@field alias string Alias used in query
---@field database string|nil Optional database qualifier

--- Clause keywords and the completion context they open. The cursor's
--- context is decided by the closest clause keyword before it, so comma
--- lists (`FROM a, b|`, `SELECT x, y|`) and multi-line clauses work.
--- Longer keywords must come before their suffixes (LEFT JOIN before JOIN).
local CLAUSES = {
  { keyword = "SHOW CREATE TABLE", context = "TABLE" },
  { keyword = "INSERT INTO", context = "TABLE" },
  { keyword = "LEFT OUTER JOIN", context = "TABLE" },
  { keyword = "RIGHT OUTER JOIN", context = "TABLE" },
  { keyword = "FULL OUTER JOIN", context = "TABLE" },
  { keyword = "LEFT JOIN", context = "TABLE" },
  { keyword = "RIGHT JOIN", context = "TABLE" },
  { keyword = "INNER JOIN", context = "TABLE" },
  { keyword = "OUTER JOIN", context = "TABLE" },
  { keyword = "CROSS JOIN", context = "TABLE" },
  { keyword = "FULL JOIN", context = "TABLE" },
  { keyword = "JOIN", context = "TABLE" },
  { keyword = "FROM", context = "TABLE" },
  { keyword = "INTO", context = "TABLE" },
  { keyword = "UPDATE", context = "TABLE" },
  { keyword = "DESCRIBE", context = "TABLE" },
  { keyword = "TRUNCATE TABLE", context = "TABLE" },
  { keyword = "TRUNCATE", context = "TABLE" },
  { keyword = "DROP TABLE", context = "TABLE" },
  { keyword = "ALTER TABLE", context = "TABLE" },
  { keyword = "USE", context = "DATABASE" },
  { keyword = "ORDER BY", context = "COLUMN" },
  { keyword = "GROUP BY", context = "COLUMN" },
  { keyword = "SELECT", context = "COLUMN" },
  { keyword = "WHERE", context = "COLUMN" },
  { keyword = "HAVING", context = "COLUMN" },
  { keyword = "SET", context = "COLUMN" },
  { keyword = "ON", context = "COLUMN" },
  { keyword = "AND", context = "COLUMN" },
  { keyword = "OR", context = "COLUMN" },
  { keyword = "VALUES", context = "KEYWORD" },
  { keyword = "LIMIT", context = "KEYWORD" },
  { keyword = "OFFSET", context = "KEYWORD" },
}

--- Escape a keyword for use in a Lua pattern, turning spaces into `%s+`
--- @param keyword string
--- @return string
local function keyword_pattern(keyword)
  return (keyword:gsub("%s+", "%%s+"))
end

--- Find the closest clause keyword before the end of `text`
--- @param text string Text before the cursor (may span lines)
--- @return { keyword: string, context: ContextType, stop: number }|nil
function Parser.last_clause(text)
  local upper = text:upper()
  local best = nil
  for _, clause in ipairs(CLAUSES) do
    local pattern = "%f[%w_]" .. keyword_pattern(clause.keyword) .. "%f[^%w_]"
    local init = 1
    while true do
      local s, e = upper:find(pattern, init)
      if not s then
        break
      end
      if not best or e > best.stop then
        best = { keyword = clause.keyword, context = clause.context, start = s, stop = e }
      end
      init = e + 1
    end
  end
  return best
end

--- Parse SQL context at cursor position
---@param text string The text containing the cursor (a line or a whole statement)
---@param cursor_col number Cursor column position within `text` (1-based)
---@param full_query string|nil Optional full statement text for alias resolution
---@return ParseContext Context information for completion
function Parser.parse_context(text, cursor_col, full_query)
  local before_cursor = text:sub(1, cursor_col - 1)
  local partial = Parser.extract_partial_word(before_cursor)
  local clause = Parser.last_clause(before_cursor)
  local clause_keyword = clause and clause.keyword or nil

  -- Qualified identifier (database.table, table.column, alias.column), backticks allowed
  local qualifier, dot_partial = before_cursor:match("`?([%w_]+)`?%.`?([%w_]*)$")
  if qualifier and dot_partial ~= nil then
    if full_query then
      local table_name, database = Parser.resolve_alias(qualifier, full_query)
      if table_name then
        return {
          type = "COLUMN",
          database = database,
          table = table_name,
          partial = dot_partial,
          resolved_from_alias = qualifier,
          clause = clause_keyword,
        }
      end
    end

    if clause and clause.context == "TABLE" then
      return {
        type = "TABLE",
        database = qualifier,
        table = nil,
        partial = dot_partial,
        clause = clause_keyword,
      }
    end

    return {
      type = "COLUMN",
      database = nil,
      table = qualifier,
      partial = dot_partial,
      clause = clause_keyword,
    }
  end

  if clause and clause.context ~= "KEYWORD" then
    return {
      type = clause.context,
      database = nil,
      table = nil,
      partial = partial,
      clause = clause_keyword,
    }
  end

  return {
    type = "KEYWORD",
    database = nil,
    table = nil,
    partial = partial,
    clause = clause_keyword,
  }
end

--- Extract the partial word being typed at the end of text
---@param text string Text before cursor
---@return string Partial word
function Parser.extract_partial_word(text)
  local word = text:match("`?([%w_]*)$")
  return word or ""
end

--- Check if cursor is after a table keyword
---@param text string Text before cursor
---@return boolean True if after table keyword
function Parser.is_after_table_keyword(text)
  local clause = Parser.last_clause(text)
  return clause ~= nil and clause.context == "TABLE"
end

--- Check if cursor is after a column keyword
---@param text string Text before cursor
---@return boolean True if after column keyword
function Parser.is_after_column_keyword(text)
  local clause = Parser.last_clause(text)
  return clause ~= nil and clause.context == "COLUMN"
end

--- Extract table names referenced in the query (FROM / JOIN / INTO / UPDATE),
--- in their original case, without database qualifiers or CTE names.
---@param text string SQL query text
---@return string[] Array of table names
function Parser.extract_table_names(text)
  local tables = {}
  local seen = {}
  local ctes = {}
  for _, name in ipairs(Parser.extract_cte_names(text)) do
    ctes[name:lower()] = true
  end

  local function add(ref)
    local name = ref:match("%.`?([%w_]+)`?$") or ref:match("^`?([%w_]+)`?$")
    if not name then
      return
    end
    local key = name:lower()
    if not seen[key] and not ctes[key] then
      seen[key] = true
      table.insert(tables, name)
    end
  end

  -- Walk the text once, keyword by keyword, so the original case is kept
  local upper = text:upper()
  for _, keyword in ipairs({ "FROM", "JOIN", "INTO", "UPDATE" }) do
    local init = 1
    while true do
      local s, e = upper:find("%f[%w_]" .. keyword .. "%f[^%w_]%s+", init)
      if not s then
        break
      end
      local ref = text:match("^([%w_%.`]+)", e + 1)
      if ref then
        add(ref)
      end
      init = e + 1
    end
  end

  return tables
end

--- Names introduced by `WITH name AS (...)` common table expressions
---@param text string
---@return string[]
function Parser.extract_cte_names(text)
  local names = {}
  local upper = text:upper()
  local s, e = upper:find("%f[%w_]WITH%s+")
  if not s then
    return names
  end
  -- WITH a AS (...), b AS (...) SELECT ...
  local init = e + 1
  while true do
    local name_s, name_e, name = text:find("^%s*,?%s*`?([%w_]+)`?%s+[Aa][Ss]%s*%(", init)
    if not name_s then
      break
    end
    table.insert(names, name)
    -- Skip the balanced parenthesis block
    local depth = 0
    local i = name_e
    while i <= #text do
      local c = text:sub(i, i)
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then
          break
        end
      end
      i = i + 1
    end
    init = i + 1
  end
  return names
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
  for match_start, table_ref, alias_start, alias_upper in upper_text:gmatch("()FROM%s+([%w_%.]+)%s+AS%s+()([%w_]+)") do
    local table_name, database = parse_table_reference(table_ref)
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
  for match_start, table_ref, alias_start, alias_upper in upper_text:gmatch("()JOIN%s+([%w_%.]+)%s+AS%s+()([%w_]+)") do
    local table_name, database = parse_table_reference(table_ref)
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

--- Identifier under a column of a line: `name` or `qualifier.name`
---@param line string
---@param col number 0-based byte column
---@return { name: string, qualifier: string|nil, start_col: number, end_col: number }|nil
function Parser.identifier_at(line, col)
  local pos = col + 1
  if not line:sub(pos, pos):match("[%w_%.`]") then
    return nil
  end
  local s = pos
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_%.`]") do
    s = s - 1
  end
  local e = pos
  while e <= #line and line:sub(e, e):match("[%w_%.`]") do
    e = e + 1
  end
  local word = line:sub(s, e - 1):gsub("`", "")
  if word == "" then
    return nil
  end
  local qualifier, name = word:match("^([%w_]+)%.([%w_]+)$")
  if not name then
    name = word:match("^([%w_]+)%.?$")
  end
  if not name then
    return nil
  end
  return { name = name, qualifier = qualifier, start_col = s - 1, end_col = e - 1 }
end

return Parser
