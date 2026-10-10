describe("Sessions", function()
  local Sessions, BackendSession, Query
  local original_notify, original_start
  local starts, sent, choices, answer, closed

  --- A started session whose backend replies are scripted by `reply(op, fields)`.
  local function fake_start(state)
    return function(request, callback)
      table.insert(starts, request)
      local session
      session = BackendSession.new(function(line)
        local msg = vim.json.decode(line)
        table.insert(sent, msg)
        if msg.op == "exec" then
          vim.schedule(function()
            session:feed(vim.json.encode({
              id = msg.id,
              results = { { query_type = "write", affected_rows = 1 } },
              session = state,
            }) .. "\n")
          end)
        end
      end)
      session.proc = {
        write = function() end,
        wait = function()
          closed = true
        end,
      }
      session.state = state
      vim.schedule(function()
        callback(session, nil)
      end)
      return session
    end
  end

  local function datasource(extra)
    return vim.tbl_extend("force", {
      name = "dev",
      adapter = {
        ENGINE = "mysql",
        config = { database = "shop" },
        build_backend_request = function(_, sql)
          return { sql = sql, max_rows = 10 }
        end,
      },
    }, extra or {})
  end

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end
    package.loaded["abcql.config"] = nil
    require("abcql.config").setup({})
    Sessions = require("abcql.db.session")
    BackendSession = require("abcql.backend.session")
    Query = require("abcql.db.query")
    original_start = BackendSession.start
    starts, sent, choices, closed = {}, {}, {}, false
    answer = 2
    Sessions.confirm = function(message, options, default)
      table.insert(choices, { message = message, options = options, default = default })
      return answer
    end
    package.loaded["abcql.db"] = {
      setup = function() end,
      refresh_winbar = function() end,
    }
  end)

  after_each(function()
    BackendSession.start = original_start
    vim.notify = original_notify
    package.loaded["abcql.db"] = nil
    for _, bufnr in ipairs(vim.tbl_keys({ [1] = 1, [2] = 2, [3] = 3 })) do
      Sessions.close(bufnr, { can_cancel = false })
    end
  end)

  describe("mode", function()
    it("defaults to oneshot, follows query.session, and the datasource flag wins", function()
      assert.are.equal("oneshot", Sessions.mode(datasource()))
      require("abcql.config").setup({ query = { session = "persistent" } })
      assert.are.equal("persistent", Sessions.mode(datasource()))
      assert.are.equal("oneshot", Sessions.mode(datasource({ session = "oneshot" })))
      assert.are.equal("persistent", Sessions.mode(datasource({ session = "bogus" })))
    end)
  end)

  describe("refusal", function()
    it("refuses SQLite", function()
      local ds = datasource()
      ds.adapter.ENGINE = "sqlite"
      assert.is_truthy(Sessions.refusal(ds):find("MySQL-only", 1, true))
      assert.is_nil(Sessions.refusal(datasource()))
    end)
  end)

  describe("routing", function()
    local invoked, displayed, buf

    before_each(function()
      invoked = {}
      displayed = nil
      buf = vim.api.nvim_create_buf(false, true)
      package.loaded["abcql.backend"].invoke = function(request, callback)
        table.insert(invoked, request)
        callback({ results = { { query_type = "select", headers = {}, rows = {}, row_count = 0 } } }, nil)
        return {}
      end
      package.loaded["abcql.ui"] = {
        display = function(results)
          displayed = results
        end,
        set_running = function() end,
        clear_running = function() end,
      }
      package.loaded["abcql.history"] = { save = function() end }
      package.loaded["abcql.db.query"] = nil
      Query = require("abcql.db.query")
    end)

    after_each(function()
      package.loaded["abcql.ui"] = nil
      package.loaded["abcql.history"] = nil
      package.loaded["abcql.db.query"] = nil
      Sessions.close(buf, { can_cancel = false })
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("sends a persistent buffer's run through its session", function()
      BackendSession.start = fake_start({ in_transaction = false })
      local done
      Query.run("update t set a = 1 where id = 2", datasource({ session = "persistent" }), {
        bufnr = buf,
        confirm = false,
        on_done = function(results, err)
          done = { results = results, err = err }
        end,
      })
      vim.wait(1000, function()
        return done ~= nil
      end)
      assert.is_nil(done.err)
      assert.are.equal(1, #starts)
      assert.are.equal(0, #invoked, "no one-shot process for a persistent buffer")
      assert.are.equal("exec", sent[1].op)
      assert.are.equal("update t set a = 1 where id = 2", sent[1].statements[1].sql)

      -- the second run reuses the session
      done = nil
      Query.run("select 1", datasource({ session = "persistent" }), {
        bufnr = buf,
        on_done = function()
          done = true
        end,
      })
      vim.wait(1000, function()
        return done ~= nil
      end)
      assert.are.equal(1, #starts)
    end)

    it("keeps a oneshot datasource on the one-shot path, even in a persistent default", function()
      require("abcql.config").setup({ query = { session = "persistent" } })
      BackendSession.start = fake_start({})
      Query.run("select 1", datasource({ session = "oneshot" }), { bufnr = buf })
      assert.are.equal(0, #starts)
    end)

    it("applies the guards before the session sees anything", function()
      BackendSession.start = fake_start({})
      Query.run("delete from t", datasource({ session = "persistent", readonly = true }), { bufnr = buf })
      assert.are.equal(0, #starts)
      assert.is_truthy(displayed:find("readonly", 1, true))
    end)

    it("surfaces the SQLite refusal without falling back to a one-shot run", function()
      local ds = datasource({ session = "persistent" })
      ds.adapter.ENGINE = "sqlite"
      Query.run("select 1", ds, { bufnr = buf })
      assert.is_truthy(displayed:find("MySQL-only", 1, true))
      assert.are.equal(0, #invoked)
      assert.are.equal(0, #starts)
    end)

    it("surfaces the PROCESS refusal without falling back", function()
      BackendSession.start = function(_, callback)
        local session = BackendSession.new(function() end)
        session.dead = true
        vim.schedule(function()
          callback(nil, "persistent session needs the PROCESS privilege to track transactions")
        end)
        return session
      end
      local err
      Query.run("select 1", datasource({ session = "persistent" }), {
        bufnr = buf,
        on_done = function(_, e)
          err = e
        end,
      })
      vim.wait(1000, function()
        return err ~= nil
      end)
      assert.is_truthy(err:find("PROCESS", 1, true))
      assert.are.equal(0, #invoked)
      assert.is_nil(Sessions.get(buf))
    end)

    it("shows a lost session as the run's error, drops it and does not re-run the statement", function()
      BackendSession.start = function(request, callback)
        local session
        session = BackendSession.new(function(line)
          local msg = vim.json.decode(line)
          table.insert(sent, msg)
          vim.schedule(function()
            session:feed(
              vim.json.encode({ id = msg.id, error = "Session lost: gone", failed_index = 0, session_lost = true })
                .. "\n"
            )
          end)
        end)
        session.proc = { write = function() end, wait = function() end }
        vim.schedule(function()
          callback(session, nil)
        end)
        return session
      end
      local err
      Query.run("update t set a = 1 where id = 1", datasource({ session = "persistent" }), {
        bufnr = buf,
        confirm = false,
        on_done = function(_, e)
          err = e
        end,
      })
      vim.wait(1000, function()
        return err ~= nil
      end)
      assert.is_truthy(err:find("Session lost", 1, true))
      assert.are.equal(1, #sent, "the statement is sent once and never replayed")
      assert.are.equal(0, #invoked)
      assert.is_nil(Sessions.get(buf))
    end)

    describe("a statement that implicitly commits", function()
      local function floating()
        return vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= ""
      end

      local ran, ds

      local function open_session(state)
        ran = {}
        BackendSession.start = fake_start(state)
        ds = datasource({ session = "persistent", confirm = "never" })
        local opened
        Sessions.ensure(buf, ds, {}, function(s)
          opened = s
        end)
        vim.wait(1000, function()
          return opened ~= nil
        end)
        package.loaded["abcql.db"].ensure_datasource = function(_, callback)
          callback(ds)
        end
        vim.api.nvim_set_current_buf(buf)
      end

      local function run_begin()
        Query.run("BEGIN", ds, {
          bufnr = buf,
          on_done = function(_, err)
            table.insert(ran, err)
          end,
        })
      end

      after_each(function()
        if floating() then
          vim.api.nvim_win_close(0, true)
        end
      end)

      it("forces the confirmation float with an open transaction, whatever the policy", function()
        open_session({ in_transaction = true, rows_modified = 2 })
        run_begin()
        assert.is_true(floating())
        local title = vim.api.nvim_win_get_config(0).title[1][1]
        assert.is_truthy(title:find("BEGIN implicitly COMMITs the open transaction (2 rows modified)", 1, true))
      end)

      it("runs nothing when declined", function()
        open_session({ in_transaction = true, rows_modified = 2 })
        run_begin()
        vim.api.nvim_feedkeys("q", "x", false)
        assert.is_false(floating())
        assert.are.equal("cancelled", ran[1])
        assert.are.equal(0, #sent)
      end)

      it("shows no float without an open transaction, or for a harmless statement", function()
        open_session({ in_transaction = false })
        run_begin()
        assert.is_false(floating())
        open_session({ in_transaction = true, rows_modified = 1 })
        Query.run("CREATE TEMPORARY TABLE t (a int)", ds, { bufnr = buf })
        Query.run("SET autocommit = 0", ds, { bufnr = buf })
        assert.is_false(floating())
      end)

      it("lists it in the single up-front prompt of a buffer run", function()
        open_session({ in_transaction = true, rows_modified = 2 })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT 1;", "DROP TABLE t;" })
        Query.execute_buffer()
        assert.is_true(floating())
        local title = vim.api.nvim_win_get_config(0).title[1][1]
        assert.is_truthy(title:find("1 implicit COMMIT", 1, true))
        local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
        assert.is_truthy(body:find("line 2: DROP implicitly COMMITs", 1, true))
        assert.are.equal(0, #sent)
      end)
    end)

    it("cancel sends the cancel op instead of killing the process", function()
      local killed = false
      BackendSession.start = function(request, callback)
        local session = BackendSession.new(function(line)
          table.insert(sent, vim.json.decode(line))
        end)
        session.proc = {
          kill = function()
            killed = true
          end,
          write = function() end,
          wait = function() end,
        }
        vim.schedule(function()
          callback(session, nil)
        end)
        return session
      end
      Query.run("select sleep(100)", datasource({ session = "persistent" }), { bufnr = buf })
      vim.wait(1000, function()
        return #sent > 0
      end)
      assert.is_true(Query.cancel())
      assert.are.equal("cancel", sent[#sent].op)
      assert.is_false(killed)
    end)
  end)

  describe("closing", function()
    local buf, session

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      session = nil
      BackendSession.start = fake_start({ in_transaction = true, rows_modified = 4, rows_locked = 0 })
      Sessions.ensure(buf, datasource(), {}, function(s)
        session = s
      end)
      vim.wait(1000, function()
        return session ~= nil
      end)
    end)

    after_each(function()
      Sessions.close(buf, { can_cancel = false })
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("asks Commit / Rollback / Cancel with Rollback as the default", function()
      answer = 3
      assert.is_false(Sessions.close(buf, { can_cancel = true }))
      assert.are.equal("C&ommit\n&Rollback\n&Cancel", choices[1].options)
      assert.are.equal(2, choices[1].default)
      assert.is_not_nil(Sessions.get(buf), "Cancel keeps the session")
      assert.is_false(closed)
    end)

    it("rolls back by closing, never sending COMMIT, when Rollback or Esc is chosen", function()
      answer = 0
      assert.is_true(Sessions.close(buf, { can_cancel = false }))
      assert.are.equal("C&ommit\n&Rollback", choices[1].options)
      assert.are.equal(2, choices[1].default)
      assert.is_true(closed)
      assert.is_nil(Sessions.get(buf))
      for _, msg in ipairs(sent) do
        assert.are_not.equal("exec", msg.op)
      end
    end)

    it("commits only when asked to", function()
      answer = 1
      Sessions.close(buf, { can_cancel = false })
      assert.are.equal("COMMIT", sent[1].statements[1].sql)
      assert.is_true(closed)
    end)

    it("gives every choice its own hotkey, so `c` can never both commit and cancel", function()
      for _, can_cancel in ipairs({ true, false }) do
        choices = {}
        Sessions.close(buf, { can_cancel = can_cancel })
        local seen = {}
        for label in choices[1].options:gmatch("[^\n]+") do
          local key = label:match("&(.)"):lower()
          assert.is_nil(seen[key], "duplicate hotkey " .. key)
          seen[key] = true
        end
        if can_cancel then
          Sessions.ensure(buf, datasource(), {}, function() end)
          vim.wait(200)
        end
      end
    end)

    it("does not ask when no transaction is open", function()
      session.state = { in_transaction = false }
      assert.is_true(Sessions.close(buf, { can_cancel = true }))
      assert.are.equal(0, #choices)
      assert.is_true(closed)
    end)
  end)

  describe("winbar_text", function()
    it("marks an open transaction, autocommit off and a different database", function()
      assert.are.equal("", Sessions.winbar_text(nil, "shop"))
      local tx =
        Sessions.winbar_text({ in_transaction = true, rows_modified = 3, rows_locked = 5, database = "shop" }, "shop")
      assert.is_truthy(tx:find("AbcqlTransaction", 1, true))
      assert.is_truthy(tx:find("TX ● 3 rows, 5 locked", 1, true))
      local off = Sessions.winbar_text({ in_transaction = false, autocommit = false, database = "other" }, "shop")
      assert.is_truthy(off:find("autocommit off", 1, true))
      assert.is_truthy(off:find("→ other", 1, true))
      assert.is_nil(Sessions.winbar_text({ autocommit = true, database = "shop" }, "shop"):find("TX", 1, true))
    end)
  end)
end)
