local Adapter = require("abcql.db.adapter.base")

describe("BaseAdapter", function()
  local adapter

  before_each(function()
    adapter = Adapter.new({ host = "localhost", port = 3306 })
  end)

  describe("new", function()
    it("should create a new adapter instance", function()
      assert.is_not_nil(adapter)
      assert.is_table(adapter.config)
    end)

    it("should store config", function()
      assert.are.equal("localhost", adapter.config.host)
      assert.are.equal(3306, adapter.config.port)
    end)

    it("should handle nil config", function()
      local adapter_no_config = Adapter.new()
      assert.is_not_nil(adapter_no_config)
      assert.is_table(adapter_no_config.config)
    end)

    it("should handle empty config", function()
      local adapter_empty = Adapter.new({})
      assert.is_not_nil(adapter_empty)
      assert.is_table(adapter_empty.config)
    end)
  end)

  describe("abstract methods", function()
    it("execute_query should throw error", function()
      assert.has_error(function()
        adapter:execute_query("SELECT 1", nil, function() end)
      end, "execute_query must be implemented by adapter")
    end)

    it("get_databases should throw error", function()
      assert.has_error(function()
        adapter:get_databases(function() end)
      end, "get_databases must be implemented by adapter")
    end)

    it("get_tables should throw error", function()
      assert.has_error(function()
        adapter:get_tables("mydb", function() end)
      end, "get_tables must be implemented by adapter")
    end)

    it("get_columns should throw error", function()
      assert.has_error(function()
        adapter:get_columns("mydb", "mytable", function() end)
      end, "get_columns must be implemented by adapter")
    end)

    it("get_constraints should throw error", function()
      assert.has_error(function()
        adapter:get_constraints("mydb", "mytable", function() end)
      end, "get_constraints must be implemented by adapter")
    end)

    it("get_indexes should throw error", function()
      assert.has_error(function()
        adapter:get_indexes("mydb", "mytable", function() end)
      end, "get_indexes must be implemented by adapter")
    end)
  end)

  describe("default implementations", function()
    describe("escape_identifier", function()
      it("should return unmodified identifier", function()
        local result = adapter:escape_identifier("table_name")
        assert.are.equal("table_name", result)
      end)

      it("should not escape special characters by default", function()
        local result = adapter:escape_identifier("table-with-dashes")
        assert.are.equal("table-with-dashes", result)
      end)
    end)

    describe("escape_value", function()
      it("should return unmodified value", function()
        local result = adapter:escape_value("some value")
        assert.are.equal("some value", result)
      end)

      it("should not escape quotes by default", function()
        local result = adapter:escape_value("value with 'quotes'")
        assert.are.equal("value with 'quotes'", result)
      end)
    end)
  end)

  describe("build_backend_request", function()
    it("should build a request from config fields", function()
      local a = Adapter.new({
        host = "db.internal",
        port = 3307,
        user = "alice",
        password = "s3cret",
        database = "shop",
      })

      local request = a:build_backend_request("SELECT 1", {})

      assert.are.equal("mysql", request.engine)
      assert.are.equal("db.internal", request.host)
      assert.are.equal(3307, request.port)
      assert.are.equal("alice", request.user)
      assert.are.equal("s3cret", request.password)
      assert.are.equal("shop", request.database)
      assert.are.equal("SELECT 1", request.sql)
    end)

    it("should use self.ENGINE when set", function()
      local a = Adapter.new({})
      a.ENGINE = "postgres"

      local request = a:build_backend_request("SELECT 1", {})

      assert.are.equal("postgres", request.engine)
    end)

    it("should override database with opts.database", function()
      local a = Adapter.new({ database = "configured_db" })

      local request = a:build_backend_request("SELECT 1", { database = "opts_db" })

      assert.are.equal("opts_db", request.database)
    end)

    it("should forward opts.timeout as timeout_ms", function()
      local a = Adapter.new({})

      local request = a:build_backend_request("SELECT 1", { timeout = 5000 })

      assert.are.equal(5000, request.timeout_ms)
    end)

    it("should not set proxy when config has none", function()
      local a = Adapter.new({})

      local request = a:build_backend_request("SELECT 1", {})

      assert.is_nil(request.proxy)
    end)

    it("should parse a valid proxy URL into request.proxy", function()
      local a = Adapter.new({ proxy = "socks5://127.0.0.1:1080" })

      local request = a:build_backend_request("SELECT 1", {})

      assert.are.same({ type = "socks5", host = "127.0.0.1", port = 1080 }, request.proxy)
    end)

    it("should notify and omit proxy on an invalid proxy URL", function()
      local original_notify = vim.notify
      local notified = false
      vim.notify = function()
        notified = true
      end

      local a = Adapter.new({ proxy = "not-a-proxy-url" })
      local request = a:build_backend_request("SELECT 1", {})

      vim.notify = original_notify

      assert.is_true(notified)
      assert.is_nil(request.proxy)
    end)
  end)
end)
