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
          assert.are.equal("select 1 LIMIT 1000", request.sql)
          assert.are.equal(0, request.max_rows)
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
      assert.are.equal(1000, displayed.auto_limit)
      assert.is_false(Query.is_running())
    end)
  end)

  describe("run with auto-LIMIT", function()
    --- Run a statement with mocked UI/history/backend; returns the backend request,
    --- the displayed result and the SQL saved to history.
    local function run(sql, ds)
      local captured = {}
      package.loaded["abcql.history"] = {
        save = function(query)
          captured.saved = query
        end,
      }
      package.loaded["abcql.ui"] = {
        display = function(results)
          captured.displayed = results
        end,
        set_running = function() end,
        clear_running = function() end,
      }
      package.loaded["abcql.backend"] = {
        invoke = function(request, callback)
          captured.request = request
          callback({ query_type = "select", headers = { "1" }, rows = { { "1" } }, row_count = 1 }, nil)
          return {}
        end,
      }
      package.loaded["abcql.db.query"] = nil
      Query = require("abcql.db.query")
      ds = ds or require("abcql.db").connectionRegistry:get_datasource("dev")
      Query.run(sql, ds, { confirm = false })
      package.loaded["abcql.history"] = nil
      package.loaded["abcql.ui"] = nil
      package.loaded["abcql.backend"] = nil
      return captured
    end

    it("sends a query's own LIMIT unchanged and lifts max_rows", function()
      local c = run("SELECT * FROM titles LIMIT 1000000")
      assert.are.equal("SELECT * FROM titles LIMIT 1000000", c.request.sql)
      assert.are.equal(0, c.request.max_rows)
      assert.is_nil(c.displayed.auto_limit)
    end)

    it("leaves other statements to max_rows", function()
      local c = run("SHOW TABLES")
      assert.are.equal("SHOW TABLES", c.request.sql)
      assert.are.equal(1000, c.request.max_rows)
      assert.is_nil(c.displayed.auto_limit)
    end)

    it("saves the SQL as written to history", function()
      local c = run("select * from t -- note")
      assert.are.equal("select * from t LIMIT 1000 -- note", c.request.sql)
      assert.are.equal("select * from t -- note", c.saved)
    end)

    it("follows query.auto_limit, then max_rows", function()
      require("abcql.config").setup({
        datasources = { dev = "mysql://u:p@localhost:3306/shop" },
        query = { max_rows = 200 },
      })
      assert.are.equal("select 1 LIMIT 200", run("select 1").request.sql)
      require("abcql.config").setup({
        datasources = { dev = "mysql://u:p@localhost:3306/shop" },
        query = { auto_limit = 50 },
      })
      assert.are.equal("select 1 LIMIT 50", run("select 1").request.sql)
      require("abcql.config").setup({
        datasources = { dev = "mysql://u:p@localhost:3306/shop" },
        query = { auto_limit = false },
      })
      local c = run("select 1")
      assert.are.equal("select 1", c.request.sql)
      assert.are.equal(1000, c.request.max_rows)
    end)

    it("lets the datasource flag override the global setting", function()
      require("abcql.config").setup({
        datasources = {
          small = { dsn = "mysql://u:p@localhost:3306/shop", auto_limit = 10 },
          off = { dsn = "mysql://u:p@localhost:3306/shop", auto_limit = false },
        },
      })
      local registry = require("abcql.db").connectionRegistry
      assert.are.equal("select 1 LIMIT 10", run("select 1", registry:get_datasource("small")).request.sql)
      assert.are.equal("select 1", run("select 1", registry:get_datasource("off")).request.sql)
    end)
  end)

  describe("dangerous statements", function()
    local invoked, ui

    before_each(function()
      invoked = nil
      ui = {
        display = function() end,
        set_running = function() end,
        clear_running = function() end,
      }
      package.loaded["abcql.ui"] = ui
      package.loaded["abcql.history"] = { save = function() end }
      package.loaded["abcql.backend"] = {
        invoke = function(request, callback)
          invoked = request.sql
          callback({ query_type = "write", affected_rows = 3 }, nil)
          return {}
        end,
      }
      package.loaded["abcql.db.query"] = nil
      Query = require("abcql.db.query")
    end)

    after_each(function()
      package.loaded["abcql.ui"] = nil
      package.loaded["abcql.history"] = nil
      package.loaded["abcql.backend"] = nil
    end)

    describe("in a buffer run", function()
      local ran, buf, batches

      local function floating()
        return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= ""
      end

      local function set_query(opts)
        for k, v in pairs(opts) do
          require("abcql.config").query[k] = v
        end
      end

      local function run_buffer(policy)
        require("abcql.config").setup({ query = { confirm = policy } })
        local ds = {
          name = "dev",
          adapter = {
            build_backend_request = function(_, sql)
              return { sql = sql }
            end,
          },
        }
        package.loaded["abcql.db"] = {
          ensure_datasource = function(_, callback)
            callback(ds)
          end,
        }
        ran = {}
        batches = {}
        package.loaded["abcql.backend"].invoke = function(request, callback)
          table.insert(batches, request)
          local results = {}
          for _, stmt in ipairs(request.statements) do
            table.insert(ran, stmt.sql)
            table.insert(results, { query_type = "write", affected_rows = 1 })
          end
          callback({ results = results }, nil)
          return {}
        end
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          "INSERT INTO a VALUES (1);",
          "UPDATE b SET x = 1;",
          "DELETE FROM c WHERE id = 1;",
        })
        vim.api.nvim_set_current_buf(buf)
        Query.execute_buffer()
      end

      after_each(function()
        package.loaded["abcql.db"] = nil
        if floating() then
          vim.api.nvim_win_close(0, true)
        end
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("confirms dangerous statements upfront, even with policy never, and declining runs nothing", function()
        run_buffer("never")
        assert.is_true(floating())
        local title = vim.api.nvim_win_get_config(0).title[1][1]
        assert.is_not_nil(title:find("1 dangerous", 1, true))
        local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
        assert.is_not_nil(body:find("line 2: UPDATE without WHERE affects every row in b", 1, true))
        assert.are.same({}, ran)

        vim.api.nvim_feedkeys("q", "x", false)
        assert.is_false(floating())
        assert.are.same({}, ran)
      end)

      it("asks once with the writes policy and runs the whole batch after accepting", function()
        run_buffer("writes")
        assert.is_true(floating())
        assert.are.same({}, ran)

        vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
        assert.is_false(floating())
        assert.are.same({ "INSERT INTO a VALUES (1)", "UPDATE b SET x = 1", "DELETE FROM c WHERE id = 1" }, ran)
      end)

      it("sends the whole buffer in one request with a row cap per statement", function()
        run_buffer("never")
        vim.api.nvim_win_close(0, true)
        ran = {}
        batches = {}
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          "SELECT * FROM a;",
          "SELECT * FROM b LIMIT 5;",
          "SET @x = 1;",
        })
        set_query({ confirm = "never", max_rows = 50, auto_limit = 0 })
        Query.execute_buffer()
        assert.are.equal(1, #batches)
        assert.is_nil(batches[1].sql)
        assert.are.same({
          { sql = "SELECT * FROM a", max_rows = nil },
          { sql = "SELECT * FROM b LIMIT 5", max_rows = 0 },
          { sql = "SET @x = 1", max_rows = nil },
        }, batches[1].statements)
      end)

      it("applies the auto-LIMIT per statement", function()
        run_buffer("never")
        vim.api.nvim_win_close(0, true)
        batches = {}
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT * FROM a;", "SET @x = 1;" })
        set_query({ confirm = "never", auto_limit = 20 })
        Query.execute_buffer()
        assert.are.same({
          { sql = "SELECT * FROM a LIMIT 20", max_rows = 0 },
          { sql = "SET @x = 1" },
        }, batches[1].statements)
      end)

      describe("displaying the batch", function()
        local displayed, saved, marks

        before_each(function()
          run_buffer("never")
          vim.api.nvim_win_close(0, true)
          displayed, saved, marks = {}, {}, {}
          package.loaded["abcql.ui"].display = function(results, _, opts)
            table.insert(displayed, { results = results, opts = opts })
          end
          package.loaded["abcql.history"].save = function(query, _, _, result, err)
            table.insert(saved, { query = query, result = result, err = err })
            return true, "id" .. #saved
          end
          local Status = require("abcql.ui.status")
          Status.done = function(mark, err)
            table.insert(marks, { mark = mark, err = err })
          end
          package.loaded["abcql.db.query"] = nil
          Query = require("abcql.db.query")
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SET @x = 1;", "SELECT @x;", "SELECT 2;" })
          set_query({ confirm = "never", auto_limit = 0 })
        end)

        it("saves every statement and shows the last result", function()
          Query.execute_buffer()
          assert.are.equal(3, #saved)
          assert.are.equal("SELECT @x", saved[2].query)
          assert.are.equal(1, #displayed)
          assert.are.equal("SET @x = 1;\nSELECT @x;\nSELECT 2;", displayed[1].opts.sent_query)
          assert.are.equal("id3", displayed[1].opts.history_id)
          assert.are.same({ bufnr = buf, start_line = 3, end_line = 3 }, marks[1].mark)
        end)

        it("shows the failing statement's error and keeps the earlier results", function()
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback({ results = { { query_type = "write" } }, error = "boom", failed_index = 1 }, nil)
            return {}
          end
          Query.execute_buffer()
          assert.are.equal(2, #saved)
          assert.is_nil(saved[1].err)
          assert.are.equal("boom", saved[2].err)
          assert.are.equal("SELECT @x", saved[2].query)
          assert.are.equal("boom", displayed[1].results)
          assert.are.same({ bufnr = buf, start_line = 2, end_line = 2 }, marks[1].mark)
          assert.are.equal("boom", marks[1].err)
        end)

        it("marks the first statement when it is the one that failed", function()
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback({ error = "boom", failed_index = 0 }, nil)
            return {}
          end
          Query.execute_buffer()
          assert.are.equal(1, #saved)
          assert.are.equal("SET @x = 1", saved[1].query)
          assert.are.equal("boom", displayed[1].results)
          assert.are.same({ bufnr = buf, start_line = 1, end_line = 1 }, marks[1].mark)
        end)

        it("covers the whole batch when an error names no statement", function()
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback(nil, "dial tcp 127.0.0.1:3306: connect: connection refused")
            return {}
          end
          Query.execute_buffer()
          assert.are.equal(1, #saved)
          assert.are.equal(saved[1].query, displayed[1].opts.query)
          assert.are.same({ bufnr = buf, start_line = 1, end_line = 3 }, marks[1].mark)
          assert.is_nil(displayed[1].results:find("may have been applied", 1, true))
        end)

        it("notes that a timed out statement may still complete on the server", function()
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback({ error = "context deadline exceeded", failed_index = 1 }, nil)
            return {}
          end
          Query.execute_buffer()
          assert.is_not_nil(displayed[1].results:find("may still complete on the server", 1, true))
        end)

        it("checks every statement for a schema change when the error names none", function()
          local checked = {}
          Query.after_schema_change = function(sql)
            table.insert(checked, sql)
          end
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback(nil, "Query cancelled")
            return {}
          end
          Query.execute_buffer()
          assert.are.same({ "SET @x = 1", "SELECT @x", "SELECT 2" }, checked)
        end)

        it("refuses a batch with a write on a readonly datasource", function()
          package.loaded["abcql.db"].ensure_datasource = function(_, callback)
            callback({ name = "prod", readonly = true, adapter = {} })
          end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1;", "UPDATE a SET x = 1 WHERE id = 1;" })
          batches = {}
          Query.execute_buffer()
          assert.are.same({}, batches)
          assert.is_not_nil(displayed[1].results:find("readonly", 1, true))
        end)

        it("keeps buffer line numbers when the selection starts on blank lines", function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "SELECT 1;", "DELETE FROM b;" })
          vim.cmd("normal! ggVG\27")
          Query.execute_selection()
          local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
          assert.is_not_nil(body:find("-- line 4: DELETE without WHERE", 1, true))
          vim.api.nvim_feedkeys("q", "x", false)

          package.loaded["abcql.config"].query.lint_dangerous = false
          Query.execute_selection()
          assert.are.same({ bufnr = buf, start_line = 4, end_line = 4 }, marks[1].mark)
        end)

        it("warns that earlier statements may have been applied when cancelled", function()
          package.loaded["abcql.backend"].invoke = function(_, callback)
            callback(nil, "Query cancelled")
            return {}
          end
          Query.execute_buffer()
          assert.is_not_nil(displayed[1].results:find("up to and including the one that was running", 1, true))
          assert.are.equal(1, #saved)
        end)
      end)

      it("runs a multi-statement selection as one batch", function()
        run_buffer("never")
        vim.api.nvim_win_close(0, true)
        ran = {}
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          "SELECT * FROM a LIMIT 100;",
          "SELECT * FROM b LIMIT 100;",
          "SELECT * FROM c LIMIT 100;",
        })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! Vjj\27")
        Query.execute_selection()
        assert.is_false(floating())
        assert.are.same({ "SELECT * FROM a LIMIT 100", "SELECT * FROM b LIMIT 100", "SELECT * FROM c LIMIT 100" }, ran)
        assert.are.equal(1, #batches)
      end)
    end)

    it("forces the confirmation float even with confirm policy never", function()
      require("abcql.config").setup({ query = { confirm = "never" } })
      local ds = {
        name = "scratch",
        confirm = "never",
        adapter = {
          build_backend_request = function(_, sql)
            return { sql = sql }
          end,
        },
      }
      local prev_win = vim.api.nvim_get_current_win()
      Query.run("select 1; delete from orders", ds, { confirm = false })

      local win = vim.api.nvim_get_current_win()
      assert.are_not.equal(prev_win, win)
      local title = vim.api.nvim_win_get_config(win).title[1][1]
      assert.is_not_nil(title:find("DELETE without WHERE affects every row in orders", 1, true))
      assert.is_nil(invoked)

      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      assert.are.equal("select 1; delete from orders", invoked)
    end)

    it("runs without a prompt when the datasource disables the lint", function()
      local ds = {
        name = "scratch",
        lint_dangerous = false,
        adapter = {
          build_backend_request = function(_, sql)
            return { sql = sql }
          end,
        },
      }
      Query.run("truncate logs", ds, { confirm = false })
      assert.are.equal("truncate logs", invoked)
    end)

    it("keeps the readonly guard first", function()
      local err
      Query.run("delete from orders", { name = "prod", readonly = true }, {
        on_done = function(_, e)
          err = e
        end,
      })
      assert.is_not_nil(err:find("readonly", 1, true))
      assert.is_nil(invoked)
    end)
  end)

  describe("cancel", function()
    it("returns false when nothing is running", function()
      assert.is_false(Query.cancel())
    end)
  end)
end)
