local ConnectionRegistry = require("abcql.db.connection.registry")

---@class abcql.Database
local Database = {
  --- @type abcql.db.connection.Registry
  connectionRegistry = nil,
  --- @type table<number, string> Maps buffer numbers to active data source names
  buffer_datasources = {},
}

Database.connectionRegistry = ConnectionRegistry.new()

--- Setup the database module with configuration
--- @param config abcql.Config
function Database.setup(config)
  -- Register built-in adapters
  local MySQLAdapter = require("abcql.db.adapter.mysql")
  Database.connectionRegistry:register_adapter("mysql", MySQLAdapter)
  -- @TODO: Register other adapters like PostgreSQL, SQLite, etc.

  vim.notify("Database adapters registered", vim.log.levels.INFO)

  -- Register data sources from config
  for dsn_name, dsn in pairs(config.data_sources or {}) do
    Database.connectionRegistry:register_datasource(dsn_name, dsn)
  end
end

--- Activate a data source by name and update buffer winbar
--- @param bufnr number
function Database.activate_datasource(bufnr)
  vim.ui.select(
    vim.tbl_keys(Database.connectionRegistry:get_all_datasources()),
    { prompt = "Select Data Source:" },
    function(datasource_name)
      local dsn = Database.connectionRegistry:get_datasource(datasource_name)
      if not dsn then
        vim.notify("Data source not found: " .. datasource_name, vim.log.levels.ERROR)
        return
      end

      local adapter, err = Database.connectionRegistry:get_connection(dsn)
      if not adapter then
        vim.notify("Failed to connect to data source: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Store active data source for the buffer
      Database.buffer_datasources[bufnr] = datasource_name

      -- Update winbar to show connected data source
      vim.api.nvim_buf_set_option(bufnr, "winbar", "[abcql.nvim] | Data source: `" .. datasource_name .. "`")

      vim.notify("Connected to data source: " .. datasource_name, vim.log.levels.INFO)
    end
  )
end

--- Get the active data source name for a buffer
--- @param bufnr number
--- @return string|nil
function Database.get_active_datasource(bufnr)
  return Database.buffer_datasources[bufnr]
end

return Database
