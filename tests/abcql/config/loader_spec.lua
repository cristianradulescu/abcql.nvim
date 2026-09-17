describe("Config Loader", function()
  local Loader
  local original_notify
  local original_getenv

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end

    original_getenv = os.getenv

    package.loaded["abcql.config.loader"] = nil
    Loader = require("abcql.config.loader")
  end)

  after_each(function()
    vim.notify = original_notify
    os.getenv = original_getenv
  end)

  describe("expand_env_vars", function()
    it("should expand environment variables", function()
      os.getenv = function(name)
        if name == "TEST_VAR" then
          return "test_value"
        end
        return nil
      end

      local result = Loader.expand_env_vars("prefix_${TEST_VAR}_suffix")
      assert.are.equal("prefix_test_value_suffix", result)
    end)

    it("should expand multiple environment variables", function()
      os.getenv = function(name)
        if name == "USER" then
          return "testuser"
        end
        if name == "PASS" then
          return "testpass"
        end
        return nil
      end

      local result = Loader.expand_env_vars("mysql://${USER}:${PASS}@localhost:3306/db")
      assert.are.equal("mysql://testuser:testpass@localhost:3306/db", result)
    end)

    it("should leave unset variables unchanged and warn", function()
      local warned = false
      vim.notify = function(msg, level)
        if msg:match("UNSET_VAR") and level == vim.log.levels.WARN then
          warned = true
        end
      end

      os.getenv = function()
        return nil
      end

      local result = Loader.expand_env_vars("${UNSET_VAR}")
      assert.are.equal("${UNSET_VAR}", result)
      assert.is_true(warned)
    end)

    it("should return non-string values unchanged", function()
      assert.are.equal(123, Loader.expand_env_vars(123))
      assert.is_nil(Loader.expand_env_vars(nil))
    end)

    it("should handle strings without variables", function()
      local result = Loader.expand_env_vars("mysql://user:pass@localhost:3306/db")
      assert.are.equal("mysql://user:pass@localhost:3306/db", result)
    end)

    it("should handle empty strings", function()
      local result = Loader.expand_env_vars("")
      assert.are.equal("", result)
    end)

    it("should handle entire DSN as environment variable", function()
      os.getenv = function(name)
        if name == "DATABASE_URL" then
          return "mysql://user:pass@localhost:3306/db"
        end
        return nil
      end

      local result = Loader.expand_env_vars("${DATABASE_URL}")
      assert.are.equal("mysql://user:pass@localhost:3306/db", result)
    end)
  end)

  describe("load_config_file", function()
    it("should return nil for non-existent files", function()
      local config, err = Loader.load_config_file("/non/existent/path.lua")
      assert.is_nil(config)
      assert.is_nil(err)
    end)
  end)

  describe("get_local_config_path", function()
    it("should return path in current working directory", function()
      local path = Loader.get_local_config_path()
      assert.is_true(path:match("%.abcql%.lua$") ~= nil)
      assert.is_true(path:match("^/") ~= nil) -- absolute path
    end)
  end)

  describe("get_dsn_map", function()
    it("should extract DSN strings from loaded datasources", function()
      local loaded = {
        dev = { dsn = "mysql://dev@localhost/db", source = "local" },
        prod = { dsn = "mysql://prod@localhost/db", source = "user" },
      }

      local result = Loader.get_dsn_map(loaded)

      assert.are.equal("mysql://dev@localhost/db", result.dev)
      assert.are.equal("mysql://prod@localhost/db", result.prod)
    end)

    it("should return empty table for empty input", function()
      local result = Loader.get_dsn_map({})
      assert.are.equal(0, vim.tbl_count(result))
    end)
  end)

  describe("get_datasource_configs", function()
    it("should include secret metadata when present", function()
      local loaded = {
        prod = {
          dsn = "mysql://user@localhost/db",
          proxy = "socks5://127.0.0.1:1080",
          secret = { service = "abcql", account = "prod-db-password" },
          source = "local",
        },
      }

      local result = Loader.get_datasource_configs(loaded)

      assert.are.equal("mysql://user@localhost/db", result.prod.dsn)
      assert.are.equal("socks5://127.0.0.1:1080", result.prod.proxy)
      assert.is_table(result.prod.secret)
      assert.are.equal("abcql", result.prod.secret.service)
      assert.are.equal("prod-db-password", result.prod.secret.account)
    end)
  end)

  describe("load_all_datasources", function()
    it("should include setup datasources", function()
      local setup_ds = {
        test = "mysql://user:pass@localhost:3306/test",
      }

      local result = Loader.load_all_datasources(setup_ds)

      assert.is_not_nil(result.test)
      assert.are.equal("mysql://user:pass@localhost:3306/test", result.test.dsn)
      assert.are.equal("config", result.test.source)
    end)

    it("should expand env vars in setup datasources", function()
      os.getenv = function(name)
        if name == "DB_PASS" then
          return "secret"
        end
        return nil
      end

      local setup_ds = {
        test = "mysql://user:${DB_PASS}@localhost:3306/test",
      }

      local result = Loader.load_all_datasources(setup_ds)

      assert.are.equal("mysql://user:secret@localhost:3306/test", result.test.dsn)
    end)

    it("should handle nil setup datasources", function()
      local result = Loader.load_all_datasources(nil)
      assert.is_table(result)
    end)

    it("should preserve secret metadata in table datasource", function()
      local setup_ds = {
        prod = {
          dsn = "mysql://user@localhost:3306/test",
          secret = {
            service = "abcql",
            account = "prod-password",
          },
        },
      }

      local result = Loader.load_all_datasources(setup_ds)

      assert.are.equal("mysql://user@localhost:3306/test", result.prod.dsn)
      assert.is_table(result.prod.secret)
      assert.are.equal("abcql", result.prod.secret.service)
      assert.are.equal("prod-password", result.prod.secret.account)
    end)
  end)

  describe("datasource flags and default", function()
    it("carries readonly/confirm/highlight through to datasource configs", function()
      local loaded = Loader.load_all_datasources({
        prod = {
          dsn = "mysql://user:pass@host:3306/db",
          readonly = true,
          confirm = "always",
          highlight = "DiagnosticError",
        },
        dev = "mysql://user:pass@localhost:3306/db",
      })
      assert.is_true(loaded.prod.readonly)
      assert.are.equal("always", loaded.prod.confirm)
      assert.are.equal("DiagnosticError", loaded.prod.highlight)
      assert.is_nil(loaded.dev.readonly)

      local configs = Loader.get_datasource_configs(loaded)
      assert.is_true(configs.prod.readonly)
      assert.are.equal("always", configs.prod.confirm)
      assert.are.equal("DiagnosticError", configs.prod.highlight)
    end)

    it("returns the setup default when it names a configured datasource", function()
      local _, default = Loader.load_all_datasources({ dev = "mysql://user:pass@localhost:3306/db" }, "dev")
      assert.are.equal("dev", default)
    end)

    it("drops a default that is not configured", function()
      local warned = false
      vim.notify = function(msg)
        if msg:match("default datasource") then
          warned = true
        end
      end
      local _, default = Loader.load_all_datasources({ dev = "mysql://user:pass@localhost:3306/db" }, "nope")
      assert.is_nil(default)
      assert.is_true(warned)
    end)
  end)

  describe("CONFIG_TEMPLATE", function()
    it("should contain example datasource format", function()
      assert.is_true(Loader.CONFIG_TEMPLATE:match("datasources") ~= nil)
      assert.is_true(Loader.CONFIG_TEMPLATE:match("return") ~= nil)
    end)

    it("should contain environment variable documentation", function()
      assert.is_true(Loader.CONFIG_TEMPLATE:match("%${") ~= nil)
    end)
  end)

  describe("has_local_config", function()
    it("should return false when no local config exists", function()
      -- Save original function
      local orig_get_local = Loader.get_local_config_path

      -- Mock to return a non-existent path
      Loader.get_local_config_path = function()
        return "/tmp/non_existent_abcql_test/.abcql.lua"
      end

      local result = Loader.has_local_config()
      assert.is_false(result)

      -- Restore
      Loader.get_local_config_path = orig_get_local
    end)
  end)

  describe("has_user_config", function()
    it("should check user config path", function()
      -- This will likely return false in test environment
      local result = Loader.has_user_config()
      assert.is_boolean(result)
    end)
  end)
