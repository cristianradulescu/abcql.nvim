local SQLiteAdapter = require("abcql.db.adapter.sqlite")
local Query = require("abcql.db.query")

describe("SQLiteAdapter", function()
  local adapter

  before_each(function()
    adapter = SQLiteAdapter.new({ path = "/data/app.db", database = "main", options = {} })
  end)

  describe("build_backend_request", function()
    it("sends the sqlite engine and the file path as the database", function()
      local request = adapter:build_backend_request("SELECT 1", { database = "other" })
      assert.are.equal("sqlite", request.engine)
      assert.are.equal("/data/app.db", request.database)
      assert.are.equal("SELECT 1", request.sql)
    end)
  end)

  describe("escaping", function()
    it("wraps identifiers in double quotes, doubling embedded quotes", function()
      assert.are.equal('"users"', adapter:escape_identifier("users"))
      assert.are.equal('"a""b"', adapter:escape_identifier('a"b'))
    end)

    it("doubles single quotes in values", function()
      assert.are.equal("O''Brien", adapter:escape_value("O'Brien"))
    end)
  end)

  describe("schema queries", function()
    local original_execute_async
    local executed
    local rows

    before_each(function()
      executed = {}
      rows = {}
      original_execute_async = Query.execute_async
      Query.execute_async = function(_, sql, callback)
        table.insert(executed, sql)
        callback({ rows = rows }, nil)
      end
    end)

    after_each(function()
      Query.execute_async = original_execute_async
    end)

    it("lists schemas without temp", function()
      rows = { { "main" } }
      local result
      adapter:get_databases(function(databases)
        result = databases
      end)
      assert.are.same({ "main" }, result)
      assert.matches("pragma_database_list", executed[1])
    end)

    it("escapes the table name in get_columns", function()
      rows = { { "id", "INTEGER" }, { "note", "NULL" } }
      local result
      adapter:get_columns("main", "o'rders", function(columns)
        result = columns
      end)
      assert.matches("pragma_table_info%('o''rders', 'main'%)", executed[1])
      assert.are.same({ name = "id", type = "INTEGER" }, result[1])
    end)

    it("groups primary and composite foreign keys by table", function()
      rows = {
        { "lines", "order_id", "PRIMARY KEY", "NULL", "NULL", "PRIMARY", "0", "1" },
        { "lines", "line", "PRIMARY KEY", "NULL", "NULL", "PRIMARY", "0", "2" },
        { "lines", "order_id", "FOREIGN KEY", "orders", "id", "lines_fk0", "1", "0" },
        { "lines", "shop_id", "FOREIGN KEY", "orders", "shop_id", "lines_fk0", "1", "1" },
        { "notes", "ref", "FOREIGN KEY", "keyless", "NULL", "notes_fk0", "1", "0" },
      }
      local result
      adapter:get_all_constraints("main", function(by_table)
        result = by_table
      end)
      assert.are.same({ "order_id", "line" }, result.lines.primary_key)
      assert.are.equal(2, #result.lines.foreign_keys)
      assert.are.equal("lines_fk0", result.lines.foreign_keys[2].constraint)
      -- A foreign key whose target column can't be resolved is dropped
      assert.are.same({}, result.notes.foreign_keys)
    end)

    it("groups index columns in order and reads uniqueness", function()
      rows = {
        { "idx_a", "x", "0" },
        { "idx_a", "y", "0" },
        { "idx_expr", "NULL", "1" },
      }
      local result
      adapter:get_indexes("main", "t", function(indexes)
        result = indexes
      end)
      assert.are.same({ name = "idx_a", columns = { "x", "y" }, unique = false }, result[1])
      assert.are.same({ name = "idx_expr", columns = { "<expr>" }, unique = true }, result[2])
    end)

    it("passes query errors through", function()
      Query.execute_async = function(_, _, callback)
        callback(nil, "no such table")
      end
      local result, err
      adapter:get_tables("main", function(tables, e)
        result, err = tables, e
      end)
      assert.is_nil(result)
      assert.are.equal("no such table", err)
    end)
  end)
end)

-- End-to-end against a real database file; needs `make build` but no server.
local backend_path = vim.fn.fnamemodify("bin/abcql-backend", ":p")
local describe_backend = vim.fn.executable(backend_path) == 1 and describe or pending

describe_backend("SQLiteAdapter with abcql-backend", function()
  local path
  local adapter

  local function await(fn)
    local done, value, err = false, nil, nil
    fn(function(v, e)
      done, value, err = true, v, e
    end)
    vim.wait(5000, function()
      return done
    end)
    assert.is_true(done, "timed out")
    return value, err
  end

  before_each(function()
    path = vim.fn.tempname() .. ".db"
    vim.fn.writefile({}, path)
    local parsed = require("abcql.db.connection.dsn").parse_dsn("sqlite://" .. path)
    adapter = SQLiteAdapter.new({ path = parsed.path, database = parsed.database, options = parsed.options })
    for _, sql in ipairs({
      "CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT UNIQUE, avatar BLOB)",
      "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers, placed DATE)",
      "CREATE INDEX idx_orders_placed ON orders(placed, customer_id)",
      "INSERT INTO customers (email, avatar) VALUES ('a@x.io', x'CAFE')",
    }) do
      local _, err = adapter:execute_query(sql, nil)
      assert.is_nil(err)
    end
  end)

  after_each(function()
    vim.fn.delete(path)
  end)

  it("introspects tables, columns, constraints and indexes", function()
    assert.are.same(
      { "main" },
      await(function(cb)
        adapter:get_databases(cb)
      end)
    )
    assert.are.same(
      { "customers", "orders" },
      await(function(cb)
        adapter:get_tables("main", cb)
      end)
    )

    local columns = await(function(cb)
      adapter:get_all_columns("main", cb)
    end)
    assert.are.same({ name = "placed", type = "DATE" }, columns.orders[3])

    local constraints = await(function(cb)
      adapter:get_all_constraints("main", cb)
    end)
    assert.are.same({ "id" }, constraints.orders.primary_key)
    -- `REFERENCES customers` without a column resolves to the parent's primary key
    assert.are.same(
      { column = "customer_id", ref_table = "customers", ref_column = "id", constraint = "orders_fk0" },
      constraints.orders.foreign_keys[1]
    )

    local indexes = await(function(cb)
      adapter:get_indexes("main", "orders", cb)
    end)
    assert.are.same({ name = "idx_orders_placed", columns = { "placed", "customer_id" }, unique = false }, indexes[1])
  end)

  it("runs queries against the file, rendering blobs as hex", function()
    local result = await(function(cb)
      adapter:execute_query('SELECT email, avatar FROM "main"."customers"', nil, cb)
    end)
    assert.are.same({ { "a@x.io", "0xCAFE" } }, result.rows)
  end)
end)
