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
  describe("format picker", function()
    it("shows each format with its description", function()
      local seen
      local orig = vim.ui.select
      vim.ui.select = function(items, opts, cb)
        seen = { items = items, labels = vim.tbl_map(opts.format_item, items) }
      end
      Export.register_format("zzz", function() end, "test format")
      Export.register_format("zzz_plain", function() end)
      -- no data: export_current bails out before the picker, so drive the picker via a result
      local UI = require("abcql.ui")
      local orig_get = UI.get_visible_results
      UI.get_visible_results = function()
        return { headers = { "a" }, rows = { { "1" } } }
      end
      Export.export_current(nil, { clipboard = true })
      UI.get_visible_results = orig_get
      vim.ui.select = orig

      local labels = {}
      for i, name in ipairs(seen.items) do
        labels[name] = seen.labels[i]
      end
      assert.is_truthy(labels.csv:match("^csv%s+%S"))
      assert.is_truthy(labels.zzz:match("test format$"))
      assert.are.equal("zzz_plain", labels.zzz_plain)
    end)
  end)
  describe("insert context", function()
    local function export_with_query(sql)
      local UI = require("abcql.ui")
      local og, od = UI.get_visible_results, UI.get_display_opts
      UI.get_visible_results = function()
        return { headers = { "a" }, rows = { { "1" } } }
      end
      UI.get_display_opts = function()
        return { query = sql }
      end
      Export.export_current("insert", { clipboard = true })
      UI.get_visible_results, UI.get_display_opts = og, od
      return vim.fn.getreg('"', 1, 1)
    end

    it("names the table when the query reads exactly one", function()
      assert.are.equal("INSERT INTO users (a)", export_with_query("SELECT a FROM users")[1])
    end)

    it("leaves a placeholder for joins", function()
      assert.are.equal(
        "INSERT INTO <table> (a)",
        export_with_query("SELECT a FROM users u JOIN orders o ON o.uid = u.id")[1]
      )
    end)
  end)
  describe("default file extension", function()
    it("maps insert to .sql and markdown to .md", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      local data = { headers = { "a" }, rows = { { "1" } } }
      local sql = Export.export("insert", data)
      local md = Export.export("markdown", data)
      vim.cmd.cd(cwd)
      assert.is_truthy(sql.filepath:match("%.sql$"))
      assert.is_truthy(md.filepath:match("%.md$"))
    end)
  end)
end)
