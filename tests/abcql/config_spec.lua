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

describe("Config add_datasource", function()
  local Config
  local original_notify, original_input, original_select, original_secure_read
  local dir, original_getcwd

  before_each(function()
    original_notify = vim.notify
    original_input = vim.ui.input
    original_select = vim.ui.select
    vim.notify = function() end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return dir
    end
    -- The trust database is left untouched in tests, so read the temp file directly
    original_secure_read = vim.secure.read
    vim.secure.read = function(path)
      local f = io.open(path, "r")
      if not f then
        return nil
      end
      local content = f:read("*a")
      f:close()
      return content
    end
    package.loaded["abcql.config"] = nil
    package.loaded["abcql.config.loader"] = nil
    package.loaded["abcql.db"] = nil
    require("abcql.config.loader").TRUST_WRITTEN_FILES = false
    Config = require("abcql.config")
    Config.setup({})
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.input = original_input
    vim.ui.select = original_select
    vim.fn.getcwd = original_getcwd
    vim.secure.read = original_secure_read
    vim.fn.delete(dir, "rf")
  end)

  it("writes the answers to the local config and registers the datasource", function()
    local answers = { "staging", "mysql://u:p@staging:3306/app" }
    vim.ui.input = function(_, on_confirm)
      on_confirm(table.remove(answers, 1))
    end
    vim.ui.select = function(items, opts, on_choice)
      if opts.prompt:match("^Options") then
        on_choice("Readonly")
      else
        on_choice(items[1])
      end
    end

    Config.add_datasource("local")

    local config = dofile(dir .. "/.abcql.lua")
    assert.are.equal("mysql://u:p@staging:3306/app", config.datasources.staging.dsn)
    assert.is_true(config.datasources.staging.readonly)
    local ds = require("abcql.db").connectionRegistry:get_datasource("staging")
    assert.is_not_nil(ds)
    assert.is_true(ds.readonly)
  end)

  it("moves the DSN password into the keyring when asked", function()
    local original_executable = vim.fn.executable
    local original_system = vim.system
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 1
      end
      return original_executable(name)
    end
    -- Record the `store` call; answer the `lookup` that the reload performs afterwards
    local stored
    vim.system = function(cmd, opts)
      if cmd[2] == "store" then
        stored = { cmd = cmd, stdin = opts and opts.stdin }
      end
      return {
        wait = function()
          return { code = 0, stdout = cmd[2] == "lookup" and "topsecret\n" or "", stderr = "" }
        end,
      }
    end

    local answers = { "prod", "mysql://u:topsecret@db:3306/app" }
    vim.ui.input = function(_, on_confirm)
      on_confirm(table.remove(answers, 1))
    end
    vim.ui.select = function(items, opts, on_choice)
      if opts.prompt:match("^Password") then
        on_choice(items[2])
      elseif opts.prompt:match("^Options") then
        on_choice("None")
      else
        on_choice(items[1])
      end
    end

    Config.add_datasource("local")

    vim.fn.executable = original_executable
    vim.system = original_system

    assert.are.equal("topsecret", stored.stdin)
    assert.are.same({ "service", "abcql", "account", "prod-db-password" }, vim.list_slice(stored.cmd, 4, 7))
    local content = assert(io.open(dir .. "/.abcql.lua")):read("*a")
    assert.is_nil(content:find("topsecret", 1, true))
    local config = dofile(dir .. "/.abcql.lua")
    assert.are.equal("mysql://u@db:3306/app", config.datasources.prod.dsn)
    assert.are.same({ service = "abcql", account = "prod-db-password" }, config.datasources.prod.secret)
  end)

  it("skips the keyring step when secret-tool is missing", function()
    local original_executable = vim.fn.executable
    vim.fn.executable = function(name)
      if name == "secret-tool" then
        return 0
      end
      return original_executable(name)
    end
    local prompts = {}
    local answers = { "dev", "mysql://u:p@localhost:3306/app" }
    vim.ui.input = function(_, on_confirm)
      on_confirm(table.remove(answers, 1))
    end
    vim.ui.select = function(items, opts, on_choice)
      table.insert(prompts, opts.prompt)
      on_choice(items[1])
    end

    Config.add_datasource("local")
    vim.fn.executable = original_executable

    for _, prompt in ipairs(prompts) do
      assert.is_nil(prompt:match("^Password"))
    end
    assert.are.equal("mysql://u:p@localhost:3306/app", dofile(dir .. "/.abcql.lua").datasources.dev)
  end)

  it("does nothing when the prompt is cancelled", function()
    vim.ui.input = function(_, on_confirm)
      on_confirm(nil)
    end
    Config.add_datasource("local")
    assert.is_nil(vim.uv.fs_stat(dir .. "/.abcql.lua"))
  end)
end)
