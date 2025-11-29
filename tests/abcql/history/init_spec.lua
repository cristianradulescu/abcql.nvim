describe("History", function()
  local History
  local original_getcwd
  local original_notify
  local test_dir

  before_each(function()
    -- Create a temporary test directory
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Mock getcwd to return our test directory (same approach as storage_spec)
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return test_dir
    end

    -- Mock vim.notify to avoid test output noise
    original_notify = vim.notify
    vim.notify = function() end

    -- Clear module caches to get fresh state
    package.loaded["abcql.history"] = nil
    package.loaded["abcql.history.init"] = nil
    package.loaded["abcql.history.storage"] = nil

    -- Load fresh instance
    History = require("abcql.history")
  end)

  after_each(function()
    -- Restore mocks
    vim.fn.getcwd = original_getcwd
    vim.notify = original_notify

    -- Clean up test directory
    vim.fn.delete(test_dir, "rf")
  end)

  describe("save", function()
    it("should save a successful query to history", function()
      local result = {
        headers = { "id", "name" },
        rows = { { "1", "Alice" }, { "2", "Bob" } },
      }

      local ok = History.save("SELECT * FROM users", "test_ds", "testdb", result, nil)

      assert.is_true(ok)
      assert.equals(1, History.count())
    end)

    it("should save a failed query to history", function()
      local ok = History.save("SELECT * FROM invalid", "test_ds", "testdb", nil, "Table not found")

      assert.is_true(ok)
      assert.equals(1, History.count())
    end)

    it("should reset position to latest after saving", function()
      local result = { headers = { "id" }, rows = { { "1" } } }

      -- Save first entry
      History.save("SELECT 1", "test_ds", "testdb", result, nil)

      -- Navigate back
      History.go_back()
      assert.is_false(History.is_at_latest())

      -- Save new entry should reset to latest
      History.save("SELECT 2", "test_ds", "testdb", result, nil)
      assert.is_true(History.is_at_latest())
    end)

    it("should handle nil database", function()
      local result = { headers = { "id" }, rows = { { "1" } } }

      local ok = History.save("SHOW DATABASES", "test_ds", nil, result, nil)

      assert.is_true(ok)
      assert.equals(1, History.count())
    end)
  end)

  describe("count", function()
    it("should return 0 for empty history", function()
      assert.equals(0, History.count())
    end)

    it("should return correct count after multiple saves", function()
      local result = { headers = { "id" }, rows = { { "1" } } }

      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)
      History.save("SELECT 3", "test_ds", "testdb", result, nil)

      assert.equals(3, History.count())
    end)
  end)

  describe("is_at_latest", function()
    it("should return true when at position 0", function()
      assert.is_true(History.is_at_latest())
    end)

    it("should return false after navigating back", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)

      History.go_back()

      assert.is_false(History.is_at_latest())
    end)
  end)

  describe("get_position", function()
    it("should return position and total count", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)

      local pos, total = History.get_position()

      assert.equals(0, pos)
      assert.equals(2, total)
    end)

    it("should update position after navigation", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)

      History.go_back()
      local pos, total = History.get_position()

      assert.equals(1, pos)
      assert.equals(2, total)
    end)
  end)

  describe("go_back", function()
    it("should return nil when history is empty", function()
      local entry = History.go_back()

      assert.is_nil(entry)
    end)

    it("should return the most recent entry on first go_back", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT * FROM users", "test_ds", "testdb", result, nil)

      local entry = History.go_back()

      assert.is_not_nil(entry)
      assert.equals("SELECT * FROM users", entry.query)
      assert.equals("test_ds", entry.datasource)
      assert.equals("testdb", entry.database)
    end)

    it("should navigate through multiple entries", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)
      History.save("SELECT 3", "test_ds", "testdb", result, nil)

      -- Collect all entries by navigating back
      local queries = {}
      for _ = 1, 3 do
        local entry = History.go_back()
        table.insert(queries, entry.query)
      end

      -- All three queries should be present (order may vary within same second)
      table.sort(queries)
      assert.equals("SELECT 1", queries[1])
      assert.equals("SELECT 2", queries[2])
      assert.equals("SELECT 3", queries[3])
    end)

    it("should return nil when at end of history", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)

      History.go_back()
      local entry = History.go_back()

      assert.is_nil(entry)
    end)
  end)

  describe("go_forward", function()
    it("should return nil and is_latest=true when already at latest", function()
      local entry, is_latest = History.go_forward()

      assert.is_nil(entry)
      assert.is_true(is_latest)
    end)

    it("should return to latest result", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)

      History.go_back()
      assert.is_false(History.is_at_latest())

      local entry, is_latest = History.go_forward()
      assert.is_nil(entry)
      assert.is_true(is_latest)
      assert.is_true(History.is_at_latest())
    end)

    it("should navigate forward through entries", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)
      History.save("SELECT 3", "test_ds", "testdb", result, nil)

      -- Go back to oldest (3 steps)
      History.go_back()
      History.go_back()
      History.go_back()

      -- Collect queries going forward
      local queries = {}
      for _ = 1, 2 do
        local entry, is_latest = History.go_forward()
        assert.is_not_nil(entry)
        assert.is_false(is_latest)
        table.insert(queries, entry.query)
      end

      -- One more forward should return to latest
      local entry3, is_latest3 = History.go_forward()
      assert.is_nil(entry3)
      assert.is_true(is_latest3)

      -- Verify we got 2 entries while navigating forward
      assert.equals(2, #queries)
    end)
  end)

  describe("current", function()
    it("should return nil when at latest", function()
      assert.is_nil(History.current())
    end)

    it("should return current entry when viewing history", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT * FROM users", "test_ds", "testdb", result, nil)

      History.go_back()

      local current = History.current()
      assert.is_not_nil(current)
      assert.equals("SELECT * FROM users", current.query)
    end)
  end)

  describe("reset_to_latest", function()
    it("should reset position to 0", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.go_back()

      assert.is_false(History.is_at_latest())

      History.reset_to_latest()

      assert.is_true(History.is_at_latest())
      assert.is_nil(History.current())
    end)
  end)

  describe("clear", function()
    it("should delete all history entries", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.save("SELECT 2", "test_ds", "testdb", result, nil)
      History.save("SELECT 3", "test_ds", "testdb", result, nil)

      assert.equals(3, History.count())

      local deleted = History.clear()

      assert.equals(3, deleted)
      assert.equals(0, History.count())
    end)

    it("should reset navigation state", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT 1", "test_ds", "testdb", result, nil)
      History.go_back()

      History.clear()

      assert.is_true(History.is_at_latest())
      assert.is_nil(History.current())
    end)
  end)

  describe("get_recent", function()
    it("should return empty array for empty history", function()
      local entries = History.get_recent()

      assert.equals(0, #entries)
    end)

    it("should return recent entries with previews", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      History.save("SELECT * FROM users WHERE id = 1", "test_ds", "testdb", result, nil)
      History.save("SELECT * FROM orders", "test_ds", "testdb", nil, "Table not found")

      local entries = History.get_recent()

      assert.equals(2, #entries)
      -- Check that one succeeded and one failed
      local success_count = 0
      local fail_count = 0
      for _, e in ipairs(entries) do
        if e.success then
          success_count = success_count + 1
        else
          fail_count = fail_count + 1
        end
      end
      assert.equals(1, success_count)
      assert.equals(1, fail_count)
    end)

    it("should truncate long query previews", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      local long_query = "SELECT " .. string.rep("column, ", 20) .. "final_column FROM some_very_long_table_name"
      History.save(long_query, "test_ds", "testdb", result, nil)

      local entries = History.get_recent()

      assert.equals(1, #entries)
      assert.is_true(#entries[1].query_preview <= 53) -- 50 chars + "..."
      assert.is_true(entries[1].query_preview:match("%.%.%.$") ~= nil)
    end)

    it("should respect limit parameter", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      for i = 1, 10 do
        History.save("SELECT " .. i, "test_ds", "testdb", result, nil)
      end

      local entries = History.get_recent(3)

      assert.equals(3, #entries)
    end)

    it("should replace newlines with spaces in preview", function()
      local result = { headers = { "id" }, rows = { { "1" } } }
      local multiline_query = "SELECT *\nFROM users\nWHERE id = 1"
      History.save(multiline_query, "test_ds", "testdb", result, nil)

      local entries = History.get_recent()

      assert.equals(1, #entries)
      assert.is_nil(entries[1].query_preview:match("\n"))
    end)
  end)
end)
