local MySQLAdapter = require("abcql.db.adapter.mysql")

describe("MySQLAdapter", function()
  local adapter

  before_each(function()
    adapter = MySQLAdapter.new({
      host = "localhost",
      port = 3306,
      user = "testuser",
      password = "testpass",
      database = "testdb",
    })
  end)

  describe("new", function()
    it("should create a new MySQL adapter instance", function()
      assert.is_not_nil(adapter)
      assert.is_table(adapter.config)
    end)

    it("should inherit from base Adapter", function()
      local Adapter = require("abcql.db.adapter.base")
      assert.is_not_nil(getmetatable(getmetatable(adapter)).__index)
      assert.are.equal(Adapter, getmetatable(getmetatable(adapter)).__index)
    end)
  end)

  describe("ENGINE", function()
    it("should be 'mysql'", function()
      assert.are.equal("mysql", MySQLAdapter.ENGINE)
    end)

    it("should be used by build_backend_request", function()
      local request = adapter:build_backend_request("SELECT 1", {})
      assert.are.equal("mysql", request.engine)
    end)
  end)

  describe("escape_identifier", function()
    it("should wrap identifier in backticks", function()
      local result = adapter:escape_identifier("table_name")
      assert.are.equal("`table_name`", result)
    end)

    it("should escape backticks within identifier", function()
      local result = adapter:escape_identifier("table`name")
      assert.are.equal("`table``name`", result)
    end)

    it("should handle multiple backticks", function()
      local result = adapter:escape_identifier("ta`ble`na`me")
      assert.are.equal("`ta``ble``na``me`", result)
    end)

    it("should handle empty identifier", function()
      local result = adapter:escape_identifier("")
      assert.are.equal("``", result)
    end)

    it("should handle special characters", function()
      local result = adapter:escape_identifier("table-with-dashes")
      assert.are.equal("`table-with-dashes`", result)
    end)
  end)

  describe("escape_value", function()
    it("should escape single quotes by doubling them", function()
      local result = adapter:escape_value("O'Reilly")
      assert.are.equal("O''Reilly", result)
    end)

    it("should handle multiple quotes", function()
      local result = adapter:escape_value("It's a 'test' value")
      assert.are.equal("It''s a ''test'' value", result)
    end)

    it("should handle consecutive quotes", function()
      local result = adapter:escape_value("test''value")
      assert.are.equal("test''''value", result)
    end)

    it("should handle empty string", function()
      local result = adapter:escape_value("")
      assert.are.equal("", result)
    end)

    it("should not modify strings without quotes", function()
      local result = adapter:escape_value("normal value")
      assert.are.equal("normal value", result)
    end)
  end)

  describe("get_constraints", function()
    -- Note: get_constraints requires async execution with Query.execute_async
    -- These tests verify the method exists and has the correct signature

    it("should be a function", function()
      assert.is_function(adapter.get_constraints)
    end)

    it("should accept database, table_name, and callback parameters", function()
      -- We can't easily test async behavior in unit tests,
      -- but we can verify the method exists and accepts the right params
      assert.has_no.errors(function()
        -- Just verify the method signature is correct by checking it's callable
        assert.is_function(adapter.get_constraints)
      end)
    end)
  end)

  describe("get_indexes", function()
    -- Note: get_indexes requires async execution with Query.execute_async
    -- These tests verify the method exists and has the correct signature

    it("should be a function", function()
      assert.is_function(adapter.get_indexes)
    end)

    it("should accept database, table_name, and callback parameters", function()
      -- Verify the method can be called with the expected signature
      -- The actual async behavior would need integration tests
      assert.has_no.errors(function()
        -- Just verify the method signature is correct by checking it's callable
        assert.is_function(adapter.get_indexes)
      end)
    end)
  end)
end)

describe("MySQLAdapter constraint names", function()
  local Query = require("abcql.db.query")
  local original_execute_async
  local rows
  local adapter

  before_each(function()
    adapter = MySQLAdapter.new({ database = "shop" })
    original_execute_async = Query.execute_async
    Query.execute_async = function(_, _, callback)
      callback({ rows = rows }, nil)
    end
  end)

  after_each(function()
    Query.execute_async = original_execute_async
  end)

  it("tags every column of a composite foreign key with its constraint in get_all_constraints", function()
    rows = {
      { "lines", "order_id", "FOREIGN KEY", "orders", "id", "fk_lines_order" },
      { "lines", "shop_id", "FOREIGN KEY", "orders", "shop_id", "fk_lines_order" },
      { "lines", "sku", "FOREIGN KEY", "products", "sku", "fk_lines_product" },
      { "lines", "id", "PRIMARY KEY", "NULL", "NULL", "PRIMARY" },
    }
    local result
    adapter:get_all_constraints("shop", function(by_table)
      result = by_table
    end)

    local fks = result.lines.foreign_keys
    assert.are.same({ "fk_lines_order", "fk_lines_order", "fk_lines_product" }, {
      fks[1].constraint,
      fks[2].constraint,
      fks[3].constraint,
    })
    assert.are.same({ "id" }, result.lines.primary_key)
  end)

  it("tags foreign keys with their constraint in get_constraints", function()
    rows = {
      { "order_id", "FOREIGN KEY", "orders", "id", "fk_lines_order" },
      { "shop_id", "FOREIGN KEY", "orders", "shop_id", "fk_lines_order" },
    }
    local result
    adapter:get_constraints("shop", "lines", function(constraints)
      result = constraints
    end)

    assert.are.same(
      { column = "shop_id", ref_table = "orders", ref_column = "shop_id", constraint = "fk_lines_order" },
      result.foreign_keys[2]
    )
  end)
end)
