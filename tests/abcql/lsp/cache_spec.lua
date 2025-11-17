local Cache = require("abcql.lsp.cache")

describe("Cache", function()
  local cache

  before_each(function()
    cache = Cache.new()
  end)

  describe("new", function()
    it("should create a new cache instance", function()
      assert.is_not_nil(cache)
      assert.is_table(cache.caches)
    end)

    it("should start with empty caches", function()
      assert.are.same({}, cache.caches)
    end)
  end)

  describe("has_cache", function()
    it("should return false for non-existent datasource", function()
      assert.is_false(cache:has_cache("test_ds"))
    end)

    it("should return true after loading schema", function()
      -- Create a minimal mock adapter
      local mock_adapter = {
        get_databases = function(_, callback)
          callback({}, nil)
        end,
      }

      cache:load_schema("test_ds", mock_adapter, function() end)
      assert.is_true(cache:has_cache("test_ds"))
    end)
  end)

  describe("get_databases", function()
    it("should return nil for non-existent datasource", function()
      local result = cache:get_databases("test_ds")
      assert.is_nil(result)
    end)

    it("should return databases after loading", function()
      local mock_adapter = {
        get_databases = function(_, callback)
          callback({ "db1", "db2" }, nil)
        end,
      }

      cache:load_schema("test_ds", mock_adapter, function()
        local databases = cache:get_databases("test_ds")
        assert.are.same({ "db1", "db2" }, databases)
      end)
    end)
  end)

  describe("get_tables", function()
    it("should return nil for non-existent datasource", function()
      local result = cache:get_tables("test_ds", "db1")
      assert.is_nil(result)
    end)

    it("should return nil for non-existent database", function()
      cache.caches["test_ds"] = {
        databases = {},
        tables = {},
        columns = {},
        metadata = { loaded_at = os.time() },
      }

      local result = cache:get_tables("test_ds", "db1")
      assert.is_nil(result)
    end)
  end)

  describe("get_columns", function()
    it("should return nil for non-existent datasource", function()
      local result = cache:get_columns("test_ds", "db1", "table1")
      assert.is_nil(result)
    end)

    it("should return nil for non-existent table", function()
      cache.caches["test_ds"] = {
        databases = {},
        tables = {},
        columns = {},
        metadata = { loaded_at = os.time() },
      }

      local result = cache:get_columns("test_ds", "db1", "table1")
      assert.is_nil(result)
    end)
  end)

  describe("clear", function()
    it("should clear cache for a datasource", function()
      cache.caches["test_ds"] = {
        databases = {},
        tables = {},
        columns = {},
        metadata = { loaded_at = os.time() },
      }

      cache:clear("test_ds")
      assert.is_false(cache:has_cache("test_ds"))
    end)

    it("should not affect other datasource caches", function()
      cache.caches["test_ds1"] = {
        databases = {},
        tables = {},
        columns = {},
        metadata = { loaded_at = os.time() },
      }
      cache.caches["test_ds2"] = {
        databases = {},
        tables = {},
        columns = {},
        metadata = { loaded_at = os.time() },
      }

      cache:clear("test_ds1")
      assert.is_false(cache:has_cache("test_ds1"))
      assert.is_true(cache:has_cache("test_ds2"))
    end)
  end)

  describe("get_metadata", function()
    it("should return nil for non-existent datasource", function()
      local result = cache:get_metadata("test_ds")
      assert.is_nil(result)
    end)

    it("should return metadata after loading", function()
      local mock_adapter = {
        get_databases = function(_, callback)
          callback({}, nil)
        end,
      }

      cache:load_schema("test_ds", mock_adapter, function()
        local metadata = cache:get_metadata("test_ds")
        assert.is_not_nil(metadata)
        assert.is_not_nil(metadata.loaded_at)
        assert.is_true(metadata.loaded_at > 0)
      end)
    end)
  end)

  describe("load_schema", function()
    it("should handle empty databases list", function()
      local mock_adapter = {
        get_databases = function(_, callback)
          callback({}, nil)
        end,
      }

      local callback_called = false
      cache:load_schema("test_ds", mock_adapter, function(err)
        callback_called = true
        assert.is_nil(err)
      end)

      assert.is_true(callback_called)
    end)

    it("should handle database loading error", function()
      local mock_adapter = {
        get_databases = function(_, callback)
          callback(nil, "Connection failed")
        end,
      }

      local callback_called = false
      cache:load_schema("test_ds", mock_adapter, function(err)
        callback_called = true
        assert.is_not_nil(err)
        assert.is_true(err:find("Failed to load databases") ~= nil)
      end)

      assert.is_true(callback_called)
    end)
  end)
end)
