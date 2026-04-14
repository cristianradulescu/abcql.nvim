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
    end)

    it("should start with empty adapters and connections", function()
      assert.are.equal(0, vim.tbl_count(registry.adapters))
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
  end)

  describe("register_datasource", function()
    local dsn_module
    local secret_module
    local original_require

    before_each(function()
      dsn_module = {
        parse_dsn = function()
          return {
            scheme = "mysql",
            host = "localhost",
            port = 3306,
            user = "user",
            password = "dsnpass",
            database = "db",
            options = {},
          }, nil
        end,
      }

      secret_module = {
        lookup = function()
          return "keyringpass", nil
        end,
      }

      original_require = _G.require
      _G.require = function(mod)
        if mod == "abcql.db.connection.dsn" then
          return dsn_module
        end
        if mod == "abcql.secret" then
          return secret_module
        end
        return original_require(mod)
      end
    end)

    after_each(function()
      _G.require = original_require
    end)

    it("uses DSN password when no secret is configured", function()
      local captured
      local MockAdapter = {
        new = function(config)
          captured = config
          return { config = config }
        end,
      }
      registry:register_adapter("mysql", MockAdapter)

      local ds, err = registry:register_datasource("dev", "mysql://user:dsnpass@localhost:3306/db", nil, nil)
      assert.is_nil(err)
      assert.is_table(ds)
      assert.are.equal("dsnpass", captured.password)
    end)

    it("uses keyring password when secret is configured", function()
      local captured
      local MockAdapter = {
        new = function(config)
          captured = config
          return { config = config }
        end,
      }
      registry:register_adapter("mysql", MockAdapter)

      local ds, err = registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, {
        service = "abcql",
        account = "prod-db-password",
      })
      assert.is_nil(err)
      assert.is_table(ds)
      assert.are.equal("keyringpass", captured.password)
    end)

    it("returns error when keyring lookup fails", function()
      secret_module.lookup = function()
        return nil, "secret lookup failed"
      end

      local MockAdapter = {
        new = function(config)
          return { config = config }
        end,
      }
      registry:register_adapter("mysql", MockAdapter)

      local ds, err = registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, {
        service = "abcql",
        account = "prod-db-password",
      })
      assert.is_nil(ds)
      assert.is_truthy(err:match("Failed to resolve keyring secret"))
    end)
  end)
end)
