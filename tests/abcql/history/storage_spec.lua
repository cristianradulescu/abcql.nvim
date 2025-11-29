local Storage = require("abcql.history.storage")

describe("History Storage", function()
  local test_dir
  local original_getcwd

  before_each(function()
    -- Create a temporary test directory
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")

    -- Mock getcwd to return our test directory
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return test_dir
    end
  end)

  after_each(function()
    -- Restore getcwd
    vim.fn.getcwd = original_getcwd

    -- Clean up test directory
    vim.fn.delete(test_dir, "rf")
  end)

  describe("get_history_dir", function()
    it("should return path in current working directory", function()
      local dir = Storage.get_history_dir()
      assert.are.equal(test_dir .. "/.abcql/query_history", dir)
    end)
  end)

  describe("ensure_dir", function()
    it("should create directory if it does not exist", function()
      local ok, err = Storage.ensure_dir()
      assert.is_true(ok)
      assert.is_nil(err)
      assert.are.equal(1, vim.fn.isdirectory(Storage.get_history_dir()))
    end)

    it("should succeed if directory already exists", function()
      Storage.ensure_dir()
      local ok, err = Storage.ensure_dir()
      assert.is_true(ok)
      assert.is_nil(err)
    end)
  end)

  describe("generate_id", function()
    it("should generate unique IDs", function()
      local id1 = Storage.generate_id()
      local id2 = Storage.generate_id()

      assert.is_string(id1)
      assert.is_string(id2)
      -- IDs should match pattern YYYYMMDD_HHMMSS_XXX
      assert.is_truthy(id1:match("^%d%d%d%d%d%d%d%d_%d%d%d%d%d%d_%d%d%d$"))
    end)
  end)

  describe("write_entry and read_entry", function()
    it("should write and read an entry", function()
      local entry = {
        id = Storage.generate_id(),
        timestamp = os.time(),
        query = "SELECT * FROM users",
        datasource = "test_db",
        database = "mydb",
        result = {
          headers = { "id", "name" },
          rows = { { 1, "Alice" }, { 2, "Bob" } },
          row_count = 2,
        },
        error = nil,
      }

      local ok, err = Storage.write_entry(entry)
      assert.is_true(ok)
      assert.is_nil(err)

      local loaded, load_err = Storage.read_entry(entry.id)
      assert.is_nil(load_err)
      assert.is_not_nil(loaded)
      assert.are.equal(entry.id, loaded.id)
      assert.are.equal(entry.query, loaded.query)
      assert.are.equal(entry.datasource, loaded.datasource)
      assert.are.equal(2, #loaded.result.rows)
    end)

    it("should handle entries with errors", function()
      local entry = {
        id = Storage.generate_id(),
        timestamp = os.time(),
        query = "SELECT * FROM nonexistent",
        datasource = "test_db",
        database = "mydb",
        result = nil,
        error = "Table does not exist",
      }

      local ok, err = Storage.write_entry(entry)
      assert.is_true(ok)
      assert.is_nil(err)

      local loaded = Storage.read_entry(entry.id)
      assert.are.equal("Table does not exist", loaded.error)
      assert.is_nil(loaded.result)
    end)

    it("should return error for non-existent entry", function()
      local loaded, err = Storage.read_entry("nonexistent_id")
      assert.is_nil(loaded)
      assert.is_not_nil(err)
    end)
  end)

  describe("list_entries", function()
    it("should return empty list when no entries exist", function()
      Storage.ensure_dir()
      local entries = Storage.list_entries()
      assert.are.equal(0, #entries)
    end)

    it("should return entries sorted newest first", function()
      local entry1 = {
        id = "20250101_100000_001",
        timestamp = os.time(),
        query = "SELECT 1",
        datasource = "test",
      }
      local entry2 = {
        id = "20250101_100001_001",
        timestamp = os.time(),
        query = "SELECT 2",
        datasource = "test",
      }
      local entry3 = {
        id = "20250101_100002_001",
        timestamp = os.time(),
        query = "SELECT 3",
        datasource = "test",
      }

      Storage.write_entry(entry1)
      Storage.write_entry(entry2)
      Storage.write_entry(entry3)

      local entries = Storage.list_entries()
      assert.are.equal(3, #entries)
      -- Newest first
      assert.are.equal("20250101_100002_001", entries[1])
      assert.are.equal("20250101_100001_001", entries[2])
      assert.are.equal("20250101_100000_001", entries[3])
    end)
  end)

  describe("delete_entry", function()
    it("should delete an existing entry", function()
      local entry = {
        id = Storage.generate_id(),
        timestamp = os.time(),
        query = "SELECT 1",
        datasource = "test",
      }

      Storage.write_entry(entry)
      assert.are.equal(1, #Storage.list_entries())

      local ok = Storage.delete_entry(entry.id)
      assert.is_true(ok)
      assert.are.equal(0, #Storage.list_entries())
    end)
  end)

  describe("prune", function()
    it("should keep only the most recent entries", function()
      for i = 1, 5 do
        local entry = {
          id = string.format("20250101_10000%d_001", i),
          timestamp = os.time(),
          query = "SELECT " .. i,
          datasource = "test",
        }
        Storage.write_entry(entry)
      end

      assert.are.equal(5, #Storage.list_entries())

      local deleted = Storage.prune(3)
      assert.are.equal(2, deleted)
      assert.are.equal(3, #Storage.list_entries())

      -- Check that newest entries are kept
      local entries = Storage.list_entries()
      assert.are.equal("20250101_100005_001", entries[1])
      assert.are.equal("20250101_100004_001", entries[2])
      assert.are.equal("20250101_100003_001", entries[3])
    end)

    it("should do nothing if under limit", function()
      local entry = {
        id = Storage.generate_id(),
        timestamp = os.time(),
        query = "SELECT 1",
        datasource = "test",
      }
      Storage.write_entry(entry)

      local deleted = Storage.prune(10)
      assert.are.equal(0, deleted)
      assert.are.equal(1, #Storage.list_entries())
    end)
  end)

  describe("clear_all", function()
    it("should delete all entries", function()
      for i = 1, 3 do
        local entry = {
          id = Storage.generate_id(),
          timestamp = os.time(),
          query = "SELECT " .. i,
          datasource = "test",
        }
        Storage.write_entry(entry)
      end

      assert.are.equal(3, #Storage.list_entries())

      local deleted = Storage.clear_all()
      assert.are.equal(3, deleted)
      assert.are.equal(0, #Storage.list_entries())
    end)
  end)
end)