end)

describe("Config Loader add_datasource_to_file", function()
  local Loader
  local dir
  local original_notify

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end
    package.loaded["abcql.config.loader"] = nil
    Loader = require("abcql.config.loader")
    Loader.TRUST_WRITTEN_FILES = false
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.delete(dir, "rf")
  end)

  local function read(path)
    local f = assert(io.open(path, "r"))
    local content = f:read("*a")
    f:close()
    return content
  end

  it("creates the file from the template and inserts a string entry", function()
    local path = dir .. "/.abcql.lua"
    local ok, err = Loader.add_datasource_to_file(path, "dev", { dsn = "mysql://u:p@localhost:3306/db" })
    assert.is_true(ok, err)
    local content = read(path)
    assert.is_not_nil(content:find('    dev = "mysql://u:p@localhost:3306/db",', 1, true))

    local config = dofile(path)
    assert.are.equal("mysql://u:p@localhost:3306/db", config.datasources.dev)
  end)

  it("writes a table entry when flags are set and keeps existing entries", function()
    local path = dir .. "/.abcql.lua"
    assert.is_true(Loader.add_datasource_to_file(path, "dev", { dsn = "mysql://u:p@localhost:3306/db" }))
    local ok = Loader.add_datasource_to_file(path, "prod", {
      dsn = "mysql://u@db:3306/app",
      proxy = "socks5://127.0.0.1:1080",
      readonly = true,
      confirm = "always",
      highlight = "DiagnosticError",
    })
    assert.is_true(ok)

    local config = dofile(path)
    assert.are.equal("mysql://u:p@localhost:3306/db", config.datasources.dev)
    assert.are.equal("mysql://u@db:3306/app", config.datasources.prod.dsn)
    assert.are.equal("socks5://127.0.0.1:1080", config.datasources.prod.proxy)
    assert.is_true(config.datasources.prod.readonly)
    assert.are.equal("always", config.datasources.prod.confirm)
    assert.are.equal("DiagnosticError", config.datasources.prod.highlight)
  end)

  it("writes a secret reference and a password-less DSN", function()
    local path = dir .. "/.abcql.lua"
    local ok = Loader.add_datasource_to_file(path, "prod", {
      dsn = "mysql://u@db:3306/app",
      secret = { service = "abcql", account = "prod-db-password" },
    })
    assert.is_true(ok)
    local config = dofile(path)
    assert.are.equal("mysql://u@db:3306/app", config.datasources.prod.dsn)
    assert.are.same({ service = "abcql", account = "prod-db-password" }, config.datasources.prod.secret)
  end)

  it("strip_dsn_password removes only the password component", function()
    assert.are.equal("mysql://u@db:3306/app", Loader.strip_dsn_password("mysql://u:p%40ss@db:3306/app"))
    assert.are.equal("mysql://u@db:3306/app", Loader.strip_dsn_password("mysql://u@db:3306/app"))
    assert.are.equal("mysql://u@db/app?x=1", Loader.strip_dsn_password("mysql://u:p@db/app?x=1"))
  end)

  it("quotes names that are not valid identifiers", function()
    local path = dir .. "/.abcql.lua"
    assert.is_true(Loader.add_datasource_to_file(path, "my-app.dev", { dsn = "mysql://u@h/db" }))
    assert.are.equal("mysql://u@h/db", dofile(path).datasources["my-app.dev"])
  end)

  it("rejects duplicates, bad names and bad DSNs", function()
    local path = dir .. "/.abcql.lua"
    assert.is_true(Loader.add_datasource_to_file(path, "dev", { dsn = "mysql://u@h/db" }))
    local ok, err = Loader.add_datasource_to_file(path, "dev", { dsn = "mysql://u@h/db2" })
    assert.is_false(ok)
    assert.is_not_nil(err:find("already exists", 1, true))

    ok, err = Loader.add_datasource_to_file(path, "bad name", { dsn = "mysql://u@h/db" })
    assert.is_false(ok)
    assert.is_not_nil(err:find("Invalid datasource name", 1, true))

    ok = Loader.add_datasource_to_file(path, "other", { dsn = "not a dsn" })
    assert.is_false(ok)
  end)

  it("preserves comments and other content in an existing file", function()
    local path = dir .. "/.abcql.lua"
    local f = assert(io.open(path, "w"))
    f:write('-- keep me\nreturn {\n  default = "dev",\n  datasources = {\n    dev = "mysql://u@h/db",\n  },\n}\n')
    f:close()
    assert.is_true(Loader.add_datasource_to_file(path, "test", { dsn = "mysql://u@h/test" }))
    local content = read(path)
    assert.is_not_nil(content:find("-- keep me", 1, true))
    local config = dofile(path)
    assert.are.equal("dev", config.default)
    assert.are.equal("mysql://u@h/test", config.datasources.test)
  end)

  it("set_dsn_password inserts or replaces the password", function()
    assert.are.equal("mysql://u:new@h/db", Loader.set_dsn_password("mysql://u@h/db", "new"))
    assert.are.equal("mysql://u:new@h/db", Loader.set_dsn_password("mysql://u:old@h/db", "new"))
    assert.are.equal("mysql://u:p%w@h/db", Loader.set_dsn_password("mysql://u@h/db", "p%w"))
  end)

  it("find_datasource_entry locates string and table entries", function()
    local lines = {
      "return {",
      "  datasources = {",
      '    dev = "mysql://u@h/db",',
      "    prod = {",
      '      dsn = "mysql://u@h/app",',
      '      secret = { service = "abcql", account = "x" },',
      "    },",
      '    ["my-app"] = "mysql://u@h/other",',
      "  },",
      "}",
    }
    local s, e = Loader.find_datasource_entry(lines, "dev")
    assert.are.same({ 3, 3 }, { s, e })
    s, e = Loader.find_datasource_entry(lines, "prod")
    assert.are.same({ 4, 7 }, { s, e })
    s, e = Loader.find_datasource_entry(lines, "my-app")
    assert.are.same({ 8, 8 }, { s, e })
    assert.is_nil(Loader.find_datasource_entry(lines, "nope"))
  end)

  it("update_datasource_in_file rewrites only the target entry", function()
    local path = dir .. "/.abcql.lua"
    local f = assert(io.open(path, "w"))
    f:write(table.concat({
      "-- keep me",
      "return {",
      '  default = "dev",',
      "  datasources = {",
      '    dev = "mysql://u:p@h/db",',
      "    prod = {",
      '      dsn = "mysql://u@h/app",',
      "      readonly = true,",
      "    },",
      "  },",
      "}",
      "",
    }, "\n"))
    f:close()

    local ok, err = Loader.update_datasource_in_file(path, "prod", {
      dsn = "mysql://u@h/app2",
      secret = { service = "abcql", account = "prod-db-password" },
      confirm = "always",
    })
    assert.is_true(ok, err)
    local content = assert(io.open(path)):read("*a")
    assert.is_not_nil(content:find("-- keep me", 1, true))
    local config = dofile(path)
    assert.are.equal("dev", config.default)
    assert.are.equal("mysql://u:p@h/db", config.datasources.dev)
    assert.are.equal("mysql://u@h/app2", config.datasources.prod.dsn)
    assert.is_nil(config.datasources.prod.readonly)
    assert.are.equal("always", config.datasources.prod.confirm)
    assert.are.same({ service = "abcql", account = "prod-db-password" }, config.datasources.prod.secret)

    -- table entry -> string entry
    assert.is_true(Loader.update_datasource_in_file(path, "prod", { dsn = "mysql://u:p@h/plain" }))
    assert.are.equal("mysql://u:p@h/plain", dofile(path).datasources.prod)

    ok, err = Loader.update_datasource_in_file(path, "missing", { dsn = "mysql://u@h/db" })
    assert.is_false(ok)
    assert.is_not_nil(err:find("not found", 1, true))
  end)

  it("fails cleanly when there is no datasources table", function()
    local path = dir .. "/.abcql.lua"
    local f = assert(io.open(path, "w"))
    f:write("return {}\n")
    f:close()
    local ok, err = Loader.add_datasource_to_file(path, "dev", { dsn = "mysql://u@h/db" })
    assert.is_false(ok)
    assert.is_not_nil(err:find("datasources = {", 1, true))
  end)
end)
