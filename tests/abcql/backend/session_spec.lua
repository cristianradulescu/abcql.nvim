describe("Backend session", function()
  local Session = require("abcql.backend.session")
  local written, session

  before_each(function()
    written = {}
    session = Session.new(function(line)
      table.insert(written, line)
    end)
  end)

  local function sent(i)
    return vim.json.decode(written[i])
  end

  describe("feed", function()
    it("handles a reply split across chunks", function()
      local got
      session:exec({ { sql = "select 1" } }, nil, function(response)
        got = response
      end)
      local reply = vim.json.encode({ id = 1, results = {}, session = { in_transaction = true } })
      session:feed(reply:sub(1, 7))
      session:feed(reply:sub(8, 20))
      assert.is_nil(got)
      session:feed(reply:sub(21) .. "\n")
      assert.is_not_nil(got)
      assert.is_true(session.state.in_transaction)
    end)

    it("handles several lines in one chunk, matching replies to requests by id", function()
      local order = {}
      session.pending[1] = function(msg)
        table.insert(order, "one:" .. msg.tag)
      end
      session.pending[2] = function(msg)
        table.insert(order, "two:" .. msg.tag)
      end
      session:feed('{"id":2,"tag":"b"}\n{"id":1,"tag":"a"}\n{"id":2')
      assert.are.same({ "two:b", "one:a" }, order)
      session:feed(',"tag":"late"}\n')
      -- id 2 was already answered; the stray reply is ignored
      assert.are.same({ "two:b", "one:a" }, order)
    end)

    it("ignores lines that are not JSON", function()
      session:feed("garbage\n")
      assert.is_false(session.dead)
    end)
  end)

  describe("exec", function()
    it("writes one newline-terminated JSON request with an increasing id", function()
      session:exec({ { sql = "select 1", max_rows = 0 } }, 500, function() end)
      assert.are.equal("\n", written[1]:sub(-1))
      assert.are.same(
        { id = 1, op = "exec", timeout_ms = 500, statements = { { sql = "select 1", max_rows = 0 } } },
        sent(1)
      )
    end)

    it("rejects a second exec while one is waiting", function()
      session:exec({ { sql = "a" } }, nil, function() end)
      local err
      session:exec({ { sql = "b" } }, nil, function(_, e)
        err = e
      end)
      assert.is_truthy(err:find("busy", 1, true))
      assert.are.equal(1, #written)
    end)

    it("returns a failed batch whole, but a request-level error as an error", function()
      local response, err
      session:exec({ { sql = "a" } }, nil, function(r, e)
        response, err = r, e
      end)
      session:feed('{"id":1,"error":"boom","failed_index":0,"results":[]}\n')
      assert.are.equal("boom", response.error)
      assert.is_nil(err)

      session:exec({ { sql = "a" } }, nil, function(r, e)
        response, err = r, e
      end)
      session:feed('{"id":2,"error":"session busy"}\n')
      assert.is_nil(response)
      assert.are.equal("session busy", err)
    end)

    it("marks the session dead when the backend reports it lost", function()
      session:exec({ { sql = "a" } }, nil, function() end)
      session:feed('{"id":1,"error":"Session lost: x","failed_index":0,"session_lost":true}\n')
      assert.is_true(session.dead)
      local err
      session:exec({ { sql = "b" } }, nil, function(_, e)
        err = e
      end)
      assert.is_not_nil(err)
      assert.are.equal(1, #written, "nothing may be sent to a dead session")
    end)
  end)

  it("fails waiting requests when the process ends, and says so once when idle", function()
    local err
    session:exec({ { sql = "a" } }, nil, function(_, e)
      err = e
    end)
    session:ended("process gone")
    assert.are.equal("process gone", err)

    local lost = 0
    local idle = Session.new(function() end)
    idle.on_lost = function()
      lost = lost + 1
    end
    idle:ended("process gone")
    assert.are.equal(1, lost)
    idle:ended("again")
    assert.are.equal(1, lost)
  end)

  it("cancel sends the cancel op", function()
    session:cancel()
    assert.are.equal("cancel", sent(1).op)
  end)

  it("reports the open reply", function()
    local opened, err
    session.pending[0] = function(msg)
      opened, err = msg.session, msg.error
    end
    session:feed('{"session":{"connection_id":3}}\n')
    assert.are.equal(3, opened.connection_id)
    assert.is_nil(err)
  end)
end)
