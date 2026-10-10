--- SQL statement splitting and classification.
---
--- The scanner understands single/double-quoted strings, backtick identifiers,
--- `--`/`#` line comments and `/* */` block comments, so a `;` inside any of
--- those never terminates a statement and several statements may share one
--- line. When a tree-sitter `sql` parser is installed and parses the buffer
--- without errors, statement ranges are taken from it instead.
---@class abcql.db.Statements
local M = {}

---@class abcql.Statement
---@field text string Statement text without the trailing semicolon
---@field start_line number 1-indexed first line of the statement
---@field start_col number 0-based byte column where the statement starts on start_line
---@field end_line number 1-indexed last line of the statement

--- Keywords that start a statement that only reads data. Everything else is
--- treated as a mutation for confirmation/readonly purposes.
local READ_KEYWORDS = {
  SELECT = true,
  SHOW = true,
  DESCRIBE = true,
  DESC = true,
  EXPLAIN = true,
  WITH = true,
  USE = true,
  HELP = true,
  VALUES = true,
  TABLE = true,
  CHECKSUM = true,
  ANALYZE = true,
}

--- Strip leading whitespace and comments from a statement.
--- @param sql string
--- @return string
function M.strip_leading_comments(sql)
  local s = sql
  while true do
    local before = s
    s = s:gsub("^%s+", "")
    s = s:gsub("^%-%-[^\n]*\n?", "")
    s = s:gsub("^#[^\n]*\n?", "")
    s = s:gsub("^/%*.-%*/", "")
    if s == before then
      return s
    end
  end
end

--- First keyword of a statement, uppercased (leading comments ignored).
--- @param sql string
--- @return string|nil
function M.first_keyword(sql)
  local word = M.strip_leading_comments(sql):match("^%(*%s*([%a_]+)")
  return word and word:upper() or nil
end

--- Whether a statement may modify data or schema (anything that is not a
--- plain read such as SELECT/SHOW/DESCRIBE/EXPLAIN).
--- @param sql string
--- @return boolean
function M.is_write(sql)
  local keyword = M.first_keyword(sql)
  if not keyword then
    return false
  end
  return not READ_KEYWORDS[keyword]
end

--- First keywords that make MySQL commit the open transaction before they run (DDL, account
--- statements, BEGIN/START TRANSACTION, LOCK/UNLOCK TABLES).
local IMPLICIT_COMMIT = {}
for _, keyword in ipairs({
  "BEGIN",
  "START",
  "CREATE",
  "ALTER",
  "DROP",
  "RENAME",
  "TRUNCATE",
  "LOCK",
  "UNLOCK",
  "GRANT",
  "REVOKE",
}) do
  IMPLICIT_COMMIT[keyword] = true
end

--- The keyword by which a statement implicitly COMMITs an open transaction: its first keyword when
--- it is one of IMPLICIT_COMMIT (but not CREATE/DROP TEMPORARY TABLE), or `SET autocommit = 1`.
--- @param sql string
--- @return string|nil keyword
function M.implicit_commit(sql)
  local keyword = M.first_keyword(sql)
  if not keyword then
    return nil
  end
  local rest = M.strip_leading_comments(sql):lower()
  if keyword == "SET" then
    local value = rest:match("^set%s+[@%w_.]*autocommit%s*=%s*(%w+)")
    return (value == "1" or value == "on" or value == "true") and "SET autocommit = 1" or nil
  end
  if (keyword == "CREATE" or keyword == "DROP") and rest:match("^%a+%s+temporary%s") then
    return nil
  end
  return IMPLICIT_COMMIT[keyword] and keyword or nil
end

--- Whether a statement contains only whitespace and comments.
--- @param sql string
--- @return boolean
function M.is_blank(sql)
  return M.strip_leading_comments(sql):match("^%s*$") ~= nil
end

