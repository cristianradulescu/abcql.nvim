describe("Query", function()
  local Query
  local original_notify

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end
    package.loaded["abcql.config"] = nil
    package.loaded["abcql.db"] = nil
    package.loaded["abcql.db.query"] = nil
    require("abcql.config").setup({ datasources = { dev = "mysql://u:p@localhost:3306/shop" } })
    Query = require("abcql.db.query")
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  describe("get_query_at_cursor", function()
    it("returns the statement under the cursor", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;", "", "select", "  2;" })
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      assert.are.equal("select\n  2", Query.get_query_at_cursor())
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.are.equal("select\n  2", Query.get_query_at_cursor())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns an empty string for an empty buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal("", Query.get_query_at_cursor())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("get_selection_query", function()
    it("returns the linewise selection without the trailing semicolon", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;", "select 2", "from t;", "select 3;" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd("normal! Vj\27")
      assert.are.equal("select 2\nfrom t", Query.get_selection_query())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("should_confirm", function()
    local ds = { name = "dev" }

    it("confirms only writes by default", function()
      assert.is_false(Query.should_confirm(ds, "select 1"))
      assert.is_true(Query.should_confirm(ds, "delete from t"))
    end)

    it("honours the global policy", function()
      require("abcql.config").setup({ query = { confirm = "always" } })
      assert.is_true(Query.should_confirm(ds, "select 1"))
      require("abcql.config").setup({ query = { confirm = "never" } })
      assert.is_false(Query.should_confirm(ds, "drop table t"))
    end)

    it("lets the datasource override the policy", function()
      assert.is_true(Query.should_confirm({ name = "prod", confirm = "always" }, "select 1"))
      assert.is_false(Query.should_confirm({ name = "scratch", confirm = "never" }, "delete from t"))
    end)
  end)

  describe("run", function()
    it("refuses writes on a readonly datasource", function()
      local displayed
      package.loaded["abcql.ui"] = {
        display = function(results)
          displayed = results
        end,
        set_running = function() end,
        clear_running = function() end,
      }
      local err
      Query.run("delete from t", { name = "prod", readonly = true }, {
        on_done = function(_, e)
          err = e
        end,
      })
      package.loaded["abcql.ui"] = nil
      assert.is_not_nil(err)
      assert.is_not_nil(displayed:find("readonly", 1, true))
    end)

    it("executes reads without a prompt and records history", function()
      local saved
      package.loaded["abcql.history"] = {
        save = function(query, ds_name)
          saved = { query = query, ds = ds_name }
        end,
      }
      local displayed
      package.loaded["abcql.ui"] = {
        display = function(results)
          displayed = results
        end,
        set_running = function() end,
        clear_running = function() end,
      }
      package.loaded["abcql.backend"] = {
        invoke = function(request, callback)
          assert.are.equal("select 1", request.sql)
          assert.are.equal(1000, request.max_rows)
          callback({ query_type = "select", headers = { "1" }, rows = { { "1" } }, row_count = 1 }, nil)
          return {}
        end,
      }
      package.loaded["abcql.db.query"] = nil
      Query = require("abcql.db.query")

      local ds = require("abcql.db").connectionRegistry:get_datasource("dev")
      local done = false
      Query.run("select 1", ds, {
        on_done = function()
          done = true
        end,
      })

      package.loaded["abcql.history"] = nil
      package.loaded["abcql.ui"] = nil
      package.loaded["abcql.backend"] = nil

      assert.is_true(done)
      assert.are.equal("select 1", saved.query)
      assert.are.equal("dev", saved.ds)
      assert.are.same({ "1" }, displayed.headers)
      assert.is_false(Query.is_running())
    end)
  end)

  describe("cancel", function()
    it("returns false when nothing is running", function()
      assert.is_false(Query.cancel())
    end)
  end)
end)
