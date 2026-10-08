describe("Export", function()
  local Export

  before_each(function()
    Export = require("abcql.export")
  end)

  it("copies the formatted lines to the clipboard registers instead of writing a file", function()
    local results = { headers = { "id", "name" }, rows = { { "1", "a" }, { "2", "b" } } }
    local cwd_before = vim.fn.glob(vim.fn.getcwd() .. "/query_*.tsv", false, true)

    local res = Export.export("tsv", results, { clipboard = true })

    assert.is_true(res.success)
    assert.is_true(res.clipboard)
    assert.is_nil(res.filepath)
    assert.are.equal(3, res.lines)
    assert.are.equal("id\tname\n1\ta\n2\tb\n", vim.fn.getreg('"'))
    assert.are.same(cwd_before, vim.fn.glob(vim.fn.getcwd() .. "/query_*.tsv", false, true))
  end)

  it("still reports unknown formats when copying", function()
    local res = Export.export("nope", { headers = {}, rows = {} }, { clipboard = true })
    assert.is_false(res.success)
  end)
end)
