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
          },
            nil
        end,
      }

      secret_module = {
        calls = 0,
        lookup = function()
          secret_module.calls = secret_module.calls + 1
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

    local Adapter = require("abcql.db.adapter.base")
    local RealAdapter = {
      new = function(config)
        return Adapter.new(config)
      end,
    }
    local ref = { service = "abcql", account = "prod-db-password" }

    it("does not look the keyring secret up at registration", function()
      local captured
      local MockAdapter = {
        new = function(config)
          captured = config
          return { config = config }
        end,
      }
      registry:register_adapter("mysql", MockAdapter)

      local ds, err = registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref)
      assert.is_nil(err)
      assert.is_table(ds)
      assert.are.equal(0, secret_module.calls)
      assert.is_nil(captured.password)
      assert.are.same(ref, captured.secret)
    end)

    it("looks the keyring password up when the first request is built, then reuses it", function()
      registry:register_adapter("mysql", RealAdapter)
      local ds = assert(registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref))
      assert.are.equal(0, secret_module.calls)

      local request, err = ds.adapter:build_backend_request("SELECT 1", {})
      assert.is_nil(err)
      assert.are.equal("keyringpass", request.password)
      assert.are.equal(1, secret_module.calls)

      request = ds.adapter:build_backend_request("SELECT 2", {})
      assert.are.equal("keyringpass", request.password)
      assert.are.equal(1, secret_module.calls)
    end)

    it("prefers the keyring secret over a DSN password", function()
      registry:register_adapter("mysql", RealAdapter)
      local ds = assert(registry:register_datasource("prod", "mysql://user:dsnpass@localhost:3306/db", nil, ref))
      assert.are.equal("keyringpass", ds.adapter:build_backend_request("SELECT 1", {}).password)
    end)

    it("keeps the datasource when the lookup fails and reports it as the query's error", function()
      local fail = true
      secret_module.lookup = function()
        secret_module.calls = secret_module.calls + 1
        if fail then
          return nil, "secret lookup failed"
        end
        return "keyringpass", nil
      end
      registry:register_adapter("mysql", RealAdapter)

      local ds, reg_err = registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref)
      assert.is_nil(reg_err)
      assert.is_table(ds)
      assert.are.equal(ds, registry:get_datasource("prod"))

      local request, err = ds.adapter:build_backend_request("SELECT 1", {})
      assert.is_nil(request)
      assert.is_truthy(err:match("Failed to resolve keyring secret: secret lookup failed"))

      -- not cached: the next query retries
      fail = false
      request = ds.adapter:build_backend_request("SELECT 1", {})
      assert.are.equal("keyringpass", request.password)
      assert.are.equal(2, secret_module.calls)
    end)

    it("surfaces a failed lookup through Query.execute_async without starting the backend", function()
      secret_module.lookup = function()
        return nil, "secret-tool lookup timed out after 20s"
      end
      registry:register_adapter("mysql", RealAdapter)
      local ds = assert(registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref))

      local Backend = require("abcql.backend")
      local original_invoke = Backend.invoke
      local invoked = false
      Backend.invoke = function()
        invoked = true
      end
      local got_err
      local handle = require("abcql.db.query").execute_async(ds.adapter, "SELECT 1", function(_, err)
        got_err = err
      end)
      Backend.invoke = original_invoke

      assert.is_nil(handle)
      assert.is_false(invoked)
      assert.is_truthy(got_err:match("timed out"))
    end)

    it("looks the secret up again after a reload (a fresh registry)", function()
      registry:register_adapter("mysql", RealAdapter)
      local ds = assert(registry:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref))
      ds.adapter:build_backend_request("SELECT 1", {})
      assert.are.equal(1, secret_module.calls)

      local reloaded = Registry.new()
      reloaded:register_adapter("mysql", RealAdapter)
      local fresh = assert(reloaded:register_datasource("prod", "mysql://user@localhost:3306/db", nil, ref))
      assert.is_nil(fresh.adapter.config.password)
      fresh.adapter:build_backend_request("SELECT 1", {})
      assert.are.equal(2, secret_module.calls)
    end)
  end)
end)

describe("ConnectionRegistry datasource flags", function()
  local MockAdapter = {
    new = function(config)
      return { config = config }
    end,
  }

  it("defaults readonly to false and leaves confirm/highlight unset", function()
    local registry = Registry.new()
    registry:register_adapter("mysql", MockAdapter)
    local ds = registry:register_datasource("dev", "mysql://u:p@localhost:3306/db")
    assert.is_false(ds.readonly)
    assert.is_nil(ds.confirm)
    assert.is_nil(ds.highlight)
  end)

  it("stores readonly, confirm and highlight from opts", function()
    local registry = Registry.new()
    registry:register_adapter("mysql", MockAdapter)
    local ds = registry:register_datasource("prod", "mysql://u:p@localhost:3306/db", nil, nil, {
      readonly = true,
      confirm = "always",
      highlight = "DiagnosticError",
    })
    assert.is_true(ds.readonly)
    assert.are.equal("always", ds.confirm)
    assert.are.equal("DiagnosticError", ds.highlight)
  end)
end)

describe("ConnectionRegistry sqlite datasources", function()
  it("passes the database file path to the adapter", function()
    local registry = Registry.new()
    registry:register_adapter("sqlite", require("abcql.db.adapter.sqlite"))
    local datasource, err = registry:register_datasource("local", "sqlite:///tmp/app.db")

    assert.is_nil(err)
    assert.are.equal("/tmp/app.db", datasource.adapter.config.path)
    assert.are.equal("main", datasource.adapter.config.database)
    assert.are.equal("sqlite", datasource.adapter:build_backend_request("SELECT 1").engine)
  end)
end)
