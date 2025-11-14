describe("Config", function()
  local Config
  local original_notify

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end

    package.loaded["abcql.config"] = nil
    package.loaded["abcql.db"] = nil

    Config = require("abcql.config")
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  describe("defaults", function()
    it("should have empty datasources by default", function()
      assert.is_table(Config.datasources)
      assert.are.equal(0, vim.tbl_count(Config.datasources))
    end)
  end)

  describe("setup", function()
    it("should accept nil options", function()
      assert.has_no.errors(function()
        Config.setup(nil)
      end)
    end)

    it("should accept empty options", function()
      assert.has_no.errors(function()
        Config.setup({})
      end)
    end)

    it("should merge user config with defaults", function()
      Config.setup({
        datasources = {
          test_db = "mysql://user:pass@localhost:3306/testdb",
        },
      })

      assert.is_not_nil(Config.datasources.test_db)
      assert.are.equal("mysql://user:pass@localhost:3306/testdb", Config.datasources.test_db)
    end)

    it("should override default datasources", function()
      Config.setup({
        datasources = {
          custom_db = "postgres://user:pass@localhost:5432/customdb",
        },
      })

      assert.is_not_nil(Config.datasources.custom_db)
    end)

    it("should handle multiple data sources", function()
      Config.setup({
        datasources = {
          db1 = "mysql://user:pass@localhost:3306/db1",
          db2 = "mysql://user:pass@localhost:3306/db2",
          db3 = "postgres://user:pass@localhost:5432/db3",
        },
      })

      assert.are.equal(3, vim.tbl_count(Config.datasources))
      assert.is_not_nil(Config.datasources.db1)
      assert.is_not_nil(Config.datasources.db2)
      assert.is_not_nil(Config.datasources.db3)
    end)

    it("should call database setup", function()
      local db_setup_called = false
      package.loaded["abcql.db"] = {
        setup = function()
          db_setup_called = true
        end,
      }

      package.loaded["abcql.config"] = nil
      Config = require("abcql.config")

      Config.setup({})

      assert.is_true(db_setup_called)
    end)
  end)

  describe("metatable access", function()
    it("should allow accessing config values through module", function()
      Config.setup({
        datasources = {
          my_db = "mysql://user:pass@localhost:3306/mydb",
        },
      })

      assert.are.equal(Config.datasources.my_db, "mysql://user:pass@localhost:3306/mydb")
    end)

    it("should return nil for non-existent keys", function()
      Config.setup({})

      assert.is_nil(Config.nonexistent_key)
    end)
  end)

  describe("deep copy", function()
    it("should not mutate defaults when config is updated", function()
      local first_config = {
        datasources = {
          db1 = "mysql://user:pass@localhost:3306/db1",
        },
      }

      Config.setup(first_config)

      package.loaded["abcql.config"] = nil
      Config = require("abcql.config")

      Config.setup({
        datasources = {
          db2 = "mysql://user:pass@localhost:3306/db2",
        },
      })

      assert.is_nil(Config.datasources.db1)
      assert.is_not_nil(Config.datasources.db2)
    end)

    it("should not mutate user options", function()
      local user_opts = {
        datasources = {
          original = "mysql://user:pass@localhost:3306/original",
        },
      }

      Config.setup(user_opts)

      package.loaded["abcql.config"] = nil
      Config = require("abcql.config")

      Config.setup({
        datasources = {
          modified = "mysql://user:pass@localhost:3306/modified",
        },
      })

      assert.are.equal("mysql://user:pass@localhost:3306/original", user_opts.datasources.original)
      assert.is_nil(user_opts.datasources.modified)
    end)
  end)
end)
