describe("LSP client lifecycle", function()
  local LSP
  local original_notify

  local function fake_datasource(name)
    return {
      name = name,
      adapter = {
        get_databases = function(_, cb)
          cb({ "db" }, nil)
        end,
        get_tables = function(_, _, cb)
          cb({ "t" }, nil)
        end,
        get_all_columns = function(_, _, cb)
          cb({ t = { { name = "id", type = "int" } } }, nil)
        end,
        escape_identifier = function(_, n)
          return n
        end,
      },
    }
  end

  local function sql_buffer()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".sql")
    vim.bo[buf].filetype = "sql"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "SELECT id FROM t;" })
    return buf
  end

  before_each(function()
    original_notify = vim.notify
    vim.notify = function() end
    package.loaded["abcql.lsp"] = nil
    LSP = require("abcql.lsp")
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("shares one client between buffers of the same datasource and stops it when both detach", function()
    local ds = fake_datasource("shared")
    local a, b = sql_buffer(), sql_buffer()

    LSP.start(a, ds, function(err)
      assert.is_nil(err)
    end)
    LSP.start(b, ds, function(err)
      assert.is_nil(err)
    end)

    local client_id = LSP.get_client_id("shared")
    assert.is_not_nil(client_id)
    -- initialize is answered asynchronously; get_clients only lists initialized clients
    vim.wait(1000, function()
      local c = vim.lsp.get_client_by_id(client_id)
      return c ~= nil and c.initialized
    end)
    assert.is_true(vim.lsp.buf_is_attached(a, client_id))
    assert.is_true(vim.lsp.buf_is_attached(b, client_id))
    assert.are.equal(1, #vim.lsp.get_clients({ name = "abcql-lsp" }))
    assert.are.equal("shared", LSP.get_datasource_name(b))

    LSP.stop(a)
    assert.is_not_nil(vim.lsp.get_client_by_id(client_id))
    assert.is_true(LSP.is_running(b))

    LSP.stop(b)
    vim.wait(500, function()
      return vim.lsp.get_client_by_id(client_id) == nil
    end)
    assert.is_nil(LSP.get_client_id("shared"))
    assert.is_false(LSP.is_running(b))

    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("uses separate clients for different datasources", function()
    local a, b = sql_buffer(), sql_buffer()
    LSP.start(a, fake_datasource("one"), function() end)
    LSP.start(b, fake_datasource("two"), function() end)
    assert.are_not.equal(LSP.get_client_id("one"), LSP.get_client_id("two"))
    LSP.stop(a)
    LSP.stop(b)
    vim.api.nvim_buf_delete(a, { force = true })
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("answers completion requests through the real client", function()
    local ds = fake_datasource("live")
    local buf = sql_buffer()
    vim.api.nvim_set_current_buf(buf)
    LSP.start(buf, ds, function() end)
    local client = vim.lsp.get_client_by_id(LSP.get_client_id("live"))
    assert.is_not_nil(client)

    local result
    client:request("textDocument/completion", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = 0, character = 7 },
    }, function(err, res)
      assert.is_nil(err)
      result = res
    end, buf)
    vim.wait(1000, function()
      return result ~= nil
    end)
    assert.is_not_nil(result)
    local found = false
    for _, item in ipairs(result) do
      if item.label == "id" then
        found = true
      end
    end
    assert.is_true(found)

    LSP.stop(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
