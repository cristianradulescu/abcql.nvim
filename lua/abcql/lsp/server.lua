local Parser = require("abcql.lsp.parser")
local Completion = require("abcql.lsp.completion")
local Statements = require("abcql.db.statements")

---@class abcql.lsp.Server
---@field cache abcql.lsp.Cache Cache instance
---@field datasource_name string Name of active datasource
---@field adapter abcql.db.adapter.Adapter Database adapter instance
---@field dispatchers table|nil RPC dispatchers (for server -> client notifications)
---@field diagnostic_timers table<string, uv.uv_timer_t> Debounce timers per document URI
local Server = {}
Server.__index = Server

local SymbolKind = { Function = 12, Class = 5, Field = 8 }
local DiagnosticSeverity = { Warning = 2 }
local DIAGNOSTICS_DEBOUNCE_MS = 300

--- Statement keywords after which a table is allowed not to exist yet
local DEFINING_KEYWORDS = { CREATE = true, RENAME = true }

--- Create a new LSP server instance (one per datasource)
---@param cache abcql.lsp.Cache Cache instance
---@param datasource_name string Name of datasource
---@param adapter abcql.db.adapter.Adapter Database adapter
---@return abcql.lsp.Server
function Server.new(cache, datasource_name, adapter)
  local self = setmetatable({}, Server)
  self.cache = cache
  self.datasource_name = datasource_name
  self.adapter = adapter
  self.dispatchers = nil
  self.diagnostic_timers = {}
  return self
end

--- Remember the client dispatchers so the server can push notifications
---@param dispatchers table
function Server:set_dispatchers(dispatchers)
  self.dispatchers = dispatchers
end

--- Handle LSP initialize request
---@param _ table LSP initialize params (unused)
---@return table Server capabilities
function Server:handle_initialize(_)
  return {
    capabilities = {
      textDocumentSync = 1, -- Full: needed to receive didChange for diagnostics
      completionProvider = {
        triggerCharacters = { "." },
        resolveProvider = false,
      },
      hoverProvider = true,
      documentSymbolProvider = true,
      codeActionProvider = true,
      workspaceSymbolProvider = true,
    },
  }
end

--- Resolve the buffer number of a text document
---@param params table
---@return number|nil
local function bufnr_of(params)
  local uri = params.textDocument and params.textDocument.uri
  if not uri then
    return nil
  end
  local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if not ok or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return bufnr
end

--- Statements of a buffer (honours the treesitter setting)
---@param bufnr number
---@return abcql.Statement[]
local function buffer_statements(bufnr)
  return require("abcql.db.query").get_statements(bufnr)
end

