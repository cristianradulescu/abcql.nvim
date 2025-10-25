describe("Database", function()
  local Database
  local original_notify

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end

    package.loaded["abcql.db"] = nil
    package.loaded["abcql.db.connection.registry"] = nil
    package.loaded["abcql.db.adapter.mysql"] = nil

    Database = require("abcql.db")
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  describe("module initialization", function()
    it("should have a connectionRegistry instance", function()
      assert.is_not_nil(Database.connectionRegistry)
      assert.is_table(Database.connectionRegistry)
    end)

    it("should have setup function", function()
      assert.is_function(Database.setup)
    end)

  end)

  describe("setup", function()
    it("should register MySQL adapter", function()
      Database.setup({
        data_sources = {
          test_db = "mysql://user:pass@localhost:3306/testdb",
        },
      })

      local schemes = Database.connectionRegistry:get_schemes()
      assert.is_true(vim.tbl_contains(schemes, "mysql"))
    end)

    it("should notify when adapters are registered", function()
      local notified = false
      vim.notify = function(msg, level)
        if msg:match("Database adapters registered") then
          notified = true
        end
      end

      Database.setup({
        data_sources = {
          test_db = "mysql://user:pass@localhost:3306/testdb",
        },
      })

      assert.is_true(notified)
    end)
  end)

  describe("connect", function()
    before_each(function()
      Database.setup({
        data_sources = {
          test_db = "mysql://user:pass@localhost:3306/testdb",
        },
      })
    end)

  end)
end)
