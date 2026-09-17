---@class abcql.lsp.Cache
---@field private caches table<string, CacheData> Cache per datasource
local Cache = {}
Cache.__index = Cache

---@class CacheData
---@field databases string[] List of database names
---@field tables table<string, string[]> Tables by database name
---@field columns table<string, ColumnInfo[]> Columns by "database.table" key
---@field constraints table<string, TableConstraints> Constraints by "database.table" key
---@field metadata CacheMetadata

---@class CacheMetadata
---@field loaded_at number Timestamp when cache was created

---@class ColumnInfo
---@field name string Column name
---@field type string Column type

---@class TableConstraints
---@field primary_key string[]
---@field foreign_keys { column: string, ref_table: string, ref_column: string }[]

--- Create a new cache instance
---@return abcql.lsp.Cache
function Cache.new()
  local self = setmetatable({}, Cache)
  self.caches = {}
  return self
end

--- Load all schema metadata for a datasource.
--- Uses the adapter's batched `get_all_columns`/`get_all_constraints` when
--- available (one query per database) and falls back to per-table
--- `get_columns` otherwise.
---@param datasource_name string Name of the datasource
---@param adapter abcql.db.adapter.Adapter Database adapter instance
---@param callback fun(err: string|nil) Called when loading is complete
function Cache:load_schema(datasource_name, adapter, callback)
  self.caches[datasource_name] = {
    databases = {},
    tables = {},
    columns = {},
    constraints = {},
    metadata = { loaded_at = os.time() },
  }

  local cache = self.caches[datasource_name]
  local errored = false

  local function fail(msg)
    if errored then
      return
    end
    errored = true
    callback(msg)
  end

  --- Load columns for one database's tables, then call done(err)
  local function load_columns(db, tables, done)
    if #tables == 0 then
      done(nil)
      return
    end

    if adapter.get_all_columns then
      adapter:get_all_columns(db, function(by_table, err)
        if err then
          done("Failed to load columns for database '" .. db .. "': " .. err)
          return
        end
        for table_name, columns in pairs(by_table or {}) do
          cache.columns[db .. "." .. table_name] = columns
        end
        for _, table_name in ipairs(tables) do
          cache.columns[db .. "." .. table_name] = cache.columns[db .. "." .. table_name] or {}
        end
        done(nil)
      end)
      return
    end

    local pending = #tables
    for _, table_name in ipairs(tables) do
      adapter:get_columns(db, table_name, function(columns, err)
        if errored then
          return
        end
        if err then
          done("Failed to load columns for table '" .. db .. "." .. table_name .. "': " .. err)
          return
        end
        cache.columns[db .. "." .. table_name] = columns
        pending = pending - 1
        if pending == 0 then
          done(nil)
        end
      end)
    end
  end

  --- Load constraints for one database (best effort: errors leave them empty)
  local function load_constraints(db, done)
    if not adapter.get_all_constraints then
      done()
      return
    end
    adapter:get_all_constraints(db, function(by_table, _)
      for table_name, constraints in pairs(by_table or {}) do
        cache.constraints[db .. "." .. table_name] = constraints
      end
      done()
    end)
  end

  adapter:get_databases(function(databases, err)
    if err then
      fail("Failed to load databases: " .. err)
      return
    end

    cache.databases = databases or {}
    local pending_databases = #cache.databases
    if pending_databases == 0 then
      callback(nil)
      return
    end

    for _, db in ipairs(cache.databases) do
      adapter:get_tables(db, function(tables, tables_err)
        if errored then
          return
        end
        if tables_err then
          fail("Failed to load tables for database '" .. db .. "': " .. tables_err)
          return
        end

        cache.tables[db] = tables or {}

        load_columns(db, cache.tables[db], function(columns_err)
          if errored then
            return
          end
          if columns_err then
            fail(columns_err)
            return
          end
          load_constraints(db, function()
            if errored then
              return
            end
            pending_databases = pending_databases - 1
            if pending_databases == 0 then
              callback(nil)
            end
          end)
        end)
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

--- Find a table by name, case-insensitively, optionally within one database
---@param datasource_name string
---@param table_name string
---@param database string|nil
---@return string|nil database Real database name
---@return string|nil table_name Real table name (as stored in the cache)
function Cache:find_table(datasource_name, table_name, database)
  local cache = self.caches[datasource_name]
  if not cache or not table_name then
    return nil, nil
  end
  local wanted = table_name:lower()
  local db_wanted = database and database:lower() or nil
  for db, tables in pairs(cache.tables) do
    if not db_wanted or db:lower() == db_wanted then
      for _, tbl in ipairs(tables) do
        if tbl:lower() == wanted then
          return db, tbl
        end
      end
    end
  end
  return nil, nil
end

--- Get cached columns for a table (database and table matched case-insensitively)
---@param datasource_name string Name of the datasource
---@param database string Database name
---@param table_name string Table name
---@return ColumnInfo[]|nil Array of column info, or nil if not cached
function Cache:get_columns(datasource_name, database, table_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  local exact = cache.columns[database .. "." .. table_name]
  if exact then
    return exact
  end
  local db, tbl = self:find_table(datasource_name, table_name, database)
  if not db then
    return nil
  end
  return cache.columns[db .. "." .. tbl]
end

--- Get cached constraints for a table (case-insensitive)
---@param datasource_name string
---@param database string
---@param table_name string
---@return TableConstraints|nil
function Cache:get_constraints(datasource_name, database, table_name)
  local cache = self.caches[datasource_name]
  if not cache then
    return nil
  end
  local exact = cache.constraints[database .. "." .. table_name]
  if exact then
    return exact
  end
  local db, tbl = self:find_table(datasource_name, table_name, database)
  if not db then
    return nil
  end
  return cache.constraints[db .. "." .. tbl]
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
