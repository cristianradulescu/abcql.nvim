local Status = require("abcql.ui.status")

describe("abcql.ui.status", function()
  local bufnr
  local ns = vim.api.nvim_create_namespace("abcql_run_status")

  before_each(function()
    Status.clear()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT 1", "FROM t;", "", "SELECT 2;" })
  end)

  local function groups()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
      out[m[2] + 1] = m[4].line_hl_group
    end
    return out
  end

  it("colours every line of a successful statement green", function()
    Status.done({ bufnr = bufnr, start_line = 1, end_line = 2 }, nil)
    assert.same({ "AbcqlRunOk", "AbcqlRunOk" }, groups())
  end)

  it("colours a failed statement red", function()
    Status.done({ bufnr = bufnr, start_line = 4, end_line = 4 }, "boom")
    assert.same({ [4] = "AbcqlRunError" }, groups())
  end)

  it("keeps only the last executed statement marked", function()
    Status.done({ bufnr = bufnr, start_line = 1, end_line = 2 }, nil)
    Status.running({ bufnr = bufnr, start_line = 4, end_line = 4 })
    assert.same({}, groups())
    Status.done({ bufnr = bufnr, start_line = 4, end_line = 4 }, nil)
    assert.same({ [4] = "AbcqlRunOk" }, groups())
  end)

  it("ignores a missing mark and clamps lines past the buffer end", function()
    Status.done(nil, nil)
    Status.done({ bufnr = bufnr, start_line = 4, end_line = 99 }, nil)
    assert.same({ [4] = "AbcqlRunOk" }, groups())
  end)
end)
