---@class TreeNode
---@field type "title"|"datasource"|"database"|"table"|"column"|"constraints_folder"|"constraint"|"indexes_folder"|"index"
---@field name string Display name of the node
---@field level number Indentation level (0 for datasource, 1 for database, etc.)
---@field expanded boolean Whether the node is currently expanded
---@field children TreeNode[]|nil Child nodes (nil until first expansion)
---@field metadata table Additional context (datasource, database_name, table_name, column_type, constraint_type, etc.)

---@class abcql.ui.Tree
local Tree = {}

local state = {
  root = nil,
  line_to_node = {},
  --- @type fun(results: any, title: string?, opts: table?)|nil Display callback set by UI module
  display_fn = nil,
}

local NS = vim.api.nvim_create_namespace("abcql_tree")

--- Set the display callback used by browse_table_data
--- This breaks the circular dependency between tree and UI modules
--- @param fn fun(results: any, title: string?, opts: table?)
function Tree.set_display_fn(fn)
  state.display_fn = fn
end

--- Drop the cached tree so the next render rebuilds it from the registry
function Tree.reset()
  state.root = nil
  state.line_to_node = {}
end

local NERD_ICONS = {
  expanded = "󰅀",
  collapsed = "󰅂",
  leaf = "•",
  datasource = "󰒍",
  database = "󰆼",
  table = "󰓫",
  column = "󰠵",
  constraints = "󰌆",
  primary_key = "󰌆",
  foreign_key = "󰿡",
  indexes = "󰗅",
  index = "󰗅",
}

local ASCII_ICONS = {
  expanded = "v",
  collapsed = ">",
  leaf = "-",
  datasource = "@",
  database = "#",
  table = "=",
  column = "-",
  constraints = "!",
  primary_key = "PK",
  foreign_key = "FK",
  indexes = "*",
  index = "*",
}

--- Icon set according to `ui.icons`
--- @return table<string, string>
local function icons()
  local ok, config = pcall(require, "abcql.config")
  if ok and type(config.ui) == "table" and config.ui.icons == false then
    return ASCII_ICONS
  end
  return NERD_ICONS
end

--- Create a new tree node
--- @param type "title"|"datasource"|"database"|"table"|"column"|"constraints_folder"|"constraint"|"indexes_folder"|"index" Node type
--- @param name string Display name
--- @param level number Indentation level (0 = datasource, 1 = database, 2 = table, 3 = column)
--- @param metadata table Additional node context
--- @return TreeNode
local function create_node(type, name, level, metadata)
  return {
    type = type,
    name = name,
    level = level,
    expanded = false,
    children = nil,
    metadata = metadata or {},
  }
end

--- Build the initial tree structure from the connection registry
--- Creates a root node with all registered datasources as children
--- @param registry abcql.db.connection.Registry Connection registry containing datasources
--- @return TreeNode Root node of the tree
function Tree.build_from_registry(registry)
  local root = create_node("title", "[ Data sources ]", -1, {})
  root.children = {}
  root.expanded = true

  local datasources = registry:get_all_datasources()
  for name, datasource in pairs(datasources) do
    local ds_node = create_node("datasource", name, 0, {
      datasource_name = name,
      datasource = datasource,
    })
    table.insert(root.children, ds_node)
  end

  table.sort(root.children, function(a, b)
    return a.name < b.name
  end)

  state.root = root
  return root
end

--- Calculate indentation string for a given tree level
--- @param level number Tree level (-1 for root, 0+ for children)
--- @return string Indentation string (2 spaces per level)
local function get_indent(level)
  if level < 0 then
    return ""
  end
  return string.rep("  ", level)
end

