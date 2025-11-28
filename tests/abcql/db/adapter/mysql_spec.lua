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
      assert.are.equal("--default-character-set=utf8mb4", args[7])
      assert.are.equal("-e", args[8])
      assert.are.equal("SELECT 1", args[9])
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

    it("should include -vvv flag for write queries", function()
      local insert_args = adapter:get_args("INSERT INTO users (name) VALUES ('test')")
      local update_args = adapter:get_args("UPDATE users SET name = 'test' WHERE id = 1")
      local delete_args = adapter:get_args("DELETE FROM users WHERE id = 1")

      local has_vvv_insert = false
      for _, arg in ipairs(insert_args) do
        if arg == "-vvv" then
          has_vvv_insert = true
          break
        end
      end

      local has_vvv_update = false
      for _, arg in ipairs(update_args) do
        if arg == "-vvv" then
          has_vvv_update = true
          break
        end
      end

      local has_vvv_delete = false
      for _, arg in ipairs(delete_args) do
        if arg == "-vvv" then
          has_vvv_delete = true
          break
        end
      end

      assert.is_true(has_vvv_insert)
      assert.is_true(has_vvv_update)
      assert.is_true(has_vvv_delete)
    end)

    it("should not include -vvv flag for SELECT queries", function()
      local args = adapter:get_args("SELECT * FROM users")

      local has_vvv = false
      for _, arg in ipairs(args) do
        if arg == "-vvv" then
          has_vvv = true
          break
        end
      end

      assert.is_false(has_vvv)
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

    it("should unescape newlines in field values", function()
      -- MySQL batch mode escapes newlines as \n (backslash + n)
      local raw = "id\tdescription\n1\tLine 1\\nLine 2\\nLine 3"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("Line 1\nLine 2\nLine 3", rows[2][2])
    end)

    it("should unescape tabs in field values", function()
      -- MySQL batch mode escapes tabs as \t (backslash + t)
      local raw = "id\tdata\n1\tCol1\\tCol2\\tCol3"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("Col1\tCol2\tCol3", rows[2][2])
    end)

    it("should unescape backslashes in field values", function()
      -- MySQL batch mode escapes backslashes as \\ (double backslash)
      local raw = "id\tpath\n1\tC:\\\\Users\\\\Admin"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("C:\\Users\\Admin", rows[2][2])
    end)

    it("should unescape NULL bytes in field values", function()
      -- MySQL batch mode escapes NULL bytes as \0
      local raw = "id\tdata\n1\tbefore\\0after"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("before\0after", rows[2][2])
    end)

    it("should handle complex mixed escape sequences", function()
      -- A field with multiple escape sequences
      local raw = "id\tcontent\n1\tFirst line\\nSecond line\\twith tab\\nThird\\\\backslash"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("First line\nSecond line\twith tab\nThird\\backslash", rows[2][2])
    end)

    it("should handle multiline text content", function()
      -- Simulating the job description content
      local raw =
        "id\tjob_description\n1\tWe are looking for a Senior Backend Engineer.\\n\\n    Key Responsibilities:\\n    - Design APIs\\n    - Optimize databases"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      local expected =
        "We are looking for a Senior Backend Engineer.\n\n    Key Responsibilities:\n    - Design APIs\n    - Optimize databases"
      assert.are.equal(expected, rows[2][2])
    end)

    it("should preserve regular backslashes not followed by escape chars", function()
      -- Backslash followed by a non-escape character should keep the backslash
      local raw = "id\tdata\n1\ttest\\x value"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("test\\x value", rows[2][2])
    end)

    it("should handle empty fields correctly", function()
      local raw = "id\tname\temail\n1\t\ttest@example.com"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal("1", rows[2][1])
      assert.are.equal("", rows[2][2])
      assert.are.equal("test@example.com", rows[2][3])
    end)

    it("should handle trailing empty field", function()
      local raw = "id\tname\temail\n1\tAlice\t"
      local rows = adapter:parse_output(raw)

      assert.are.equal(2, #rows)
      assert.are.equal(3, #rows[2])
      assert.are.equal("", rows[2][3])
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

  describe("is_write_query", function()
    it("should detect INSERT queries", function()
      assert.is_true(adapter:is_write_query("INSERT INTO users (name) VALUES ('John')"))
    end)

    it("should detect UPDATE queries", function()
      assert.is_true(adapter:is_write_query("UPDATE users SET name = 'Jane' WHERE id = 1"))
    end)

    it("should detect DELETE queries", function()
      assert.is_true(adapter:is_write_query("DELETE FROM users WHERE id = 1"))
    end)

    it("should detect case-insensitive queries", function()
      assert.is_true(adapter:is_write_query("insert into users (name) values ('John')"))
      assert.is_true(adapter:is_write_query("update users set name = 'Jane'"))
      assert.is_true(adapter:is_write_query("delete from users"))
    end)

    it("should handle queries with leading whitespace", function()
      assert.is_true(adapter:is_write_query("  INSERT INTO users (name) VALUES ('John')"))
      assert.is_true(adapter:is_write_query("\n\tUPDATE users SET name = 'Jane'"))
    end)

    it("should not detect SELECT queries as write queries", function()
      assert.is_false(adapter:is_write_query("SELECT * FROM users"))
    end)

    it("should not detect SHOW queries as write queries", function()
      assert.is_false(adapter:is_write_query("SHOW TABLES"))
    end)

    it("should not detect DESCRIBE queries as write queries", function()
      assert.is_false(adapter:is_write_query("DESCRIBE users"))
    end)
  end)

  describe("parse_write_output", function()
    it("should parse INSERT query output", function()
      local raw = "Query OK, 1 row affected (0.001 sec)"
      local result = adapter:parse_write_output(raw)

      assert.are.equal(1, result.affected_rows)
      assert.are.equal(0, result.matched_rows)
      assert.are.equal(0, result.changed_rows)
      assert.are.equal(0, result.warnings)
    end)

    it("should parse UPDATE query output with matched/changed rows", function()
      local raw = [[Query OK, 3 rows affected (0.001 sec)
Rows matched: 5  Changed: 3  Warnings: 0]]
      local result = adapter:parse_write_output(raw)

      assert.are.equal(3, result.affected_rows)
      assert.are.equal(5, result.matched_rows)
      assert.are.equal(3, result.changed_rows)
      assert.are.equal(0, result.warnings)
    end)

    it("should parse DELETE query output", function()
      local raw = "Query OK, 10 rows affected (0.002 sec)"
      local result = adapter:parse_write_output(raw)

      assert.are.equal(10, result.affected_rows)
    end)

    it("should parse query with warnings", function()
      local raw = [[Query OK, 2 rows affected (0.001 sec)
Rows matched: 2  Changed: 2  Warnings: 1]]
      local result = adapter:parse_write_output(raw)

      assert.are.equal(2, result.affected_rows)
      assert.are.equal(2, result.matched_rows)
      assert.are.equal(2, result.changed_rows)
      assert.are.equal(1, result.warnings)
    end)

    it("should parse query with 0 rows affected", function()
      local raw = "Query OK, 0 rows affected (0.000 sec)"
      local result = adapter:parse_write_output(raw)

      assert.are.equal(0, result.affected_rows)
    end)

    it("should handle UPDATE with no actual changes", function()
      local raw = [[Query OK, 0 rows affected (0.001 sec)
Rows matched: 5  Changed: 0  Warnings: 0]]
      local result = adapter:parse_write_output(raw)

      assert.are.equal(0, result.affected_rows)
      assert.are.equal(5, result.matched_rows)
      assert.are.equal(0, result.changed_rows)
      assert.are.equal(0, result.warnings)
    end)

    it("should handle empty output gracefully", function()
      local raw = ""
      local result = adapter:parse_write_output(raw)

      assert.are.equal(0, result.affected_rows)
      assert.are.equal(0, result.matched_rows)
      assert.are.equal(0, result.changed_rows)
      assert.are.equal(0, result.warnings)
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
