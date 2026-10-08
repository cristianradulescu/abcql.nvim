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
  describe("update WHERE column", function()
    it("asks for the WHERE column and leaves it out of SET", function()
      local UI = require("abcql.ui")
      local og, od, os_ = UI.get_visible_results, UI.get_display_opts, vim.ui.select
      UI.get_visible_results = function()
        return { headers = { "id", "name" }, rows = { { "1", "x" } } }
      end
      UI.get_display_opts = function()
        return { query = "SELECT * FROM users" }
      end
      local prompts = {}
      vim.ui.select = function(items, opts, cb)
        table.insert(prompts, opts.prompt)
        cb(items[1], 1)
      end
      Export.export_current("update", { clipboard = true })
      UI.get_visible_results, UI.get_display_opts, vim.ui.select = og, od, os_
      assert.are.same({ "WHERE column:" }, prompts)
      assert.are.equal("UPDATE users SET name = 'x' WHERE id = 1;", vim.fn.getreg('"'))
    end)

    it("picks several WHERE columns one at a time until Done", function()
      local UI = require("abcql.ui")
      local og, od, os_ = UI.get_visible_results, UI.get_display_opts, vim.ui.select
      UI.get_visible_results = function()
        return { headers = { "a", "b", "c", "d" }, rows = { { "1", "2", "3", "4" } } }
      end
      UI.get_display_opts = function()
        return { query = "SELECT * FROM t" }
      end
      local offered = {}
      local answers = { 1, 3, 0 } -- a, then c, then Done
      vim.ui.select = function(items, opts, cb)
        table.insert(offered, vim.tbl_map(opts.format_item, items))
        cb(answers[#offered], 0)
      end
      Export.export_current("update", { clipboard = true })
      UI.get_visible_results, UI.get_display_opts, vim.ui.select = og, od, os_
      assert.are.same({ "a", "b", "c", "d" }, offered[1])
      assert.are.same({ "b", "c", "d", "[Done]" }, offered[2])
      assert.are.same({ "b", "d", "[Done]" }, offered[3])
      assert.are.equal("UPDATE t SET b = 2, d = 4 WHERE a = 1 AND c = 3;", vim.fn.getreg('"'))
    end)

    it("stops asking once only one column is left to update", function()
      local UI = require("abcql.ui")
      local og, od, os_ = UI.get_visible_results, UI.get_display_opts, vim.ui.select
      UI.get_visible_results = function()
        return { headers = { "a", "b", "c" }, rows = { { "1", "2", "3" } } }
      end
      UI.get_display_opts = function()
        return { query = "SELECT * FROM t" }
      end
      local calls = 0
      vim.ui.select = function(items, _, cb)
        calls = calls + 1
        cb(items[1], 1)
      end
      Export.export_current("update", { clipboard = true })
      UI.get_visible_results, UI.get_display_opts, vim.ui.select = og, od, os_
      assert.are.equal(2, calls)
      assert.are.equal("UPDATE t SET c = 3 WHERE a = 1 AND b = 2;", vim.fn.getreg('"'))
    end)

    it("exports nothing when the picker is cancelled", function()
      local UI = require("abcql.ui")
      local og, od, os_ = UI.get_visible_results, UI.get_display_opts, vim.ui.select
      UI.get_visible_results = function()
        return { headers = { "id", "name" }, rows = { { "1", "x" } } }
      end
      UI.get_display_opts = function()
        return {}
      end
      vim.ui.select = function(_, _, cb)
        cb(nil, nil)
      end
      vim.fn.setreg('"', "untouched")
      Export.export_current("update", { clipboard = true })
      UI.get_visible_results, UI.get_display_opts, vim.ui.select = og, od, os_
      assert.are.equal("untouched", vim.fn.getreg('"'))
    end)
  end)
end)
