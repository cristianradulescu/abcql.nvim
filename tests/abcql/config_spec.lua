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
    it("should have empty data_sources by default", function()
      assert.is_table(Config.data_sources)
      assert.are.equal(0, vim.tbl_count(Config.data_sources))
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
        data_sources = {
          test_db = "mysql://user:pass@localhost:3306/testdb",
        },
      })

      assert.is_not_nil(Config.data_sources.test_db)
      assert.are.equal("mysql://user:pass@localhost:3306/testdb", Config.data_sources.test_db)
    end)

    it("should override default data_sources", function()
      Config.setup({
        data_sources = {
          custom_db = "postgres://user:pass@localhost:5432/customdb",
        },
      })

      assert.is_not_nil(Config.data_sources.custom_db)
    end)

    it("should handle multiple data sources", function()
      Config.setup({
        data_sources = {
          db1 = "mysql://user:pass@localhost:3306/db1",
          db2 = "mysql://user:pass@localhost:3306/db2",
          db3 = "postgres://user:pass@localhost:5432/db3",
        },
      })

      assert.are.equal(3, vim.tbl_count(Config.data_sources))
      assert.is_not_nil(Config.data_sources.db1)
      assert.is_not_nil(Config.data_sources.db2)
      assert.is_not_nil(Config.data_sources.db3)
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

    it("should create Abcql user command", function()
      Config.setup({})

      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.Abcql)
    end)

    it("should notify when setting up", function()
      local notified = false
      vim.notify = function(msg, level)
        if msg:match("Setting up abcql config") then
          notified = true
        end
      end

      Config.setup({})

      assert.is_true(notified)
    end)
  end)

  describe("metatable access", function()
    it("should allow accessing config values through module", function()
      Config.setup({
        data_sources = {
          my_db = "mysql://user:pass@localhost:3306/mydb",
        },
      })

      assert.are.equal(Config.data_sources.my_db, "mysql://user:pass@localhost:3306/mydb")
    end)

    it("should return nil for non-existent keys", function()
      Config.setup({})

      assert.is_nil(Config.nonexistent_key)
    end)
  end)

  describe("deep copy", function()
    it("should not mutate defaults when config is updated", function()
      local first_config = {
        data_sources = {
          db1 = "mysql://user:pass@localhost:3306/db1",
        },
      }

      Config.setup(first_config)

      package.loaded["abcql.config"] = nil
      Config = require("abcql.config")

      Config.setup({
        data_sources = {
          db2 = "mysql://user:pass@localhost:3306/db2",
        },
      })

      assert.is_nil(Config.data_sources.db1)
      assert.is_not_nil(Config.data_sources.db2)
    end)

    it("should not mutate user options", function()
      local user_opts = {
        data_sources = {
          original = "mysql://user:pass@localhost:3306/original",
        },
      }

      Config.setup(user_opts)

      package.loaded["abcql.config"] = nil
      Config = require("abcql.config")

      Config.setup({
        data_sources = {
          modified = "mysql://user:pass@localhost:3306/modified",
        },
      })

      assert.are.equal("mysql://user:pass@localhost:3306/original", user_opts.data_sources.original)
      assert.is_nil(user_opts.data_sources.modified)
    end)
  end)
end)
