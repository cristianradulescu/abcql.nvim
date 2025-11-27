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