--- The statement containing the cursor, and the text of it up to the cursor.
--- Falls back to the current line when the cursor is outside any statement.
---@param bufnr number
---@param row number 0-based line
---@param col number 0-based character column
---@return { text: string, before: string, start_line: number, end_line: number, statement: abcql.Statement|nil }
function Server:statement_at(bufnr, row, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[row + 1] or ""
  local statements = buffer_statements(bufnr)
  local statement = nil
  for _, stmt in ipairs(statements) do
    if row + 1 >= stmt.start_line and row + 1 <= stmt.end_line then
      statement = stmt
      break
    end
  end

  if not statement then
    return { text = line, before = line:sub(1, col), start_line = row + 1, end_line = row + 1, statement = nil }
  end

  local before_lines = {}
  for l = statement.start_line, row do
    table.insert(before_lines, lines[l] or "")
  end
  table.insert(before_lines, line:sub(1, col))

  return {
    text = statement.text,
    before = table.concat(before_lines, "\n"),
    start_line = statement.start_line,
    end_line = statement.end_line,
    statement = statement,
  }
end

--- Tables referenced by a statement that exist in the cache
---@param text string
---@return { database: string, name: string }[]
function Server:known_tables(text)
  local found = {}
  for _, name in ipairs(Parser.extract_table_names(text)) do
    local db, real = self.cache:find_table(self.datasource_name, name)
    if db then
      table.insert(found, { database = db, name = real })
    end
  end
  return found
end

--- Handle textDocument/completion request
---@param params table LSP completion params
---@return table[] Array of completion items
function Server:handle_completion(params)
  local bufnr = bufnr_of(params)
  if not bufnr or not self.cache:has_cache(self.datasource_name) then
    return {}
  end

  local ctx = self:statement_at(bufnr, params.position.line, params.position.character)
  local context = Parser.parse_context(ctx.before, #ctx.before + 1, ctx.text)
  local partial = context.partial
  local ds = self.datasource_name
  local cache = self.cache
  local items = {}

  if context.type == "DATABASE" then
    vim.list_extend(items, Completion.create_database_items(cache:get_databases(ds) or {}, partial))
  elseif context.type == "TABLE" then
    local all_tables = cache:get_all_tables(ds) or {}
    if context.database then
      local tables = nil
      for name, list in pairs(all_tables) do
        if name:lower() == context.database:lower() then
          tables = list
        end
      end
      vim.list_extend(items, Completion.create_table_items(tables or {}, partial, context.database))
    else
      vim.list_extend(items, Completion.create_all_table_items(all_tables, partial))
      if context.clause == "INSERT INTO" or context.clause == "INTO" then
        vim.list_extend(items, Completion.create_insert_snippet_items(cache, ds, all_tables, partial))
      end
    end
  elseif context.type == "COLUMN" then
    if context.table then
      local db, real = cache:find_table(ds, context.table, context.database)
      local columns = db and cache:get_columns(ds, db, real) or nil
      if columns then
        vim.list_extend(
          items,
          Completion.create_column_items(columns, partial, real, context.resolved_from_alias, Completion.RANK.PRIMARY)
        )
      end
    else
      local table_names = Parser.extract_table_names(ctx.text)
      local from_statement =
        Completion.create_columns_from_tables(cache, ds, table_names, nil, partial, Completion.RANK.PRIMARY)
      if #from_statement > 0 then
        vim.list_extend(items, from_statement)
      else
        -- No resolvable tables in the statement: offer every column, ranked lower
        for db, tables in pairs(cache:get_all_tables(ds) or {}) do
          for _, tbl in ipairs(tables) do
            local columns = cache:get_columns(ds, db, tbl)
            if columns then
              vim.list_extend(
                items,
                Completion.create_column_items(columns, partial, tbl, nil, Completion.RANK.SECONDARY)
              )
            end
          end
        end
      end
    end
  end

  -- Keywords are always available, ranked after schema items
  vim.list_extend(items, Completion.create_keyword_items(partial))

  return items
end

--- Markdown for a table hover
---@param database string
---@param table_name string
---@return string
function Server:table_markdown(database, table_name)
  local columns = self.cache:get_columns(self.datasource_name, database, table_name) or {}
  local constraints = self.cache:get_constraints(self.datasource_name, database, table_name)
  local pk = {}
  local fks = {}
  if constraints then
    for _, col in ipairs(constraints.primary_key or {}) do
      pk[col] = true
    end
    for _, fk in ipairs(constraints.foreign_keys or {}) do
      fks[fk.column] = fk
    end
  end

  local lines = { string.format("**%s.%s** (table, %d columns)", database, table_name, #columns), "" }
  table.insert(lines, "| column | type | |")
  table.insert(lines, "|---|---|---|")
  for _, col in ipairs(columns) do
    local marks = {}
    if pk[col.name] then
      table.insert(marks, "PK")
    end
    if fks[col.name] then
      table.insert(marks, "FK → " .. fks[col.name].ref_table .. "." .. fks[col.name].ref_column)
    end
    table.insert(lines, string.format("| `%s` | %s | %s |", col.name, col.type, table.concat(marks, ", ")))
  end
  return table.concat(lines, "\n")
end

--- Markdown for a column hover
---@param database string
---@param table_name string
---@param column ColumnInfo
---@return string
function Server:column_markdown(database, table_name, column)
  local lines = { string.format("**%s.%s** `%s`", table_name, column.name, column.type) }
  local constraints = self.cache:get_constraints(self.datasource_name, database, table_name)
  if constraints then
    for _, col in ipairs(constraints.primary_key or {}) do
      if col == column.name then
        table.insert(lines, "")
        table.insert(lines, "Primary key")
      end
    end
    for _, fk in ipairs(constraints.foreign_keys or {}) do
      if fk.column == column.name then
        table.insert(lines, "")
        table.insert(lines, string.format("Foreign key → %s.%s", fk.ref_table, fk.ref_column))
      end
    end
  end
  table.insert(lines, "")
  table.insert(lines, string.format("Table: %s.%s", database, table_name))
  return table.concat(lines, "\n")
end

--- Resolve the identifier under the cursor to a table or a column
---@param bufnr number
---@param row number 0-based
---@param col number 0-based
---@return { kind: "table"|"column", database: string, table: string, column: ColumnInfo|nil, ident: table }|nil
function Server:resolve_at(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local ident = Parser.identifier_at(line, col)
  if not ident then
    return nil
  end
  local ctx = self:statement_at(bufnr, row, col)
  local ds = self.datasource_name

  local function column_in(db, tbl, name)
    for _, c in ipairs(self.cache:get_columns(ds, db, tbl) or {}) do
      if c.name:lower() == name:lower() then
        return c
      end
    end
    return nil
  end

  if ident.qualifier then
    -- alias.column / table.column / database.table
    local table_name, database = Parser.resolve_alias(ident.qualifier, ctx.text)
    local db, real = self.cache:find_table(ds, table_name or ident.qualifier, database)
    if db then
      local column = column_in(db, real, ident.name)
      if column then
        return { kind = "column", database = db, table = real, column = column, ident = ident }
      end
    end
    db, real = self.cache:find_table(ds, ident.name, ident.qualifier)
    if db then
      return { kind = "table", database = db, table = real, ident = ident }
    end
    return nil
  end

  local db, real = self.cache:find_table(ds, ident.name)
  if db then
    return { kind = "table", database = db, table = real, ident = ident }
  end
  for _, tbl in ipairs(self:known_tables(ctx.text)) do
    local column = column_in(tbl.database, tbl.name, ident.name)
    if column then
      return { kind = "column", database = tbl.database, table = tbl.name, column = column, ident = ident }
    end
  end
  return nil
end

--- Handle textDocument/hover
---@param params table
---@return table|nil
function Server:handle_hover(params)
  local bufnr = bufnr_of(params)
  if not bufnr or not self.cache:has_cache(self.datasource_name) then
    return nil
  end
  local resolved = self:resolve_at(bufnr, params.position.line, params.position.character)
  if not resolved then
    return nil
  end
  local value
  if resolved.kind == "table" then
    value = self:table_markdown(resolved.database, resolved.table)
  else
    value = self:column_markdown(resolved.database, resolved.table, resolved.column)
  end
  return {
    contents = { kind = "markdown", value = value },
    range = {
      start = { line = params.position.line, character = resolved.ident.start_col },
      ["end"] = { line = params.position.line, character = resolved.ident.end_col },
    },
  }
end

--- Short label for a statement: first keyword plus first table, or its first words
---@param stmt abcql.Statement
---@return string
local function statement_label(stmt)
  local keyword = Statements.first_keyword(stmt.text) or "SQL"
  local tables = Parser.extract_table_names(stmt.text)
  if #tables > 0 then
    return keyword .. " " .. table.concat(tables, ", ")
  end
  local flat = Statements.strip_leading_comments(stmt.text):gsub("%s+", " ")
  if #flat > 40 then
    flat = flat:sub(1, 37) .. "..."
  end
  return flat
end

--- Handle textDocument/documentSymbol: one symbol per statement
---@param params table
---@return table[]
function Server:handle_document_symbol(params)
  local bufnr = bufnr_of(params)
  if not bufnr then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local symbols = {}
  for _, stmt in ipairs(buffer_statements(bufnr)) do
    local range = {
      start = { line = stmt.start_line - 1, character = 0 },
      ["end"] = { line = stmt.end_line - 1, character = #(lines[stmt.end_line] or "") },
    }
    table.insert(symbols, {
      name = statement_label(stmt),
      detail = string.format("lines %d-%d", stmt.start_line, stmt.end_line),
      kind = SymbolKind.Function,
      range = range,
      selectionRange = range,
    })
  end
  return symbols
end

--- Handle workspace/symbol: tables and columns of the datasource as symbols.
--- Their location points at the current buffer, so this is a lookup tool
--- rather than a jump.
---@param params table
---@return table[]
function Server:handle_workspace_symbol(params)
  if not self.cache:has_cache(self.datasource_name) then
    return {}
  end
  local query = (params.query or ""):lower()
  local uri = vim.uri_from_bufnr(vim.api.nvim_get_current_buf())
  local location = {
    uri = uri,
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
  }
  local symbols = {}
  for db, tables in pairs(self.cache:get_all_tables(self.datasource_name) or {}) do
    for _, tbl in ipairs(tables) do
      if query == "" or tbl:lower():find(query, 1, true) then
        table.insert(symbols, { name = tbl, kind = SymbolKind.Class, containerName = db, location = location })
      end
      for _, col in ipairs(self.cache:get_columns(self.datasource_name, db, tbl) or {}) do
        if query ~= "" and col.name:lower():find(query, 1, true) then
          table.insert(symbols, {
            name = col.name,
            kind = SymbolKind.Field,
            containerName = db .. "." .. tbl,
            location = location,
          })
        end
      end
    end
  end
  table.sort(symbols, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return a.name < b.name
  end)
  return symbols
end

--- Position of the first `*` in a `SELECT *` of a statement
---@param lines string[] Buffer lines
---@param stmt abcql.Statement
---@return number|nil line 0-based
---@return number|nil col 0-based
local function find_select_star(lines, stmt)
  for l = stmt.start_line, stmt.end_line do
    local text = lines[l] or ""
    local s = text:find("%f[%w_][Ss][Ee][Ll][Ee][Cc][Tt]%s+%*")
    if s then
      local star = text:find("*", s, true)
      return l - 1, star - 1
    end
  end
  return nil, nil
end

--- Handle textDocument/codeAction for the statement under the range start
---@param params table
---@return table[]
function Server:handle_code_action(params)
  local bufnr = bufnr_of(params)
  if not bufnr then
    return {}
  end
  local uri = params.textDocument.uri
  local row = params.range.start.line
  local col = params.range.start.character
  local ctx = self:statement_at(bufnr, row, col)
  local actions = {}

  if ctx.statement then
    table.insert(actions, {
      title = "abcql: run this statement",
      kind = "source",
      command = {
        title = "Run statement",
        command = "abcql.run",
        arguments = { { uri = uri, line = ctx.start_line } },
      },
    })
  end

  local resolved = self.cache:has_cache(self.datasource_name) and self:resolve_at(bufnr, row, col) or nil
  if resolved then
    local qualified = self.adapter:escape_identifier(resolved.database)
      .. "."
      .. self.adapter:escape_identifier(resolved.table)
    table.insert(actions, {
      title = string.format("abcql: browse %s", resolved.table),
      kind = "source",
      command = {
        title = "Browse table",
        command = "abcql.browse",
        arguments = { { sql = "SELECT * FROM " .. qualified .. " LIMIT 1000" } },
      },
    })

    local columns = self.cache:get_columns(self.datasource_name, resolved.database, resolved.table) or {}
    if #columns > 0 and ctx.statement then
      local names = {}
      for _, c in ipairs(columns) do
        table.insert(names, c.name)
      end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local template = string.format(
        "\nINSERT INTO %s (%s)\nVALUES (%s);",
        resolved.table,
        table.concat(names, ", "),
        table.concat(
          vim.tbl_map(function()
            return "?"
          end, names),
          ", "
        )
      )
      -- Insert right after the last line of the current statement
      local at = { line = ctx.end_line - 1, character = #(lines[ctx.end_line] or "") }
      table.insert(actions, {
        title = string.format("abcql: insert INSERT template for %s", resolved.table),
        kind = "refactor",
        edit = { changes = { [uri] = { { range = { start = at, ["end"] = at }, newText = template } } } },
      })
    end
  end

  if ctx.statement and self.cache:has_cache(self.datasource_name) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local star_line, star_col = find_select_star(lines, ctx.statement)
    local tables = self:known_tables(ctx.text)
    if star_line and #tables > 0 then
      local names = {}
      local qualify = #tables > 1
      for _, tbl in ipairs(tables) do
        for _, c in ipairs(self.cache:get_columns(self.datasource_name, tbl.database, tbl.name) or {}) do
          table.insert(names, qualify and (tbl.name .. "." .. c.name) or c.name)
        end
      end
      if #names > 0 then
        table.insert(actions, {
          title = "abcql: expand * to the column list",
          kind = "refactor.rewrite",
          edit = {
            changes = {
              [uri] = {
                {
                  range = {
                    start = { line = star_line, character = star_col },
                    ["end"] = { line = star_line, character = star_col + 1 },
                  },
                  newText = table.concat(names, ", "),
                },
              },
            },
          },
        })
      end
    end
  end

  return actions
end

--- Diagnostics for tables that do not exist in the cached schema
---@param bufnr number
---@return table[] LSP diagnostics
function Server:compute_diagnostics(bufnr)
  if not self.cache:has_cache(self.datasource_name) or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diagnostics = {}
  for _, stmt in ipairs(buffer_statements(bufnr)) do
    local keyword = Statements.first_keyword(stmt.text)
    if not (keyword and DEFINING_KEYWORDS[keyword]) then
      for _, name in ipairs(Parser.extract_table_names(stmt.text)) do
        local db = self.cache:find_table(self.datasource_name, name)
        if not db then
          for l = stmt.start_line, stmt.end_line do
            local text = lines[l] or ""
            local s, e = text:find("%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]")
            if s then
              table.insert(diagnostics, {
                range = {
                  start = { line = l - 1, character = s - 1 },
                  ["end"] = { line = l - 1, character = e },
                },
                severity = DiagnosticSeverity.Warning,
                source = "abcql",
                message = string.format("Unknown table '%s' in datasource '%s'", name, self.datasource_name),
              })
              break
            end
          end
        end
      end
    end
  end
  return diagnostics
end

--- Publish diagnostics for a document now
---@param uri string
function Server:publish_diagnostics(uri)
  if not self.dispatchers then
    return
  end
  local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  local diagnostics = (ok and vim.api.nvim_buf_is_valid(bufnr)) and self:compute_diagnostics(bufnr) or {}
  self.dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diagnostics })
end

--- Publish diagnostics after a short debounce
---@param uri string
function Server:schedule_diagnostics(uri)
  local timer = self.diagnostic_timers[uri]
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
    self.diagnostic_timers[uri] = timer
  end
  timer:start(DIAGNOSTICS_DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      self:publish_diagnostics(uri)
    end)
  end)
end

--- Clear diagnostics for a closed document
---@param uri string
function Server:clear_diagnostics(uri)
  local timer = self.diagnostic_timers[uri]
  if timer then
    timer:stop()
    timer:close()
    self.diagnostic_timers[uri] = nil
  end
  if self.dispatchers then
    self.dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = {} })
  end
end

--- Handle a client notification
---@param method string
---@param params table
function Server:handle_notification(method, params)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri then
    return
  end
  if method == "textDocument/didOpen" or method == "textDocument/didChange" then
    self:schedule_diagnostics(uri)
  elseif method == "textDocument/didClose" then
    self:clear_diagnostics(uri)
  end
end

--- Handle shutdown request
---@return table|nil
function Server:handle_shutdown()
  for uri, timer in pairs(self.diagnostic_timers) do
    timer:stop()
    timer:close()
    self.diagnostic_timers[uri] = nil
  end
  return nil
end

return Server
