local ConnectionRegistry = require("abcql.db.connection.registry")

---@class abcql.Database
local Database = {}

Database.connectionRegistry = ConnectionRegistry.new()

function Database.setup()
  -- Register built-in adapters
  local MySQLAdapter = require("abcql.db.adapter.mysql")
  Database.connectionRegistry:register_adapter("mysql", MySQLAdapter)
  -- @TODO: Register other adapters like PostgreSQL, SQLite, etc.

  vim.notify("Database adapters registered", vim.log.levels.INFO)
end

--- Get a connection from the registry
--- @param dsn string The data source name
--- @return abcql.db.adapter.Adapter|nil adapter instance
--- @return string|nil error message
function Database.connect(dsn)
  return Database.connectionRegistry:get_connection(dsn)
end

return Database
