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

--- Whether a statement contains only whitespace and comments.
--- @param sql string
--- @return boolean
function M.is_blank(sql)
  return M.strip_leading_comments(sql):match("^%s*$") ~= nil
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
    stripped = stripped:gsub("%s+$", "")
    table.insert(statements, {
      text = stripped,
      start_line = first_line,
      end_line = stop_line,
    })
  end

  while i <= len do
    local c = text:sub(i, i)
    local two = text:sub(i, i + 1)

    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == "'" or c == '"' or c == "`" then
      -- Quoted string / identifier: skip to the matching close, honouring
      -- backslash escapes and doubled quotes.
      local quote = c
      i = i + 1
      while i <= len do
        local ch = text:sub(i, i)
        if ch == "\\" and quote ~= "`" then
          if text:sub(i + 1, i + 1) == "\n" then
            line = line + 1
          end
          i = i + 2
        elseif ch == quote then
          if text:sub(i + 1, i + 1) == quote then
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          if ch == "\n" then
            line = line + 1
          end
          i = i + 1
        end
      end
    elseif two == "--" or c == "#" then
      local nl = text:find("\n", i, true)
      i = nl or (len + 1)
    elseif two == "/*" then
      local close = text:find("*/", i + 2, true)
      local stop = close and (close + 1) or len
      for _ in text:sub(i, stop):gmatch("\n") do
        line = line + 1
      end
      i = stop + 1
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
      local sr, _, er, ec = node:range()
      local chunk = {}
      for l = sr + 1, er + 1 do
        table.insert(chunk, lines[l] or "")
      end
      if ec == 0 and #chunk > 1 then
        table.remove(chunk)
        er = er - 1
      end
      local text = table.concat(chunk, "\n"):gsub(";%s*$", ""):gsub("%s+$", "")
      if not M.is_blank(text) then
        table.insert(statements, { text = text, start_line = sr + 1, end_line = er + 1 })
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

return M
