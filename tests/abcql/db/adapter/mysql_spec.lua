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

  describe("get_command", function()
    it("should return 'mysql'", function()
      assert.are.equal("mysql", adapter:get_command())
    end)
  end)

  describe("get_args", function()
    it("should generate args with all config options", function()
      local args = adapter:get_args("SELECT 1")

      assert.is_table(args)
      assert.are.equal("-hlocalhost", args[1])
      assert.are.equal("-P3306", args[2])
      assert.are.equal("-utestuser", args[3])
      assert.are.equal("-ptestpass", args[4])
      assert.are.equal("-Dtestdb", args[5])
      assert.are.equal("--batch", args[6])
      assert.are.equal("-e", args[7])
      assert.are.equal("SELECT 1", args[8])
    end)

    it("should generate args without password", function()
      local adapter_no_pass = MySQLAdapter.new({
        host = "localhost",
        port = 3306,
        user = "testuser",
        database = "testdb",
      })

      local args = adapter_no_pass:get_args("SELECT 1")

      local has_password = false
      for _, arg in ipairs(args) do
        if arg:match("^%-p") then
          has_password = true
        end
      end

      assert.is_false(has_password)
    end)

    it("should generate args without database", function()
      local adapter_no_db = MySQLAdapter.new({
        host = "localhost",
        port = 3306,
        user = "testuser",
        password = "testpass",
      })

      local args = adapter_no_db:get_args("SELECT 1")

      local has_database = false
      for _, arg in ipairs(args) do
        if arg:match("^%-D") then
          has_database = true
        end
      end

      assert.is_false(has_database)
    end)

    it("should use default host and port when not provided", function()
      local adapter_defaults = MySQLAdapter.new({
        user = "testuser",
      })

      local args = adapter_defaults:get_args("SELECT 1")

      assert.are.equal("-hlocalhost", args[1])
      assert.are.equal("-P3306", args[2])
    end)

    it("should always include --batch flag", function()
      local args = adapter:get_args("SELECT 1")

      local has_batch = false
      for _, arg in ipairs(args) do
        if arg == "--batch" then
          has_batch = true
        end
      end

      assert.is_true(has_batch)
    end)

    it("should include --skip-column-names when requested", function()
      local args = adapter:get_args("SELECT 1", { skip_column_names = true })

      local has_skip = false
      for _, arg in ipairs(args) do
        if arg == "--skip-column-names" then
          has_skip = true
        end
      end

      assert.is_true(has_skip)
    end)

    it("should not include --skip-column-names by default", function()
      local args = adapter:get_args("SELECT 1")

      local has_skip = false
      for _, arg in ipairs(args) do
        if arg == "--skip-column-names" then
          has_skip = true
        end
      end

      assert.is_false(has_skip)
    end)

    it("should handle nil opts", function()
      local args = adapter:get_args("SELECT 1", nil)
      assert.is_table(args)
    end)

    it("should override database with opts.database", function()
      local args = adapter:get_args("SELECT 1", { database = "override_db" })

      local found_override = false
      for _, arg in ipairs(args) do
        if arg == "-Doverride_db" then
          found_override = true
        end
        -- Make sure the config database is not used
        if arg == "-Dtestdb" then
          error("Should not use config database when opts.database is provided")
        end
      end

      assert.is_true(found_override)
    end)

    it("should use config database when opts.database is not provided", function()
      local args = adapter:get_args("SELECT 1", {})

      local found_config_db = false
      for _, arg in ipairs(args) do
        if arg == "-Dtestdb" then
          found_config_db = true
        end
      end

      assert.is_true(found_config_db)
    end)

    it("should properly format query argument", function()
      local query = "SELECT * FROM users WHERE id = 1"
      local args = adapter:get_args(query)

      assert.are.equal(query, args[#args])
    end)
  end)

  describe("parse_output", function()
    it("should parse tab-separated single row", function()
      local raw = "field1\tfield2\tfield3"
      local rows = adapter:parse_output(raw)

      assert.are.equal(1, #rows)
      assert.are.equal(3, #rows[1])
      assert.are.equal("field1", rows[1][1])
      assert.are.equal("field2", rows[1][2])
      assert.are.equal("field3", rows[1][3])
    end)

    it("should parse multiple rows", function()
      local raw = "id\tname\n1\tAlice\n2\tBob"
      local rows = adapter:parse_output(raw)

      assert.are.equal(3, #rows)
      assert.are.equal("id", rows[1][1])
      assert.are.equal("name", rows[1][2])
      assert.are.equal("1", rows[2][1])
      assert.are.equal("Alice", rows[2][2])
      assert.are.equal("2", rows[3][1])
      assert.are.equal("Bob", rows[3][2])
    end)

    it("should handle empty output", function()
      local raw = ""
      local rows = adapter:parse_output(raw)

      assert.are.equal(0, #rows)
    end)

    it("should handle single field rows", function()
      local raw = "value1\nvalue2\nvalue3"
      local rows = adapter:parse_output(raw)

      assert.are.equal(3, #rows)
      assert.are.equal(1, #rows[1])
      assert.are.equal("value1", rows[1][1])
      assert.are.equal("value2", rows[2][1])
      assert.are.equal("value3", rows[3][1])
    end)

    it("should handle rows with many columns", function()
      local raw = "a\tb\tc\td\te\tf\tg\th"
      local rows = adapter:parse_output(raw)

      assert.are.equal(1, #rows)
      assert.are.equal(8, #rows[1])
    end)

    it("should handle different line endings", function()
      local raw_unix = "field1\tfield2\nfield3\tfield4"
      local rows_unix = adapter:parse_output(raw_unix)

      local raw_windows = "field1\tfield2\r\nfield3\tfield4"
      local rows_windows = adapter:parse_output(raw_windows)

      assert.are.equal(2, #rows_unix)
      assert.are.equal(2, #rows_windows)
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
end)
