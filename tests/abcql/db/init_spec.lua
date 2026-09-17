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

describe("Database datasource resolution", function()
  local Database
  local original_notify
  local original_select

  local function new_buffer(lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
    return buf
  end

  before_each(function()
    original_notify = vim.notify
    original_select = vim.ui.select
    vim.notify = function() end

    package.loaded["abcql.config"] = nil
    package.loaded["abcql.db"] = nil
    package.loaded["abcql.lsp"] = {
      start = function(_, _, cb)
        cb(nil)
      end,
      stop = function() end,
    }
    Database = require("abcql.db")
    Database.setup({
      datasources = {
        dev = "mysql://u:p@localhost:3306/shop",
        prod = { dsn = "mysql://u:p@db:3306/shop", readonly = true, confirm = "always", highlight = "Error" },
      },
    })
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.select = original_select
    package.loaded["abcql.lsp"] = nil
  end)

  it("keeps safety flags on registered datasources", function()
    local prod = Database.connectionRegistry:get_datasource("prod")
    assert.is_true(prod.readonly)
    assert.are.equal("always", prod.confirm)
    assert.are.equal("Error", prod.highlight)
    assert.is_false(Database.connectionRegistry:get_datasource("dev").readonly)
  end)

  it("lists datasource names sorted", function()
    assert.are.same({ "dev", "prod" }, Database.get_datasource_names())
  end)

  describe("detect_datasource_comment", function()
    it("reads `-- abcql: name` from the first lines", function()
      local buf = new_buffer({ "-- some header", "--abcql:prod", "select 1;" })
      assert.are.equal("prod", Database.detect_datasource_comment(buf))
    end)

    it("accepts the datasource= form", function()
      local buf = new_buffer({ "-- abcql: datasource = dev", "select 1;" })
      assert.are.equal("dev", Database.detect_datasource_comment(buf))
    end)

    it("returns nil without a comment", function()
      local buf = new_buffer({ "select 1;" })
      assert.is_nil(Database.detect_datasource_comment(buf))
    end)
  end)

  describe("resolve_datasource_name", function()
    it("prefers an explicit attachment", function()
      local buf = new_buffer({ "-- abcql: prod" })
      Database.attach_datasource(buf, "dev")
      local name, reason = Database.resolve_datasource_name(buf)
      assert.are.equal("dev", name)
      assert.are.equal("attached", reason)
    end)

    it("uses the file comment before the default", function()
      Database.default_datasource_name = "dev"
      local buf = new_buffer({ "-- abcql: prod" })
      local name, reason = Database.resolve_datasource_name(buf)
      assert.are.equal("prod", name)
      assert.are.equal("file comment", reason)
    end)

    it("ignores an unknown comment datasource and falls back to the default", function()
      Database.default_datasource_name = "dev"
      local buf = new_buffer({ "-- abcql: nope" })
      assert.are.equal("dev", (Database.resolve_datasource_name(buf)))
    end)

    it("falls back to the last used datasource", function()
      Database.default_datasource_name = nil
      Database.attach_datasource(new_buffer({}), "prod")
      local name, reason = Database.resolve_datasource_name(new_buffer({}))
      assert.are.equal("prod", name)
      assert.are.equal("last used", reason)
    end)

    it("does not reuse the last datasource when auto_attach is off", function()
      require("abcql.config").setup({
        datasources = { dev = "mysql://u:p@localhost:3306/shop" },
        query = { auto_attach = false },
      })
      Database = require("abcql.db")
      Database.attach_datasource(new_buffer({}), "dev")
      assert.is_nil((Database.resolve_datasource_name(new_buffer({}))))
    end)

    it("returns nil when nothing applies", function()
      Database.default_datasource_name = nil
      Database.last_datasource_name = nil
      assert.is_nil((Database.resolve_datasource_name(new_buffer({}))))
    end)
  end)

  describe("attach_datasource", function()
    it("stores the datasource and sets the winbar on windows showing the buffer", function()
      local buf = new_buffer({ "select 1;" })
      vim.api.nvim_set_current_buf(buf)
      Database.attach_datasource(buf, "prod")
      assert.are.equal("prod", Database.get_active_datasource(buf).name)
      local winbar = vim.wo[vim.api.nvim_get_current_win()].winbar
      assert.is_not_nil(winbar:find("prod", 1, true))
      assert.is_not_nil(winbar:find("readonly", 1, true))
      assert.is_not_nil(winbar:find("%#Error#", 1, true))
    end)

    it("reports unknown names", function()
      local err
      Database.attach_datasource(new_buffer({}), "missing", function(_, e)
        err = e
      end)
      assert.is_not_nil(err)
    end)
  end)

  describe("ensure_datasource", function()
    it("prompts when nothing can be resolved", function()
      Database.default_datasource_name = nil
      Database.last_datasource_name = nil
      vim.ui.select = function(items, _, on_choice)
        assert.are.same({ "dev", "prod" }, items)
        on_choice("dev")
      end
      local picked
      Database.ensure_datasource(new_buffer({}), function(ds)
        picked = ds
      end)
      assert.are.equal("dev", picked.name)
    end)

    it("auto-attaches from a file comment without prompting", function()
      vim.ui.select = function()
        error("should not prompt")
      end
      local picked
      Database.ensure_datasource(new_buffer({ "-- abcql: dev" }), function(ds)
        picked = ds
      end)
      assert.are.equal("dev", picked.name)
    end)
  end)
end)
