--- Auto-LIMIT: add `LIMIT n` to a plain top-level SELECT before it is sent, so
--- the server limits the result instead of the backend's `max_rows` cap.
---
--- The rule is deliberately conservative. Only a statement starting with
--- SELECT, or WITH whose main statement is a SELECT, is considered (a UNION of
--- SELECTs counts). Words inside strings, backtick identifiers, comments and
--- parentheses (subqueries, derived tables, CTE bodies, parenthesised UNION
--- branches) are ignored. A statement with its own top-level LIMIT is left as
--- written. `SELECT ... INTO`, several statements, unbalanced parentheses or
--- anything else unusual is left alone, and `max_rows` still applies to it.
---@class abcql.db.Limit
local M = {}

local Statements = require("abcql.db.statements")

--- Tokens of a statement: words (uppercased) and `(`, `)`, `;`, `,`, with
--- their byte range and parenthesis depth. Strings, identifiers, comments,
--- numbers, variables and words qualified by a `.` are skipped. Each token
--- also records `before`, where the SQL before it ends (ignoring whitespace
--- and comments).
--- @param sql string
--- @return { word: string, start: number, stop: number, depth: number, before: number }[]|nil tokens nil when parentheses don't balance
--- @return number last_end Position of the last character that isn't whitespace or a comment
local function tokenize(sql)
  local tokens = {}
  local len = #sql
  local depth = 0
  local last_end = 0
  local i = 1
  while i <= len do
    local c = sql:sub(i, i)
    local skipped = Statements.skip_literal(sql, i)
    if skipped then
      if c == "'" or c == '"' or c == "`" then
        last_end = skipped - 1
      end
      i = skipped
    elseif c:match("%s") then
      i = i + 1
    elseif c:match("[%a_]") then
      local word = sql:match("^[%w_$]+", i)
      if sql:sub(i - 1, i - 1) ~= "." then
        table.insert(tokens, { word = word:upper(), start = i, stop = i + #word - 1, depth = depth, before = last_end })
      end
      i = i + #word
      last_end = i - 1
    elseif c == "@" or c:match("%d") then
      i = i + #sql:match("^[@%w_$.]+", i)
      last_end = i - 1
    elseif c == "(" or c == ")" or c == ";" or c == "," then
      if c == ")" then
        depth = depth - 1
        if depth < 0 then
          return nil
        end
      end
      table.insert(tokens, { word = c, start = i, stop = i, depth = depth, before = last_end })
      if c == "(" then
        depth = depth + 1
      end
      last_end = i
      i = i + 1
    else
      last_end = i
      i = i + 1
    end
  end
  if depth ~= 0 then
    return nil, last_end
  end
  return tokens, last_end
end

--- Main statement keywords that may follow a WITH clause
local WITH_TARGETS = { SELECT = true, INSERT = true, UPDATE = true, DELETE = true, REPLACE = true, VALUES = true }

--- Analyse a statement's top level.
--- @param sql string
--- @return "explicit"|"plain"|"other" kind
--- @return number|nil insert_at Byte position where a LIMIT goes (for "plain")
local function analyse(sql)
  local tokens, last_end = tokenize(sql)
  if not tokens or #tokens == 0 then
    return "other"
  end

  -- Ignore one trailing `;`; anything after a top-level `;` is another statement.
  local last = #tokens
  if tokens[last].word == ";" then
    if last_end ~= tokens[last].start then
      return "other"
    end
    last_end = tokens[last].before
    last = last - 1
  end
  for n = 1, last do
    if tokens[n].word == ";" then
      return "other"
    end
  end
  if last == 0 then
    return "other"
  end

  -- `(SELECT ... LIMIT n)`: the wrapped query's own LIMIT counts, but no LIMIT
  -- is added (SQLite doesn't accept a parenthesised query).
  if tokens[1].word == "(" then
    local close = nil
    for n = 2, last do
      if tokens[n].word == ")" and tokens[n].depth == 0 then
        close = n
        break
      end
    end
    if close == last then
      local inner = analyse(sql:sub(tokens[1].stop + 1, tokens[last].start - 1))
      return inner == "explicit" and "explicit" or "other"
    end
    return "other"
  end

  local first = tokens[1].word
  if first == "WITH" then
    for n = 2, last do
      local word = tokens[n].word
      if tokens[n].depth == 0 and WITH_TARGETS[word] then
        if word ~= "SELECT" then
          return "other"
        end
        break
      end
    end
  elseif first ~= "SELECT" then
    return "other"
  end

  --- Word of the n-th token (nil past the statement)
  local function word_at(n)
    return n <= last and tokens[n].word or nil
  end

  local insert_at = last_end + 1
  local lock_at = nil
  for n = 1, last do
    local token = tokens[n]
    if token.depth == 0 then
      if token.word == "LIMIT" then
        return "explicit"
      elseif token.word == "INTO" then
        return "other"
      elseif not lock_at then
        -- FOR UPDATE / FOR SHARE, not an index hint's FOR JOIN/ORDER BY/GROUP BY;
        -- LOCK IN SHARE MODE, not a column named lock.
        local following = word_at(n + 1)
        local is_for = token.word == "FOR" and (following == "UPDATE" or following == "SHARE")
        local is_lock = token.word == "LOCK"
          and following == "IN"
          and word_at(n + 2) == "SHARE"
          and word_at(n + 3) == "MODE"
        if is_for or is_lock then
          lock_at = token.before + 1
        end
      end
    end
  end
  -- A LIMIT goes before FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE, and
  -- before any comment in front of it.
  if lock_at then
    insert_at = lock_at
  end
  return "plain", insert_at
end

--- Whether a statement has its own top-level LIMIT (only SELECT/WITH queries
--- are recognised).
--- @param sql string
--- @return boolean
function M.has_limit(sql)
  return (analyse(sql)) == "explicit"
end

--- Prepare a statement for sending.
--- @param sql string The statement as the user wrote it
--- @param limit number|false|nil LIMIT to add to a plain SELECT (0/false/nil disables)
--- @return string sql The SQL to send (unchanged unless a LIMIT was added)
--- @return "added"|"explicit"|nil status "added" when the LIMIT was appended, "explicit" when the statement has its own
function M.apply(sql, limit)
  local kind, insert_at = analyse(sql)
  if kind == "explicit" then
    return sql, "explicit"
  end
  if kind ~= "plain" or type(limit) ~= "number" or limit <= 0 then
    return sql, nil
  end
  -- Keep what follows the insert point (a semicolon, a trailing comment,
  -- FOR UPDATE ...) after the LIMIT.
  local before = sql:sub(1, insert_at - 1):gsub("%s+$", "")
  local after = sql:sub(#before + 1)
  local sep = after:match("^[^%s;]") and " " or ""
  return string.format("%s LIMIT %d%s%s", before, limit, sep, after), "added"
end

--- The auto-LIMIT for a datasource: its `auto_limit` flag, else
--- `query.auto_limit`, else `query.max_rows`, else 1000.
--- @param datasource Datasource|nil
--- @return number limit 0 when disabled
function M.for_datasource(datasource)
  local limit = datasource and datasource.auto_limit
  if limit == nil then
    local ok, config = pcall(require, "abcql.config")
    local query = ok and type(config.query) == "table" and config.query or {}
    limit = query.auto_limit
    if limit == nil then
      limit = query.max_rows
    end
    if limit == nil then
      limit = 1000
    end
  end
  if type(limit) ~= "number" or limit <= 0 then
    return 0
  end
  return math.floor(limit)
end

return M
