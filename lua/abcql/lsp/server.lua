local Parser = require("abcql.lsp.parser")
local Completion = require("abcql.lsp.completion")

---@class abcql.lsp.Server
---@field cache abcql.lsp.Cache Cache instance
---@field datasource_name string Name of active datasource
---@field adapter abcql.db.adapter.Adapter Database adapter instance
---@field bufnr number Buffer number this server is attached to
local Server = {}
Server.__index = Server

--- Create a new LSP server instance
---@param cache abcql.lsp.Cache Cache instance
---@param datasource_name string Name of datasource
---@param adapter abcql.db.adapter.Adapter Database adapter
---@param bufnr number Buffer number
---@return abcql.lsp.Server
function Server.new(cache, datasource_name, adapter, bufnr)
  local self = setmetatable({}, Server)
  self.cache = cache
  self.datasource_name = datasource_name
  self.adapter = adapter
  self.bufnr = bufnr
  return self
end

--- Handle LSP initialize request
---@param _ table LSP initialize params (unused)
---@return table Server capabilities
function Server:handle_initialize(_)
  return {
    capabilities = {
      completionProvider = {
        triggerCharacters = { ".", " " },
        resolveProvider = false,
      },
    },
  }
end

--- Get full query context up to current position
---@param bufnr number Buffer number
---@param line_idx number Current line index (0-based)
---@return string Full query text
function Server:get_query_context(bufnr, line_idx)
  -- Get all lines from buffer start to current line
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line_idx + 1, false)
  return table.concat(lines, "\n")
end

--- Handle textDocument/completion request
---@param params table LSP completion params
---@return table[] Array of completion items
function Server:handle_completion(params)
  -- Use the stored buffer number instead of resolving from URI
  -- This works better with unnamed buffers
  local bufnr = self.bufnr
  local line_idx = params.position.line
  local col_idx = params.position.character

  -- Get the current line
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)
  if #lines == 0 then
    return {}
  end

  local line = lines[1]
  local cursor_col = col_idx + 1 -- Convert to 1-based

  -- Get full query context for alias resolution
  local full_query = self:get_query_context(bufnr, line_idx)

  -- Parse context with full query for alias support
  local context = Parser.parse_context(line, cursor_col, full_query)

  -- Check if cache is loaded
  if not self.cache:has_cache(self.datasource_name) then
    return {}
  end

  -- Generate completions based on context
  if context.type == "DATABASE" then
    local databases = self.cache:get_databases(self.datasource_name)
    if databases then
      return Completion.create_database_items(databases, context.partial)
    end
  elseif context.type == "TABLE" then
    if context.database then
      -- Specific database: show tables from that database
      local tables = self.cache:get_tables(self.datasource_name, context.database)
      if tables then
        return Completion.create_table_items(tables, context.partial, context.database)
      end
    else
      -- No database specified: show tables from all databases
      local all_tables = self.cache:get_all_tables(self.datasource_name)
      if all_tables then
        return Completion.create_all_table_items(all_tables, context.partial)
      end
    end
  elseif context.type == "COLUMN" then
    if context.table then
      -- Specific table: show columns from that table
      -- Try to find the table in any database
      local all_tables = self.cache:get_all_tables(self.datasource_name)
      if all_tables then
        for db, tables in pairs(all_tables) do
          for _, tbl in ipairs(tables) do
            if tbl == context.table then
              local columns = self.cache:get_columns(self.datasource_name, db, context.table)
              if columns then
                -- Pass alias info if this was resolved from an alias
                return Completion.create_column_items(
                  columns,
                  context.partial,
                  context.table,
                  context.resolved_from_alias
                )
              end
            end
          end
        end
      end
    else
      -- No table specified: extract tables from query and show their columns
      -- Use the already-fetched full_query instead of re-fetching
      local table_names = Parser.extract_table_names(full_query)

      if #table_names > 0 then
        return Completion.create_columns_from_tables(
          self.cache,
          self.datasource_name,
          table_names,
          nil,
          context.partial
        )
      end

      -- If no tables found, show all columns from all tables (fallback)
      local items = {}
      local all_tables = self.cache:get_all_tables(self.datasource_name)
      if all_tables then
        for db, tables in pairs(all_tables) do
          for _, tbl in ipairs(tables) do
            local columns = self.cache:get_columns(self.datasource_name, db, tbl)
            if columns then
              local col_items = Completion.create_column_items(columns, context.partial, tbl)
              vim.list_extend(items, col_items)
            end
          end
        end
      end
      return items
    end
  elseif context.type == "KEYWORD" then
    return Completion.create_keyword_items(context.partial)
  end

  return {}
end

--- Handle shutdown request
---@return table|nil
function Server:handle_shutdown()
  return nil
end

return Server
