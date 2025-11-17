local ConnectionRegistry = require("abcql.db.connection.registry")
local LSP = require("abcql.lsp")

---@class abcql.Database
local Database = {
  --- @type abcql.db.connection.Registry
  connectionRegistry = nil,
  --- @type table<number, Datasource> Maps buffer numbers to active data source names
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

  -- Register data sources from config
  for name, dsn in pairs(config.datasources or {}) do
    Database.connectionRegistry:register_datasource(name, dsn)
  end
end

--- Activate a data source by name and update buffer winbar
--- @param bufnr number
function Database.activate_datasource(bufnr)
  vim.ui.select(
    vim.tbl_keys(Database.connectionRegistry:get_all_datasources()),
    { prompt = "Select datasource:" },
    function(datasource_name)
      local datasource, err = Database.connectionRegistry:get_datasource(datasource_name)
      if err then
        vim.notify("Error retrieving datasource: " .. err, vim.log.levels.ERROR)
        return
      end

      -- Store active data source for the buffer
      Database.buffer_datasources[bufnr] = datasource

      -- Update winbar to show connected data source
      vim.api.nvim_buf_set_option(
        bufnr,
        "winbar",
        "[abcql.nvim] | Data source: `" .. (datasource and datasource.name or "`Not selected`") .. "`"
      )

      vim.notify("Connected to data source: " .. datasource_name, vim.log.levels.INFO)

      -- Start LSP for this buffer
      LSP.start(bufnr, datasource, function(lsp_err)
        if lsp_err then
          vim.notify("Failed to start LSP: " .. lsp_err, vim.log.levels.ERROR)
        end
      end)
    end
  )
end

--- Get the active data source name for a buffer
--- @param bufnr number
--- @return Datasource|nil
function Database.get_active_datasource(bufnr)
  return Database.buffer_datasources[bufnr]
end

return Database