--- If a quoted string, backtick identifier or comment starts at position i,
--- return the position just after it (a `--`/`#` comment ends before its
--- newline; an unterminated one runs to the end of the text). Returns nil
--- when position i starts ordinary SQL.
--- @param text string
--- @param i number
--- @return number|nil
function M.skip_literal(text, i)
  local len = #text
  local c = text:sub(i, i)
  local two = text:sub(i, i + 1)
  if c == "'" or c == '"' or c == "`" then
    -- Skip to the matching close, honouring backslash escapes and doubled
    -- quotes.
    local quote = c
    i = i + 1
    while i <= len do
      local ch = text:sub(i, i)
      if ch == "\\" and quote ~= "`" then
        i = i + 2
      elseif ch == quote then
        if text:sub(i + 1, i + 1) ~= quote then
          return i + 1
        end
        i = i + 2
      else
        i = i + 1
      end
    end
    return len + 1
  elseif two == "--" or c == "#" then
    return text:find("\n", i, true) or (len + 1)
  elseif two == "/*" then
    local close = text:find("*/", i + 2, true)
    return close and (close + 2) or (len + 1)
  end
  return nil
end

--- Split raw SQL text into statements using a character scanner.
--- @param text string
--- @return abcql.Statement[]
function M.scan(text)
  local statements = {}
  local len = #text
  local i = 1
  local line = 1
  local stmt_start = 1
  local stmt_start_line = 1

  local function push(stop, stop_line)
    local raw = text:sub(stmt_start, stop)
    -- Drop leading whitespace/comments so text starts at real SQL and
    -- start_line points at it.
    local stripped = M.strip_leading_comments(raw)
    if stripped:match("^%s*$") then
      return
    end
    local consumed = raw:sub(1, #raw - #stripped)
    local first_line = stmt_start_line
    for _ in consumed:gmatch("\n") do
      first_line = first_line + 1
    end
    local start = stmt_start + #consumed
    local line_start = start
    while line_start > 1 and text:sub(line_start - 1, line_start - 1) ~= "\n" do
      line_start = line_start - 1
    end
    stripped = stripped:gsub("%s+$", "")
    table.insert(statements, {
      text = stripped,
      start_line = first_line,
      start_col = start - line_start,
      end_line = stop_line,
    })
  end

  while i <= len do
    local c = text:sub(i, i)
    local stop = M.skip_literal(text, i)

    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif stop then
      -- A line comment ends before its newline, which is counted above.
      for _ in text:sub(i, stop - 1):gmatch("\n") do
        line = line + 1
      end
      i = stop
    elseif c == ";" then
      push(i - 1, line)
      i = i + 1
      stmt_start = i
      stmt_start_line = line
    else
      i = i + 1
    end
  end

  if stmt_start <= len then
    push(len, line)
  end

  return statements
end

--- Try to split the buffer with tree-sitter. Returns nil when no `sql`
--- parser is available or the parse tree contains errors.
--- @param bufnr number
--- @return abcql.Statement[]|nil
local function split_with_treesitter(bufnr)
  if not (vim.treesitter and vim.treesitter.language and vim.treesitter.language.add) then
    return nil
  end

  local has_parser = pcall(vim.treesitter.language.add, "sql")
  if not has_parser then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "sql", { error = false })
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root or root:has_error() then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local statements = {}
  for node in root:iter_children() do
    if node:type() == "statement" then
      local sr, sc, er, ec = node:range()
      local chunk = {}
      for l = sr + 1, er + 1 do
        table.insert(chunk, lines[l] or "")
      end
      if ec == 0 and #chunk > 1 then
        table.remove(chunk)
        er = er - 1
      else
        chunk[#chunk] = chunk[#chunk]:sub(1, ec)
      end
      -- Several statements may share a line: keep only this node's columns.
      chunk[1] = chunk[1]:sub(sc + 1)
      local text = table.concat(chunk, "\n"):gsub(";%s*$", ""):gsub("%s+$", "")
      if not M.is_blank(text) then
        table.insert(statements, { text = text, start_line = sr + 1, start_col = sc, end_line = er + 1 })
      end
    end
  end

  if #statements == 0 then
    return nil
  end
  return statements
end

--- Split a buffer into statements (tree-sitter when available, scanner otherwise).
--- @param bufnr number|nil
--- @return abcql.Statement[]
function M.split_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local statements = split_with_treesitter(bufnr)
  if statements then
    return statements
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  return M.scan(text)
end

--- Find the statement under (or, on a blank line, after) the given line.
--- @param statements abcql.Statement[]
--- @param line number 1-indexed cursor line
--- @return abcql.Statement|nil
function M.at_line(statements, line)
  local following = nil
  for _, stmt in ipairs(statements) do
    if line >= stmt.start_line and line <= stmt.end_line then
      return stmt
    end
    if stmt.start_line > line and not following then
      following = stmt
    end
  end
  return following
end

---@class abcql.StatementToken
---@field kind "word"|"quoted"|"punct"
---@field value string Uppercased for words, raw otherwise
---@field raw string
---@field pos number 1-indexed byte offset in the statement

--- Tokens outside any parentheses (so subqueries and CTE bodies are skipped;
--- an opening `(` is kept as a token). Comments are dropped.
--- @param sql string
--- @return abcql.StatementToken[]
local function top_level_tokens(sql)
  local tokens = {}
  local depth = 0
  local i = 1
  while i <= #sql do
    local c = sql:sub(i, i)
    local after = M.skip_literal(sql, i)
    if after then
      if depth == 0 and c:match("['\"`]") then
        local raw = sql:sub(i, after - 1)
        table.insert(tokens, { kind = "quoted", value = raw, raw = raw, pos = i })
      end
      i = after
    elseif c:match("[%w_$]") then
      local word = sql:match("^[%w_$]+", i)
      if depth == 0 then
        table.insert(tokens, { kind = "word", value = word:upper(), raw = word, pos = i })
      end
      i = i + #word
    else
      if depth == 0 and not c:match("%s") then
        table.insert(tokens, { kind = "punct", value = c, raw = c, pos = i })
      end
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = math.max(depth - 1, 0)
      end
      i = i + 1
    end
  end
  return tokens
end

--- Possibly qualified table name starting at token `j` (e.g. db.`orders`).
--- @param tokens abcql.StatementToken[]
--- @param j number
--- @return string|nil
local function table_name_at(tokens, j)
  local function is_name(t)
    return t and t.kind ~= "punct"
  end
  if not is_name(tokens[j]) then
    return nil
  end
  local name = tokens[j].raw
  while tokens[j + 1] and tokens[j + 1].value == "." and is_name(tokens[j + 2]) do
    name = name .. "." .. tokens[j + 2].raw
    j = j + 2
  end
  return name
end

--- Keywords that start the main statement after a WITH clause
local DML_KEYWORDS =
  { SELECT = true, INSERT = true, REPLACE = true, UPDATE = true, DELETE = true, TABLE = true, VALUES = true }

--- Clauses that may follow the WHERE condition of an UPDATE/DELETE
local AFTER_WHERE = { ORDER = true, LIMIT = true, RETURNING = true }

--- WHERE conditions that are trivially true (tokens concatenated, uppercased)
local TRIVIAL_WHERE = { ["1"] = true, ["1=1"] = true, ["TRUE"] = true }

--- Join types that do not restrict the rows of the left-hand table
local NON_RESTRICTING_JOINS = { LEFT = true, RIGHT = true, OUTER = true, CROSS = true, NATURAL = true }

--- Whether the tokens from `from` up to (not including) `stop` contain an
--- inner join (JOIN, INNER JOIN, STRAIGHT_JOIN) with an ON/USING condition.
--- @param tokens abcql.StatementToken[]
--- @param from number
--- @param stop number
--- @return boolean
local function has_inner_join(tokens, from, stop)
  for k = from, stop - 1 do
    local t = tokens[k]
    if t.value == "JOIN" or t.value == "STRAIGHT_JOIN" then
      local prev = tokens[k - 1]
      if not (prev and NON_RESTRICTING_JOINS[prev.value]) then
        for m = k + 1, stop - 1 do
          local v = tokens[m].value
          if v == "ON" or v == "USING" then
            return true
          elseif v == "JOIN" or v == "STRAIGHT_JOIN" then
            break
          end
        end
      end
    end
  end
  return false
end

---@class abcql.DangerousStatement
---@field keyword "UPDATE"|"DELETE"|"TRUNCATE"
---@field table string|nil Target table, when it could be determined
---@field pos number 1-indexed byte offset of the keyword in the statement
---@field message string Human-readable explanation

--- Detect a statement that affects every row of a table: UPDATE/DELETE with
--- no top-level WHERE (or a literal `WHERE 1`, `WHERE 1=1`, `WHERE TRUE`),
--- and TRUNCATE. WHEREs inside subqueries, CTE bodies, strings or comments do
--- not count. Returns nil when unsure.
--- @param sql string A single statement
--- @return abcql.DangerousStatement|nil
function M.dangerous(sql)
  local tokens = top_level_tokens(sql)
  local first = tokens[1]
  if not first or first.kind ~= "word" then
    return nil
  end

  local function result(keyword, tbl, pos, what, rows)
    return {
      keyword = keyword,
      table = tbl,
      pos = pos,
      message = string.format("%s %s%s", what, rows or "every row", tbl and (" in " .. tbl) or ""),
    }
  end

  if first.value == "TRUNCATE" then
    local j = (tokens[2] and tokens[2].value == "TABLE") and 3 or 2
    return result("TRUNCATE", table_name_at(tokens, j), first.pos, "TRUNCATE removes")
  end

  local i = 1
  if first.value == "WITH" then
    while tokens[i] and not (tokens[i].kind == "word" and DML_KEYWORDS[tokens[i].value]) do
      i = i + 1
    end
  end
  local keyword = tokens[i] and tokens[i].value
  if keyword ~= "UPDATE" and keyword ~= "DELETE" then
    return nil
  end

  local tbl, where, set, limit, ordered = nil, nil, nil, nil, false
  for k = i + 1, #tokens do
    local t = tokens[k]
    if t.kind == "word" then
      if t.value == "WHERE" and not where then
        where = k
      elseif t.value == "SET" and not set then
        set = k
      elseif t.value == "ORDER" then
        ordered = true
      elseif t.value == "LIMIT" then
        limit = k
      elseif keyword == "DELETE" and t.value == "FROM" and not tbl then
        tbl = table_name_at(tokens, k + 1)
      end
    end
  end
  -- An inner join already restricts the rows of the target table.
  if has_inner_join(tokens, i + 1, set or where or limit or (#tokens + 1)) then
    return nil
  end
  if keyword == "UPDATE" then
    local j = i + 1
    while tokens[j] and (tokens[j].value == "LOW_PRIORITY" or tokens[j].value == "IGNORE") do
      j = j + 1
    end
    if tokens[j] and tokens[j].value == "OR" then -- SQLite: UPDATE OR REPLACE t
      j = j + 2
    end
    tbl = table_name_at(tokens, j)
  end

  local rows = nil
  if limit then
    local count, after = tokens[limit + 1], tokens[limit + 2]
    if count and count.value:match("^%d+$") and not after then
      rows = string.format("up to %s%s rows", count.value, ordered and "" or " arbitrary")
    else
      rows = "arbitrary rows (LIMIT)"
    end
  end

  if not where then
    return result(keyword, tbl, tokens[i].pos, keyword .. " without WHERE affects", rows)
  end
  local cond = {}
  for k = where + 1, #tokens do
    if tokens[k].kind == "word" and AFTER_WHERE[tokens[k].value] then
      break
    end
    table.insert(cond, tokens[k].value)
  end
  local condition = table.concat(cond)
  if TRIVIAL_WHERE[condition] then
    return result(keyword, tbl, tokens[i].pos, string.format("%s with WHERE %s affects", keyword, condition), rows)
  end
  return nil
end

return M
