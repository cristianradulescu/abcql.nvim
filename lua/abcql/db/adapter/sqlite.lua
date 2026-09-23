local Adapter = require("abcql.db.adapter.base")
local Query = require("abcql.db.query")

---@class abcql.db.adapter.SQLiteAdapter: abcql.db.adapter.Adapter
local SQLiteAdapter = {}
SQLiteAdapter.__index = SQLiteAdapter
setmetatable(SQLiteAdapter, { __index = Adapter })

--- Engine identifier sent to abcql-backend
SQLiteAdapter.ENGINE = "sqlite"

--- Tables and views of a schema, skipping SQLite's internal `sqlite_*` tables
local USER_TABLES = [[SELECT name FROM %s.sqlite_master
  WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\_%%' ESCAPE '\']]

--- Create a new SQLite adapter instance
--- @param config AdapterConfig Configuration parameters for the adapter (`path` is the database file)
--- @return table The adapter instance
function SQLiteAdapter.new(config)
  local self = Adapter.new(config)
  return setmetatable(self, SQLiteAdapter)
end

--- The backend opens `path`; `database` is the schema name ("main") the rest of the
--- plugin qualifies tables with, so it isn't sent.
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (timeout?: number in ms, max_rows?: number)
--- @return table request
function SQLiteAdapter:build_backend_request(query, opts)
  local request = Adapter.build_backend_request(self, query, opts)
  request.database = self.config.path
  return request
end

--- Execute a query with possible asynchronous callback
--- @param query string The SQL query to execute
--- @param opts table|nil Optional parameters (adapter-specific)
--- @param callback function Called with (results, error) where results is structured data
function SQLiteAdapter:execute_query(query, opts, callback)
  if callback == nil then
    return Query.execute_sync(self, query, opts)
  end

  return Query.execute_async(self, query, callback, opts)
end

--- Run a query and hand its rows to `on_rows`, or the error to `callback`
--- @param query string
--- @param callback function Called with (nil, err) on failure
--- @param on_rows fun(rows: string[][])
function SQLiteAdapter:query_rows(query, callback, on_rows)
  Query.execute_async(self, query, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    on_rows(result.rows or {})
  end)
end

--- Fetch the schemas of the database file (`main`, plus any attached ones)
--- @param callback function Called with (databases, error) where databases is array of schema names
function SQLiteAdapter:get_databases(callback)
  self:query_rows("SELECT name FROM pragma_database_list WHERE name <> 'temp' ORDER BY seq", callback, function(rows)
    local databases = {}
    for _, row in ipairs(rows) do
      table.insert(databases, row[1])
    end
    callback(databases, nil)
  end)
end

--- Fetch list of tables and views in a schema asynchronously
--- @param database string Schema name
--- @param callback function Called with (tables, error) where tables is array of table names
function SQLiteAdapter:get_tables(database, callback)
  local query = string.format(USER_TABLES .. " ORDER BY name", self:escape_identifier(database))
  self:query_rows(query, callback, function(rows)
    local tables = {}
    for _, row in ipairs(rows) do
      table.insert(tables, row[1])
    end
    callback(tables, nil)
  end)
end

--- Fetch list of columns in a table asynchronously
--- @param database string Schema name
--- @param table_name string Table name
--- @param callback function Called with (columns, error) where columns is array of {name, type} tables
function SQLiteAdapter:get_columns(database, table_name, callback)
  local query = string.format(
    "SELECT name, type FROM pragma_table_info('%s', '%s') ORDER BY cid",
    self:escape_value(table_name),
    self:escape_value(database)
  )
  self:query_rows(query, callback, function(rows)
    local columns = {}
    for _, row in ipairs(rows) do
      table.insert(columns, { name = row[1], type = row[2] or "" })
    end
    callback(columns, nil)
  end)
end

--- Fetch the columns of every table in a schema with one query
--- @param database string Schema name
--- @param callback fun(columns_by_table: table<string, ColumnInfo[]>|nil, err: string|nil)
function SQLiteAdapter:get_all_columns(database, callback)
  local query = string.format(
    "SELECT t.name, c.name, c.type FROM (%s) t JOIN pragma_table_info(t.name, '%s') c ORDER BY t.name, c.cid",
    string.format(USER_TABLES, self:escape_identifier(database)),
    self:escape_value(database)
  )
  self:query_rows(query, callback, function(rows)
    local by_table = {}
    for _, row in ipairs(rows) do
      by_table[row[1]] = by_table[row[1]] or {}
      table.insert(by_table[row[1]], { name = row[2], type = row[3] or "" })
    end
    callback(by_table, nil)
  end)
end

--- Primary key and foreign key rows for the tables selected by `tables_sql`, as
--- (table, column, constraint type, ref table, ref column, constraint name).
--- A foreign key without an explicit target column references the parent's
--- primary key, which is looked up for single-column keys.
--- @param tables_sql string Query selecting a `name` column of table names
--- @param schema string Escaped schema name (as a string literal body)
--- @return string
local function constraints_query(tables_sql, schema)
  return string.format(
    [[SELECT t.name, c.name, 'PRIMARY KEY', NULL, NULL, 'PRIMARY', 0, c.pk
    FROM (%s) t JOIN pragma_table_info(t.name, '%s') c
    WHERE c.pk > 0
    UNION ALL
    SELECT t.name, f."from", 'FOREIGN KEY', f."table",
      COALESCE(f."to", (SELECT p.name FROM pragma_table_info(f."table", '%s') p WHERE p.pk = 1)),
      t.name || '_fk' || f.id, 1 + f.id, f.seq
    FROM (%s) t JOIN pragma_foreign_key_list(t.name, '%s') f
    ORDER BY 1, 7, 8]],
    tables_sql,
    schema,
    schema,
    tables_sql,
    schema
  )
end

--- Group constraint rows into { primary_key, foreign_keys } per table
--- @param rows string[][]
--- @return table<string, { primary_key: string[], foreign_keys: table[] }>
local function group_constraints(rows)
  local by_table = {}
  for _, row in ipairs(rows) do
    local table_name, column_name, constraint_type, ref_table, ref_column, name =
      row[1], row[2], row[3], row[4], row[5], row[6]
    by_table[table_name] = by_table[table_name] or { primary_key = {}, foreign_keys = {} }
    if constraint_type == "PRIMARY KEY" then
      table.insert(by_table[table_name].primary_key, column_name)
    elseif ref_table and ref_table ~= "NULL" and ref_column and ref_column ~= "NULL" then
      table.insert(by_table[table_name].foreign_keys, {
        column = column_name,
        ref_table = ref_table,
        ref_column = ref_column,
        constraint = name,
      })
    end
  end
  return by_table
end

--- Fetch primary/foreign key constraints of every table in a schema with one query
--- @param database string Schema name
--- @param callback fun(constraints_by_table: table<string, { primary_key: string[], foreign_keys: table[] }>|nil, err: string|nil)
function SQLiteAdapter:get_all_constraints(database, callback)
  local tables_sql = string.format(USER_TABLES, self:escape_identifier(database))
  self:query_rows(constraints_query(tables_sql, self:escape_value(database)), callback, function(rows)
    callback(group_constraints(rows), nil)
  end)
end

--- Fetch constraints for a table asynchronously
--- @param database string Schema name
--- @param table_name string Table name
--- @param callback function Called with (constraints, error) where constraints is { primary_key: string[], foreign_keys: {column, ref_table, ref_column}[] }
function SQLiteAdapter:get_constraints(database, table_name, callback)
  local tables_sql = string.format("SELECT '%s' AS name", self:escape_value(table_name))
  self:query_rows(constraints_query(tables_sql, self:escape_value(database)), callback, function(rows)
    callback(group_constraints(rows)[table_name] or { primary_key = {}, foreign_keys = {} }, nil)
  end)
end

--- Fetch indexes for a table asynchronously
--- @param database string Schema name
--- @param table_name string Table name
--- @param callback function Called with (indexes, error) where indexes is array of { name: string, columns: string[], unique: boolean }
function SQLiteAdapter:get_indexes(database, table_name, callback)
  local query = string.format(
    [[SELECT il.name, ii.name, il."unique"
    FROM pragma_index_list('%s', '%s') il JOIN pragma_index_info(il.name, '%s') ii
    ORDER BY il.name, ii.seqno]],
    self:escape_value(table_name),
    self:escape_value(database),
    self:escape_value(database)
  )
  self:query_rows(query, callback, function(rows)
    local index_map = {}
    local indexes = {}
    for _, row in ipairs(rows) do
      local index_name = row[1]
      if not index_map[index_name] then
        index_map[index_name] = { name = index_name, columns = {}, unique = row[3] == "1" }
        table.insert(indexes, index_map[index_name])
      end
      -- Expression indexes have no column name
      table.insert(index_map[index_name].columns, row[2] == "NULL" and "<expr>" or row[2])
    end
    callback(indexes, nil)
  end)
end

--- Escape a SQLite identifier using double quotes
--- @param name string The identifier to escape
--- @return string The escaped identifier with double quotes
function SQLiteAdapter:escape_identifier(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Escape a value for SQLite queries by doubling single quotes
--- @param value string The value to escape
--- @return string The escaped value
function SQLiteAdapter:escape_value(value)
  return (value:gsub("'", "''"))
end

return SQLiteAdapter
