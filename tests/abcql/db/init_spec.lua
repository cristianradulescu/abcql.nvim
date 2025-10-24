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

    it("should have connect function", function()
      assert.is_function(Database.connect)
    end)
  end)

  describe("setup", function()
    it("should register MySQL adapter", function()
      Database.setup()

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

      Database.setup()

      assert.is_true(notified)
    end)
  end)

  describe("connect", function()
    before_each(function()
      Database.setup()
    end)

    it("should delegate to connection registry", function()
      local dsn = "mysql://user:password@localhost:3306/testdb"
      local adapter, err = Database.connect(dsn)

      assert.is_not_nil(adapter)
      assert.is_nil(err)
    end)

    it("should return adapter instance for valid MySQL DSN", function()
      local dsn = "mysql://user:password@localhost:3306/testdb"
      local adapter, err = Database.connect(dsn)

      assert.is_nil(err)
      assert.is_not_nil(adapter)
      assert.is_function(adapter.get_command)
      assert.are.equal("mysql", adapter:get_command())
    end)

    it("should return error for invalid DSN", function()
      local dsn = "invalid-dsn"
      local adapter, err = Database.connect(dsn)

      assert.is_nil(adapter)
      assert.is_not_nil(err)
    end)

    it("should return error for unsupported scheme", function()
      local dsn = "unsupported://user:password@localhost:3306/testdb"
      local adapter, err = Database.connect(dsn)

      assert.is_nil(adapter)
      assert.is_not_nil(err)
      assert.matches("No adapter registered", err)
    end)

    it("should cache connections", function()
      local dsn = "mysql://user:password@localhost:3306/testdb"

      local adapter1, _ = Database.connect(dsn)
      local adapter2, _ = Database.connect(dsn)

      assert.are.equal(adapter1, adapter2)
    end)
  end)
end)
