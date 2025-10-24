local Registry = require("abcql.db.connection.registry")

describe("ConnectionRegistry", function()
  local registry

  before_each(function()
    registry = Registry.new()
  end)

  describe("new", function()
    it("should create a new registry instance", function()
      assert.is_not_nil(registry)
      assert.is_table(registry.adapters)
      assert.is_table(registry.connections)
    end)

    it("should start with empty adapters and connections", function()
      assert.are.equal(0, vim.tbl_count(registry.adapters))
      assert.are.equal(0, vim.tbl_count(registry.connections))
    end)
  end)

  describe("register_adapter", function()
    local MockAdapter = {
      new = function()
        return {}
      end,
    }

    it("should register an adapter for a scheme", function()
      registry:register_adapter("mysql", MockAdapter)
      assert.are.equal(MockAdapter, registry.adapters.mysql)
    end)

    it("should handle case-insensitive scheme registration", function()
      registry:register_adapter("MySQL", MockAdapter)
      assert.are.equal(MockAdapter, registry.adapters.mysql)
    end)

    it("should allow multiple adapters for different schemes", function()
      local AnotherAdapter = { new = function() end }
      registry:register_adapter("mysql", MockAdapter)
      registry:register_adapter("postgres", AnotherAdapter)

      assert.are.equal(MockAdapter, registry.adapters.mysql)
      assert.are.equal(AnotherAdapter, registry.adapters.postgres)
    end)
  end)

  describe("get_schemes", function()
    it("should return empty list when no adapters registered", function()
      local schemes = registry:get_schemes()
      assert.are.equal(0, #schemes)
    end)

    it("should return list of registered schemes", function()
      local MockAdapter = { new = function() end }
      registry:register_adapter("mysql", MockAdapter)
      registry:register_adapter("postgres", MockAdapter)

      local schemes = registry:get_schemes()
      table.sort(schemes)

      assert.are.equal(2, #schemes)
      assert.are.equal("mysql", schemes[1])
      assert.are.equal("postgres", schemes[2])
    end)

    it("should return sorted list of schemes", function()
      local MockAdapter = { new = function() end }
      registry:register_adapter("sqlite", MockAdapter)
      registry:register_adapter("mysql", MockAdapter)
      registry:register_adapter("postgres", MockAdapter)

      local schemes = registry:get_schemes()

      assert.are.equal("mysql", schemes[1])
      assert.are.equal("postgres", schemes[2])
      assert.are.equal("sqlite", schemes[3])
    end)
  end)

  describe("parse_dsn", function()
    it("should parse valid MySQL DSN with all components", function()
      local dsn = "mysql://user:password@localhost:3306/mydb"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.is_not_nil(parsed)
      assert.are.equal("mysql", parsed.scheme)
      assert.are.equal("user", parsed.user)
      assert.are.equal("password", parsed.password)
      assert.are.equal("localhost", parsed.host)
      assert.are.equal(3306, parsed.port)
      assert.are.equal("mydb", parsed.database)
    end)

    it("should parse DSN without password", function()
      local dsn = "mysql://user@localhost:3306/mydb"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("user", parsed.user)
      assert.is_nil(parsed.password)
    end)

    it("should parse DSN without port", function()
      local dsn = "mysql://user:password@localhost/mydb"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("localhost", parsed.host)
      assert.is_nil(parsed.port)
    end)

    it("should parse DSN without database", function()
      local dsn = "mysql://user:password@localhost:3306"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.is_nil(parsed.database)
    end)

    it("should parse DSN with query string options", function()
      local dsn = "mysql://user:password@localhost:3306/mydb?timeout=30&charset=utf8"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("30", parsed.options.timeout)
      assert.are.equal("utf8", parsed.options.charset)
    end)

    it("should handle invalid DSN format", function()
      local dsn = "not-a-valid-dsn"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(parsed)
      assert.is_not_nil(err)
      assert.matches("Invalid DSN format", err)
    end)

    it("should handle empty DSN", function()
      local dsn = ""
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(parsed)
      assert.is_not_nil(err)
    end)

    it("should normalize scheme to lowercase", function()
      local dsn = "MySQL://user:password@localhost:3306/mydb"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("mysql", parsed.scheme)
    end)

    it("should parse PostgreSQL DSN", function()
      local dsn = "postgres://pguser:pgpass@pghost:5432/pgdb"
      local parsed, err = registry:parse_dsn(dsn)

      assert.is_nil(err)
      assert.are.equal("postgres", parsed.scheme)
      assert.are.equal("pguser", parsed.user)
      assert.are.equal("pgpass", parsed.password)
      assert.are.equal("pghost", parsed.host)
      assert.are.equal(5432, parsed.port)
      assert.are.equal("pgdb", parsed.database)
    end)
  end)

  describe("get_connection", function()
    local MockAdapter
    local mock_instance

    before_each(function()
      mock_instance = { config = {} }
      MockAdapter = {
        new = function(config)
          mock_instance.config = config
          return mock_instance
        end,
      }
      registry:register_adapter("mysql", MockAdapter)
    end)

    it("should create new connection from valid DSN", function()
      local dsn = "mysql://user:password@localhost:3306/mydb"
      local adapter, err = registry:get_connection(dsn)

      assert.is_nil(err)
      assert.are.equal(mock_instance, adapter)
      assert.are.equal("localhost", adapter.config.host)
      assert.are.equal(3306, adapter.config.port)
      assert.are.equal("user", adapter.config.user)
      assert.are.equal("password", adapter.config.password)
      assert.are.equal("mydb", adapter.config.database)
    end)

    it("should cache and reuse connections for same DSN", function()
      local dsn = "mysql://user:password@localhost:3306/mydb"

      local adapter1, _ = registry:get_connection(dsn)
      local adapter2, _ = registry:get_connection(dsn)

      assert.are.equal(adapter1, adapter2)
    end)

    it("should return error for unregistered scheme", function()
      local dsn = "postgres://user:password@localhost:5432/mydb"
      local adapter, err = registry:get_connection(dsn)

      assert.is_nil(adapter)
      assert.is_not_nil(err)
      assert.matches("No adapter registered for scheme", err)
    end)

    it("should return error for invalid DSN", function()
      local dsn = "invalid-dsn-format"
      local adapter, err = registry:get_connection(dsn)

      assert.is_nil(adapter)
      assert.is_not_nil(err)
      assert.matches("Invalid DSN format", err)
    end)

    it("should create separate connections for different DSNs", function()
      local dsn1 = "mysql://user1:pass1@host1:3306/db1"
      local dsn2 = "mysql://user2:pass2@host2:3307/db2"

      local mock_instance1 = { config = {} }
      local mock_instance2 = { config = {} }
      local call_count = 0

      MockAdapter.new = function(config)
        call_count = call_count + 1
        if call_count == 1 then
          mock_instance1.config = config
          return mock_instance1
        else
          mock_instance2.config = config
          return mock_instance2
        end
      end

      local adapter1, _ = registry:get_connection(dsn1)
      local adapter2, _ = registry:get_connection(dsn2)

      assert.are_not.equal(adapter1, adapter2)
      assert.are.equal("host1", adapter1.config.host)
      assert.are.equal("host2", adapter2.config.host)
    end)
  end)
end)
