---@class abcql.lsp.Cache
---@field private caches table<string, CacheData> Cache per datasource
local Cache = {}
Cache.__index = Cache

---@class CacheData
---@field databases string[] List of database names
---@field tables table<string, string[]> Tables by database name
---@field columns table<string, ColumnInfo[]> Columns by "database.table" key
---@field metadata CacheMetadata

---@class CacheMetadata
---@field loaded_at number Timestamp when cache was created

---@class ColumnInfo
---@field name string Column name
---@field type string Column type

--- Create a new cache instance
---@return abcql.lsp.Cache
function Cache.new()
  local self = setmetatable({}, Cache)
  self.caches = {}
  return self
end

--- Load all schema metadata for a datasource
---@param datasource_name string Name of the datasource
---@param adapter abcql.db.adapter.Adapter Database adapter instance
---@param callback fun(err: string|nil) Called when loading is complete
function Cache:load_schema(datasource_name, adapter, callback)
  -- Initialize cache structure
  self.caches[datasource_name] = {
    databases = {},
    tables = {},
    columns = {},
    metadata = {
      loaded_at = os.time(),
    },
  }

  local cache = self.caches[datasource_name]

  -- Step 1: Load databases
  adapter:get_databases(function(databases, err)
    if err then
      callback("Failed to load databases: " .. err)
      return
    end

    cache.databases = databases

    -- Step 2: Load tables for each database
    local pending_databases = #databases
    if pending_databases == 0 then
      callback(nil)
      return
    end

    for _, db in ipairs(databases) do
      adapter:get_tables(db, function(tables, tables_err)
        if tables_err then
          callback("Failed to load tables for database '" .. db .. "': " .. tables_err)
          return
        end

        cache.tables[db] = tables

        -- Step 3: Load columns for each table
        local pending_tables = #tables
        if pending_tables == 0 then
          pending_databases = pending_databases - 1
          if pending_databases == 0 then
            callback(nil)
          end
          return
        end

        for _, table_name in ipairs(tables) do
          adapter:get_columns(db, table_name, function(columns, columns_err)
            if columns_err then
              callback("Failed to load columns for table '" .. db .. "." .. table_name .. "': " .. columns_err)
              return
            end

            local key = db .. "." .. table_name
            cache.columns[key] = columns

            pending_tables = pending_tables - 1
            if pending_tables == 0 then
              pending_databases = pending_databases - 1
              if pending_databases == 0 then
                callback(nil)
              end
            end
          end)
        end
      end)
    end
  end)
end

--- Get cached databases for a datasource
---@param datasource_name string Name of the datasource
---@return string[]|nil Array of database names, or nil if not cached
function Cache:get_databases(datasource_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  return cache.databases
end

--- Get cached tables for a database
---@param datasource_name string Name of the datasource
---@param database string Database name
---@return string[]|nil Array of table names, or nil if not cached
function Cache:get_tables(datasource_name, database)
  local cache = self.caches[datasource_name]
  if not cache or not cache.tables[database] then
    return nil
  end
  return cache.tables[database]
end

--- Get all tables across all databases for a datasource
---@param datasource_name string Name of the datasource
---@return table<string, string[]>|nil Tables by database, or nil if not cached
function Cache:get_all_tables(datasource_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  return cache.tables
end

--- Get cached columns for a table
---@param datasource_name string Name of the datasource
---@param database string Database name
---@param table_name string Table name
---@return ColumnInfo[]|nil Array of column info, or nil if not cached
function Cache:get_columns(datasource_name, database, table_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  local key = database .. "." .. table_name
  return cache.columns[key]
end

--- Clear cache for a specific datasource
---@param datasource_name string Name of the datasource
function Cache:clear(datasource_name)
  self.caches[datasource_name] = nil
end

--- Check if cache exists for a datasource
---@param datasource_name string Name of the datasource
---@return boolean True if cache exists
function Cache:has_cache(datasource_name)
  return self.caches[datasource_name] ~= nil
end

--- Get cache metadata
---@param datasource_name string Name of the datasource
---@return CacheMetadata|nil Cache metadata, or nil if not cached
function Cache:get_metadata(datasource_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  return cache.metadata
end

return Cache
