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

  describe("slice", function()
    local results = { headers = { "id", "name" }, rows = { { "1", "a" }, { "2", "b" } } }

    it("returns everything for scope all", function()
      assert.are.equal(results, Export.slice(results, "all"))
    end)

    it("takes the cell, row and column of the target", function()
      local target = { col = 2, row = results.rows[2] }
      assert.are.same({ headers = { "name" }, rows = { { "b" } } }, Export.slice(results, "cell", target))
      assert.are.same({ headers = results.headers, rows = { { "2", "b" } } }, Export.slice(results, "row", target))
      assert.are.same({ headers = { "name" }, rows = { { "a" }, { "b" } } }, Export.slice(results, "column", target))
    end)

    it("reports a missing target", function()
      assert.is_nil(Export.slice(results, "cell", { col = 1 }))
      assert.is_nil(Export.slice(results, "row", {}))
      assert.is_nil(Export.slice(results, "column", {}))
      assert.is_nil(Export.slice(results, "bogus"))
    end)

    it("exports a column slice as an inline list to the clipboard", function()
      local data = Export.slice(results, "column", { col = 1 })
      local res = Export.export("values", data, { clipboard = true })
      assert.is_true(res.success)
      assert.are.equal("1, 2", vim.fn.getreg('"'))
      assert.are.equal("v", vim.fn.getregtype('"'))
    end)
  end)
end)
