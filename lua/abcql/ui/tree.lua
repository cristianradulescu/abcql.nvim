---@class TreeNode
---@field type "datasource"|"database"|"table"|"column"
---@field name string Display name of the node
---@field level number Indentation level (0 for datasource, 1 for database, etc.)
---@field expanded boolean Whether the node is currently expanded
---@field children TreeNode[]|nil Child nodes (nil until first expansion)
---@field metadata table Additional context (datasource, database_name, table_name, column_type, etc.)

---@class abcql.ui.Tree
local Tree = {}

local state = {
  root = nil,
  line_to_node = {},
}

local ICONS = {
  expanded = "▼",
  collapsed = "▶",
  leaf = "•",
}

--- Create a new tree node
--- @param type "datasource"|"database"|"table"|"column" Node type
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
  local root = create_node("root", "Data Sources", -1, {})
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
--- @return string Formatted display line
local function format_node_line(node)
  local indent = get_indent(node.level)
  local icon

  if node.type == "column" then
    icon = ICONS.leaf
  elseif node.expanded then
    icon = ICONS.expanded
  else
    icon = ICONS.collapsed
  end

  local display_name = node.name
  if node.type == "column" and node.metadata.column_type then
    display_name = display_name .. " (" .. node.metadata.column_type .. ")"
  end

  if node.level < 0 then
    return display_name .. ":"
  end

  return indent .. icon .. " " .. display_name
end

--- Render the tree into display lines and build line-to-node mapping
--- Only expanded nodes and their visible children are included in the output
--- @param root TreeNode Root node to render
--- @return string[] Array of formatted display lines
function Tree.render(root)
  state.line_to_node = {}
  local lines = {}
  local line_num = 1

  local function render_node(node)
    if not node then
      return
    end

    local line = format_node_line(node)
    table.insert(lines, line)
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

  return lines
end

--- Get the tree node at a specific buffer line number
--- @param line_num number Buffer line number (1-indexed)
--- @return TreeNode|nil Node at the line, or nil if no node exists
function Tree.get_node_at_line(line_num)
  return state.line_to_node[line_num]
end

--- Toggle a node's expanded state or lazy-load its children
--- Behavior:
--- - Columns cannot be expanded (no-op)
--- - If expanded: collapse the node
--- - If collapsed with children already loaded: expand the node
--- - If collapsed without children: trigger async load, then expand on success
--- @param node TreeNode Node to toggle
--- @param callback function|nil Called after toggle completes (for UI refresh)
function Tree.toggle_node(node, callback)
  if node.type == "column" then
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

    callback(true)
  end)
end

--- Get the current tree root node
--- @return TreeNode|nil Root node, or nil if tree hasn't been built yet
function Tree.get_root()
  return state.root
end

return Tree