--- Format a tree node into a display line with icon and indentation
--- @param node TreeNode Node to format
--- @param active_datasource string|nil Name of the datasource attached to the editor buffer
--- @return string line Formatted display line
--- @return { group: string, col_start: number, col_end: number }[] highlights Byte ranges to highlight
local function format_node_line(node, active_datasource)
  local ICONS = icons()
  local indent = get_indent(node.level)
  local icon

  if node.type == "column" then
    icon = ICONS.column
  elseif node.type == "constraint" then
    if node.metadata.constraint_type == "primary_key" then
      icon = ICONS.primary_key
    else
      icon = ICONS.foreign_key
    end
  elseif node.type == "index" then
    icon = ICONS.index
  elseif node.expanded then
    icon = ICONS.expanded
  else
    icon = ICONS.collapsed
  end

  if node.type == "datasource" then
    icon = icon .. " " .. ICONS.datasource
  elseif node.type == "database" then
    icon = icon .. " " .. ICONS.database
  elseif node.type == "table" then
    icon = icon .. " " .. ICONS.table
  elseif node.type == "constraints_folder" then
    icon = icon .. " " .. ICONS.constraints
  elseif node.type == "indexes_folder" then
    icon = icon .. " " .. ICONS.indexes
  end

  local display_name = node.name
  local type_suffix = nil
  if node.type == "column" and node.metadata.column_type then
    type_suffix = " (" .. node.metadata.column_type .. ")"
  end

  if node.level < 0 then
    return display_name, { { group = "AbcqlTreeTitle", col_start = 0, col_end = #display_name } }
  end

  local highlights = {}
  local prefix = indent .. icon .. " "
  table.insert(highlights, { group = "AbcqlTreeIcon", col_start = #indent, col_end = #indent + #icon })
  if node.type == "datasource" and active_datasource == node.name then
    display_name = display_name .. " (active)"
    table.insert(highlights, { group = "AbcqlTreeActive", col_start = #prefix, col_end = #prefix + #display_name })
  end
  local line = prefix .. display_name
  if type_suffix then
    table.insert(highlights, { group = "AbcqlTreeType", col_start = #line, col_end = #line + #type_suffix })
    line = line .. type_suffix
  end

  return line, highlights
end

--- Render the tree into display lines and build line-to-node mapping
--- Only expanded nodes and their visible children are included in the output
--- @param root TreeNode Root node to render
--- @param opts? { active_datasource: string? }
--- @return string[] lines Array of formatted display lines
--- @return table[] highlights Array of { line (0-indexed), group, col_start, col_end }
function Tree.render(root, opts)
  opts = opts or {}
  state.line_to_node = {}
  local lines = {}
  local highlights = {}
  local line_num = 1

  local function render_node(node)
    if not node then
      return
    end

    local line, line_highlights = format_node_line(node, opts.active_datasource)
    table.insert(lines, line)
    for _, hl in ipairs(line_highlights) do
      hl.line = line_num - 1
      table.insert(highlights, hl)
    end
    state.line_to_node[line_num] = node
    line_num = line_num + 1

    if node.expanded and node.children then
      for _, child in ipairs(node.children) do
        render_node(child)
      end
    end
  end

  render_node(root)
  table.insert(lines, "")

  return lines, highlights
end

--- Apply highlights produced by Tree.render to the tree buffer
--- @param buf number
--- @param highlights table[]
function Tree.apply_highlights(buf, highlights)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, hl in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, hl.line, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.group,
    })
  end
end

--- Get the tree node at a specific buffer line number
--- @param line_num number Buffer line number (1-indexed)
--- @return TreeNode|nil Node at the line, or nil if no node exists
function Tree.get_node_at_line(line_num)
  return state.line_to_node[line_num]
end

--- Get the buffer line of a node from the last render
--- @param node TreeNode
--- @return number|nil line 1-indexed line number
function Tree.get_line_of_node(node)
  for line, n in pairs(state.line_to_node) do
    if n == node then
      return line
    end
  end
  return nil
end

--- Fully qualified, escaped name for a database/table/column node
--- @param node TreeNode
--- @return string|nil
function Tree.qualified_name(node)
  local datasource = node.metadata.datasource
  local adapter = datasource and datasource.adapter
  local function esc(name)
    if adapter and adapter.escape_identifier then
      return adapter:escape_identifier(name)
    end
    return name
  end

  if node.type == "database" then
    return esc(node.metadata.database_name)
  elseif node.type == "table" then
    return esc(node.metadata.database_name) .. "." .. esc(node.metadata.table_name)
  elseif node.type == "column" then
    return esc(node.metadata.table_name) .. "." .. esc(node.name)
  end
  return nil
end

--- Reload a node's children from the database (drops the cached subtree)
--- @param node TreeNode
--- @param callback function|nil Called after the reload completes
function Tree.reload_node(node, callback)
  if node.type == "title" then
    Tree.reset()
    if callback then
      callback()
    end
    return
  end
  if node.type == "column" or node.type == "constraint" or node.type == "index" then
    return
  end
  node.children = nil
  node.expanded = false
  Tree.toggle_node(node, callback)
end

--- Expand a datasource node (loading it if needed) and the database its DSN
--- points at, so the tree opens on what the editor is connected to.
--- @param datasource_name string
--- @param callback function|nil Called after each expansion step
function Tree.expand_datasource(datasource_name, callback)
  local root = state.root
  if not root or not root.children then
    return
  end
  for _, ds_node in ipairs(root.children) do
    if ds_node.type == "datasource" and ds_node.name == datasource_name then
      local function expand_database()
        if callback then
          callback()
        end
        local datasource = ds_node.metadata.datasource
        local db_name = datasource and datasource.adapter and datasource.adapter.config.database
        if not db_name or not ds_node.children then
          return
        end
        for _, db_node in ipairs(ds_node.children) do
          if db_node.name == db_name and not db_node.expanded then
            Tree.toggle_node(db_node, callback)
            return
          end
        end
      end
      if ds_node.expanded then
        expand_database()
      else
        Tree.toggle_node(ds_node, expand_database)
      end
      return
    end
  end
end

--- Collect all loaded table nodes (depth-first)
--- @return TreeNode[]
local function loaded_tables()
  local tables = {}
  local function walk(node)
    if node.type == "table" then
      table.insert(tables, node)
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  if state.root then
    walk(state.root)
  end
  return tables
end

--- Pick a loaded table with vim.ui.select, expand its ancestors and hand it to the callback
--- @param callback fun(node: TreeNode)
function Tree.filter(callback)
  local tables = loaded_tables()
  if #tables == 0 then
    vim.notify("abcql: expand a database first to filter its tables", vim.log.levels.INFO)
    return
  end

  vim.ui.select(tables, {
    prompt = "Jump to table:",
    format_item = function(node)
      return node.metadata.datasource_name .. " / " .. node.metadata.database_name .. " / " .. node.name
    end,
  }, function(node)
    if not node then
      return
    end
    -- Make sure the node's ancestors are expanded so it can be rendered
    local function expand_path(current)
      if current == node then
        return true
      end
      for _, child in ipairs(current.children or {}) do
        if expand_path(child) then
          current.expanded = true
          return true
        end
      end
      return false
    end
    if state.root then
      expand_path(state.root)
    end
    callback(node)
  end)
end

--- Toggle a node's expanded state or lazy-load its children
--- Behavior:
--- - Columns, constraints, and indexes cannot be expanded (no-op)
--- - If expanded: collapse the node
--- - If collapsed with children already loaded: expand the node
--- - If collapsed without children: trigger async load, then expand on success
--- @param node TreeNode Node to toggle
--- @param callback function|nil Called after toggle completes (for UI refresh)
function Tree.toggle_node(node, callback)
  if node.type == "column" or node.type == "constraint" or node.type == "index" then
    return
  end

  if node.expanded then
    node.expanded = false
    if callback then
      callback()
    end
    return
  end

  if node.children then
    node.expanded = true
    if callback then
      callback()
    end
    return
  end

  if node.type == "datasource" then
    Tree.load_databases(node, function(success)
      if success then
        node.expanded = true
      end
      if callback then
        callback()
      end
    end)
  elseif node.type == "database" then
    Tree.load_tables(node, function(success)
      if success then
        node.expanded = true
      end
      if callback then
        callback()
      end
    end)
  elseif node.type == "table" then
    Tree.load_columns(node, function(success)
      if success then
        node.expanded = true
      end
      if callback then
        callback()
      end
    end)
  elseif node.type == "constraints_folder" then
    Tree.load_constraints(node, function(success)
      if success then
        node.expanded = true
      end
      if callback then
        callback()
      end
    end)
  elseif node.type == "indexes_folder" then
    Tree.load_indexes(node, function(success)
      if success then
        node.expanded = true
      end
      if callback then
        callback()
      end
    end)
  end
end

--- Asynchronously load databases for a datasource node
--- Creates child nodes for each database and stores them sorted alphabetically
--- @param datasource_node TreeNode Datasource node to load children for
--- @param callback fun(success: boolean) Called with true on success, false on error
function Tree.load_databases(datasource_node, callback)
  local datasource = datasource_node.metadata.datasource
  if not datasource or not datasource.adapter then
    vim.notify("No adapter for datasource: " .. datasource_node.name, vim.log.levels.ERROR)
    callback(false)
    return
  end

  datasource.adapter:get_databases(function(databases, err)
    if err then
      vim.notify("Error loading databases: " .. err, vim.log.levels.ERROR)
      callback(false)
      return
    end

    datasource_node.children = {}
    for _, db_name in ipairs(databases) do
      local db_node = create_node("database", db_name, datasource_node.level + 1, {
        datasource_name = datasource_node.name,
        datasource = datasource,
        database_name = db_name,
      })
      table.insert(datasource_node.children, db_node)
    end

    table.sort(datasource_node.children, function(a, b)
      return a.name < b.name
    end)

    callback(true)
  end)
end

--- Asynchronously load tables for a database node
--- Creates child nodes for each table and stores them sorted alphabetically
--- @param database_node TreeNode Database node to load children for
--- @param callback fun(success: boolean) Called with true on success, false on error
function Tree.load_tables(database_node, callback)
  local datasource = database_node.metadata.datasource
  local database_name = database_node.metadata.database_name

  if not datasource or not datasource.adapter then
    vim.notify("No adapter for database: " .. database_node.name, vim.log.levels.ERROR)
    callback(false)
    return
  end

  datasource.adapter:get_tables(database_name, function(tables, err)
    if err then
      vim.notify("Error loading tables: " .. err, vim.log.levels.ERROR)
      callback(false)
      return
    end

    database_node.children = {}
    for _, table_name in ipairs(tables) do
      local table_node = create_node("table", table_name, database_node.level + 1, {
        datasource_name = database_node.metadata.datasource_name,
        datasource = datasource,
        database_name = database_name,
        table_name = table_name,
      })
      table.insert(database_node.children, table_node)
    end

    table.sort(database_node.children, function(a, b)
      return a.name < b.name
    end)

    callback(true)
  end)
end

--- Asynchronously load columns for a table node
--- Creates child nodes for each column with type information
--- Also adds a Constraints folder node at the end
--- @param table_node TreeNode Table node to load children for
--- @param callback fun(success: boolean) Called with true on success, false on error
function Tree.load_columns(table_node, callback)
  local datasource = table_node.metadata.datasource
  local database_name = table_node.metadata.database_name
  local table_name = table_node.metadata.table_name

  if not datasource or not datasource.adapter then
    vim.notify("No adapter for table: " .. table_node.name, vim.log.levels.ERROR)
    callback(false)
    return
  end

  datasource.adapter:get_columns(database_name, table_name, function(columns, err)
    if err then
      vim.notify("Error loading columns: " .. err, vim.log.levels.ERROR)
      callback(false)
      return
    end

    table_node.children = {}
    for _, column in ipairs(columns) do
      local col_node = create_node("column", column.name, table_node.level + 1, {
        datasource_name = table_node.metadata.datasource_name,
        datasource = datasource,
        database_name = database_name,
        table_name = table_name,
        column_type = column.type,
      })
      table.insert(table_node.children, col_node)
    end

    -- Add Constraints folder node at the end
    local constraints_node = create_node("constraints_folder", "Constraints", table_node.level + 1, {
      datasource_name = table_node.metadata.datasource_name,
      datasource = datasource,
      database_name = database_name,
      table_name = table_name,
    })
    table.insert(table_node.children, constraints_node)

    -- Add Indexes folder node at the end
    local indexes_node = create_node("indexes_folder", "Indexes", table_node.level + 1, {
      datasource_name = table_node.metadata.datasource_name,
      datasource = datasource,
      database_name = database_name,
      table_name = table_name,
    })
    table.insert(table_node.children, indexes_node)

    callback(true)
  end)
end

--- Asynchronously load constraints for a constraints folder node
--- Creates child nodes for primary key and foreign key constraints
--- @param constraints_node TreeNode Constraints folder node to load children for
--- @param callback fun(success: boolean) Called with true on success, false on error
function Tree.load_constraints(constraints_node, callback)
  local datasource = constraints_node.metadata.datasource
  local database_name = constraints_node.metadata.database_name
  local table_name = constraints_node.metadata.table_name

  if not datasource or not datasource.adapter then
    vim.notify("No adapter for constraints: " .. constraints_node.name, vim.log.levels.ERROR)
    callback(false)
    return
  end

  datasource.adapter:get_constraints(database_name, table_name, function(constraints, err)
    if err then
      vim.notify("Error loading constraints: " .. err, vim.log.levels.ERROR)
      callback(false)
      return
    end

    constraints_node.children = {}

    -- Add primary key node if exists
    if constraints.primary_key and #constraints.primary_key > 0 then
      local pk_text = "PK: " .. table.concat(constraints.primary_key, ", ")
      local pk_node = create_node("constraint", pk_text, constraints_node.level + 1, {
        constraint_type = "primary_key",
      })
      table.insert(constraints_node.children, pk_node)
    end

    -- Add foreign key nodes
    for _, fk in ipairs(constraints.foreign_keys or {}) do
      local fk_text = string.format("FK: %s → %s.%s", fk.column, fk.ref_table, fk.ref_column)
      local fk_node = create_node("constraint", fk_text, constraints_node.level + 1, {
        constraint_type = "foreign_key",
      })
      table.insert(constraints_node.children, fk_node)
    end

    callback(true)
  end)
end

--- Asynchronously load indexes for an indexes folder node
--- Creates child nodes for each index with column information
--- @param indexes_node TreeNode Indexes folder node to load children for
--- @param callback fun(success: boolean) Called with true on success, false on error
function Tree.load_indexes(indexes_node, callback)
  local datasource = indexes_node.metadata.datasource
  local database_name = indexes_node.metadata.database_name
  local table_name = indexes_node.metadata.table_name

  if not datasource or not datasource.adapter then
    vim.notify("No adapter for indexes: " .. indexes_node.name, vim.log.levels.ERROR)
    callback(false)
    return
  end

  datasource.adapter:get_indexes(database_name, table_name, function(indexes, err)
    if err then
      vim.notify("Error loading indexes: " .. err, vim.log.levels.ERROR)
      callback(false)
      return
    end

    indexes_node.children = {}

    for _, idx in ipairs(indexes or {}) do
      local unique_marker = idx.unique and "UNIQUE " or ""
      local idx_text = string.format("%s%s (%s)", unique_marker, idx.name, table.concat(idx.columns, ", "))
      local idx_node = create_node("index", idx_text, indexes_node.level + 1, {
        index_name = idx.name,
        unique = idx.unique,
      })
      table.insert(indexes_node.children, idx_node)
    end

    callback(true)
  end)
end

--- Get the current tree root node
--- @return TreeNode|nil Root node, or nil if tree hasn't been built yet
function Tree.get_root()
  return state.root
end

--- Browse table data by executing a SELECT query
--- Only works when called on a table node
--- @param node TreeNode Table node to browse
--- @param callback fun(success: boolean) Called after query execution
function Tree.browse_table_data(node, callback)
  if node.type ~= "table" then
    vim.notify("Can only browse data for table nodes", vim.log.levels.WARN)
    if callback then
      callback(false)
    end
    return
  end

  local datasource = node.metadata.datasource
  local database_name = node.metadata.database_name
  local table_name = node.metadata.table_name

  if not datasource or not datasource.adapter then
    vim.notify("No adapter for table: " .. node.name, vim.log.levels.ERROR)
    if callback then
      callback(false)
    end
    return
  end

  -- Build SELECT query with fully qualified table name
  local escaped_db = datasource.adapter:escape_identifier(database_name)
  local escaped_table = datasource.adapter:escape_identifier(table_name)
  local query = string.format("SELECT * FROM %s.%s LIMIT 1000", escaped_db, escaped_table)

  local Query = require("abcql.db.query")
  local History = require("abcql.history")

  Query.execute_async(datasource.adapter, query, function(results, err)
    -- Save to history (both success and error cases)
    History.save(query, datasource.name, database_name, results, err)

    local display_opts = { query = query, datasource = datasource }
    if err then
      if state.display_fn then
        state.display_fn(err, nil, display_opts)
      end
      if callback then
        callback(false)
      end
      return
    end

    if state.display_fn then
      state.display_fn(results, nil, display_opts)
    end

    if callback then
      callback(true)
    end
  end, { database = database_name })
end

return Tree
