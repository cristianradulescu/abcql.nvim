describe("UI", function()
  local UI
  local original_notify
  local original_select

  local function sql_buffer()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "sql"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;" })
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  local function results_lines()
    local buf = vim.fn.bufnr("[abcql] Query Results")
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local function output_lines()
    local buf = vim.fn.bufnr("[abcql] Query Output")
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  before_each(function()
    original_notify = vim.notify
    original_select = vim.ui.select
    vim.notify = function() end

    package.loaded["abcql.ui"] = nil
    package.loaded["abcql.ui.tree"] = nil
    package.loaded["abcql.config"] = nil
    package.loaded["abcql.db"] = nil
    require("abcql.config").setup({ datasources = { dev = "mysql://u:p@localhost:3306/shop" } })
    UI = require("abcql.ui")
    vim.cmd("only")
    sql_buffer()
  end)

  after_each(function()
    pcall(UI.close)
    vim.notify = original_notify
    vim.ui.select = original_select
    vim.cmd("only")
  end)

  describe("open", function()
    it("uses the current SQL buffer as the editor and shows results", function()
      UI.open()
      assert.is_true(UI.is_valid())
      assert.is_true(UI.results_visible())
      assert.is_false(UI.tree_visible())
    end)

    it("prompts before creating a scratch editor for non-SQL buffers", function()
      vim.bo.filetype = "text"
      local prompted = false
      vim.ui.select = function(_, _, on_choice)
        prompted = true
        on_choice("Yes")
      end
      UI.open()
      assert.is_true(prompted)
      assert.is_true(UI.is_valid())
    end)
  end)

  describe("toggle_results", function()
    it("survives a hide/show round trip", function()
      UI.open()
      UI.toggle_results()
      assert.is_false(UI.results_visible())
      assert.has_no.errors(UI.toggle_results)
      assert.is_true(UI.results_visible())
    end)

    it("re-opens the panel when new results arrive while hidden", function()
      UI.open()
      UI.toggle_results()
      assert.has_no.errors(function()
        UI.display({ headers = { "a" }, rows = { { "1" } }, row_count = 1, query_type = "select" })
      end)
      assert.is_true(UI.results_visible())
      assert.are.same({ "a" }, UI.get_current_results().headers)
    end)
  end)

  describe("display", function()
    it("renders a result table with a footer", function()
      UI.open()
      UI.display({ headers = { "id", "name" }, rows = { { "1", "x" } }, row_count = 1, duration_ms = 12 })
      local lines = results_lines()
      assert.is_not_nil(lines[2]:find("id", 1, true))
      assert.is_not_nil(lines[4]:find("x", 1, true))
      assert.are.equal(" 1 row • 12ms", lines[#lines])
    end)

    it("flags truncated results in the footer", function()
      UI.open()
      UI.display({ headers = { "id" }, rows = { { "1" } }, row_count = 1, truncated = true })
      local lines = results_lines()
      assert.is_not_nil(lines[#lines]:find("showing first 1 row", 1, true))
    end)

    it("shows an added LIMIT in the footer", function()
      UI.open()
      UI.display({ headers = { "id" }, rows = { { "1" } }, row_count = 1, auto_limit = 1000 })
      local lines = results_lines()
      assert.are.equal(" 1 row • auto LIMIT 1000", lines[#lines])
    end)

    it("shows the datasource and summary in the results winbar, the query in the Output tab", function()
      UI.open()
      local ds = require("abcql.db").connectionRegistry:get_datasource("dev")
      UI.display(
        { headers = { "id" }, rows = {}, row_count = 0, duration_ms = 5 },
        nil,
        { query = "-- c\nselect  *\nfrom t", datasource = ds }
      )
      local results_win = vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))
      local winbar = vim.wo[results_win].winbar
      assert.is_not_nil(winbar:find("dev/shop", 1, true))
      assert.is_nil(winbar:find("select", 1, true))
      assert.is_not_nil(winbar:find("0 rows", 1, true))
      local output = output_lines()
      assert.is_not_nil(output[1]:find("^%-%- dev/shop • %d"))
      assert.are.same({ "-- c", "select  *", "from t" }, vim.list_slice(output, 2, 4))
      assert.are.equal("-- 0 rows • 5ms", output[#output])
      assert.is_not_nil(winbar:find("%= %#AbcqlFooter#g? keys", 1, true))
    end)

    it("renders errors and clears stored results", function()
      UI.open()
      UI.display({ headers = { "a" }, rows = { { "1" } }, row_count = 1 })
      UI.display("boom")
      assert.is_nil(UI.get_current_results())
      assert.is_not_nil(table.concat(results_lines(), "\n"):find("boom", 1, true))
    end)

    it("shows a history entry's query in the Output tab, not above the table", function()
      UI.open()
      UI.display(
        { headers = { "a" }, rows = { { "1" } }, row_count = 1 },
        nil,
        { query = "select 1", history_position = "history 1/3", executed_at = 0 }
      )
      assert.is_not_nil(results_lines()[1]:find("^┌"))
      local output = output_lines()
      assert.are.equal("-- history 1/3 • " .. os.date("%Y-%m-%d %H:%M:%S", 0), output[1])
      assert.are.equal("select 1", output[2])
    end)

    it("shows the SQL as sent when an auto LIMIT was added", function()
      UI.open()
      UI.display(
        { headers = { "a" }, rows = {}, row_count = 0 },
        nil,
        { query = "select a from t", sent_query = "select a from t LIMIT 10" }
      )
      local output = table.concat(output_lines(), "\n")
      assert.is_not_nil(output:find("auto LIMIT", 1, true))
      assert.is_not_nil(output:find("select a from t LIMIT 10", 1, true))
    end)

    it("puts the error message in the Output tab", function()
      UI.open()
      UI.display("Unknown column 'x'", nil, { query = "select x" })
      local output = output_lines()
      assert.are.same({ "-- error:", "-- Unknown column 'x'" }, vim.list_slice(output, #output - 1, #output))
    end)
  end)

  describe("tabs", function()
    local function results_win()
      return vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))
    end

    it("switches the results window between Result and Output with o", function()
      UI.open()
      UI.display({ headers = { "a" }, rows = { { "1" } }, row_count = 1 }, nil, { query = "select 1" })
      local win = results_win()
      vim.api.nvim_set_current_win(win)
      assert.is_not_nil(vim.wo[win].winbar:find("%#AbcqlTabActive# Result", 1, true))

      vim.cmd("normal o")
      assert.are.equal("[abcql] Query Output", vim.fn.bufname(vim.api.nvim_win_get_buf(win)))
      assert.is_not_nil(vim.wo[win].winbar:find("%#AbcqlTabActive# Output", 1, true))

      vim.cmd("normal o")
      assert.are.equal("[abcql] Query Results", vim.fn.bufname(vim.api.nvim_win_get_buf(win)))
    end)

    it("goes back to the Result tab when a new result arrives", function()
      UI.open()
      local win = results_win()
      vim.api.nvim_set_current_win(win)
      vim.cmd("normal o")
      UI.display({ headers = { "a" }, rows = { { "1" } }, row_count = 1 })
      assert.are.equal("[abcql] Query Results", vim.fn.bufname(vim.api.nvim_win_get_buf(win)))
    end)

    it("keeps the Output tab across hiding and showing the panel", function()
      UI.open()
      vim.api.nvim_set_current_win(results_win())
      vim.cmd("normal o")
      UI.toggle_results()
      UI.toggle_results()
      local win = vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Output"))
      assert.are_not.equal(-1, win)
    end)
  end)

  describe("sort and filter", function()
    local original_input

    local function results_win()
      return vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))
    end

    --- Put the cursor on a column's cell (header line 2, data from line 4) and press keys
    local function press(keys, line, header)
      local win = results_win()
      vim.api.nvim_set_current_win(win)
      local col = assert(results_lines()[2]:find(header, 1, true)) - 1
      vim.api.nvim_win_set_cursor(win, { line, col })
      vim.cmd("normal " .. keys)
    end

    --- First cell (id) of each data row as rendered
    local function ids()
      local out = {}
      local lines = results_lines()
      for i = 4, #lines - 2 do
        table.insert(out, (lines[i]:match("^│ (%S+)")))
      end
      return out
    end

    before_each(function()
      original_input = vim.ui.input
      UI.open()
      UI.display({
        headers = { "id", "name", "total" },
        rows = { { "1", "b", "10" }, { "2", "a", "9" }, { "3", "c", "NULL" } },
        row_count = 3,
      })
    end)

    after_each(function()
      vim.ui.input = original_input
    end)

    it("sorts by the column under the cursor, cycling asc → desc → off", function()
      press("s", 2, "total")
      assert.are.same({ "3", "2", "1" }, ids())
      assert.is_not_nil(results_lines()[2]:find("total ▲", 1, true))
      assert.are.equal(" 3 rows • sorted by total ▲", results_lines()[#results_lines()])
      press("s", 2, "total")
      assert.are.same({ "1", "2", "3" }, ids())
      assert.is_not_nil(results_lines()[2]:find("total ▼", 1, true))
      press("s", 2, "total")
      assert.are.same({ "1", "2", "3" }, ids())
      assert.is_nil(results_lines()[2]:find("▼", 1, true))
    end)

    it("keeps the cursor on the sorted column", function()
      press("s", 5, "name")
      local cursor = vim.api.nvim_win_get_cursor(results_win())
      assert.are.equal(5, cursor[1])
      assert.are.equal(results_lines()[2]:find("name", 1, true) - 1, cursor[2])
    end)

    it("resolves cell keys through the sorted rows", function()
      press("s", 2, "name")
      press("yc", 4, "name")
      assert.are.equal("a", vim.fn.getreg('"'))
      press("yr", 4, "id")
      assert.are.equal("2\ta\t9", vim.fn.getreg('"'))
    end)

    it("keeps or drops rows equal to the cell under the cursor", function()
      press("=", 4, "name")
      assert.are.same({ "1" }, ids())
      assert.are.equal(" 1 of 3 rows • filter: name = 'b'", results_lines()[#results_lines()])
      press("F", 4, "name")
      press("!", 6, "total")
      assert.are.same({ "1", "2" }, ids())
      assert.are.equal(" 2 of 3 rows • filter: total IS NOT NULL", results_lines()[#results_lines()])
    end)

    it("filters by text from a prompt and clears everything with X", function()
      vim.ui.input = function(_, on_confirm)
        on_confirm("name:A")
      end
      press("s", 2, "id")
      press("f", 4, "id")
      assert.are.same({ "2" }, ids())
      press("X", 4, "id")
      assert.are.same({ "1", "2", "3" }, ids())
      assert.are.equal(" 3 rows", results_lines()[#results_lines()])
    end)

    it("says when no row matches the filter", function()
      vim.ui.input = function(_, on_confirm)
        on_confirm("zzz")
      end
      press("f", 4, "id")
      -- The message is truncated to the (narrow) table width like "No rows returned"
      assert.is_not_nil(results_lines()[4]:find(" No rows m", 1, true))
      assert.are.equal(" 0 of 3 rows • filter: contains 'zzz'", results_lines()[#results_lines()])
    end)

    it("exposes the visible rows for export", function()
      press("s", 2, "total")
      press("!", 4, "total")
      local visible, filtered = UI.get_visible_results()
      assert.is_true(filtered)
      assert.are.same({ { "2", "a", "9" }, { "1", "b", "10" } }, visible.rows)
      assert.are.equal(3, #UI.get_current_results().rows)
    end)

    it("follows the foreign key of the cell under the cursor with gf", function()
      local Follow = require("abcql.db.follow")
      local original_follow = Follow.follow
      local called
      Follow.follow = function(ds, database, sql, results, row_idx, col_idx)
        called = { ds = ds.name, database = database, sql = sql, row = results.rows[row_idx][col_idx] }
      end
      -- A history entry: only the datasource name and database are known
      UI.display({ headers = { "id", "customer_id" }, rows = { { "1", "42" }, { "2", "43" } }, row_count = 2 }, nil, {
        query = "SELECT * FROM orders",
        history_position = "history 1/1",
        datasource = { name = "dev", adapter = { config = { database = "shop" } } },
      })
      press("gf", 5, "customer_id")
      Follow.follow = original_follow
      assert.are.same({ ds = "dev", database = "shop", sql = "SELECT * FROM orders", row = "43" }, called)
    end)

    it("resets the view when a new result is displayed", function()
      press("=", 4, "name")
      UI.display({ headers = { "id" }, rows = { { "7" }, { "8" } }, row_count = 2 })
      assert.are.equal(" 2 rows", results_lines()[#results_lines()])
      local _, filtered = UI.get_visible_results()
      assert.is_false(filtered)
    end)
  end)

  describe("history navigation", function()
    local original_stdpath, data_dir, History

    before_each(function()
      data_dir = vim.fn.tempname()
      original_stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(what)
        return what == "data" and data_dir or original_stdpath(what)
      end
      package.loaded["abcql.history"] = nil
      package.loaded["abcql.history.storage"] = nil
      History = require("abcql.history")
      UI.open()
    end)

    after_each(function()
      vim.fn.stdpath = original_stdpath
      vim.fn.delete(data_dir, "rf")
      package.loaded["abcql.history"] = nil
      package.loaded["abcql.history.storage"] = nil
    end)

    --- Save a query like Query.run does and show it as the live result
    local function run(sql, results, err)
      local _, id = History.save(sql, "dev", "shop", results, err)
      UI.display(err or results, nil, { query = sql, history_id = id })
    end

    local function first_cell()
      return results_lines()[4]:match("^│ (%S+)")
    end

    it("shows the previous query on the first step back", function()
      run("SELECT 1", { headers = { "n" }, rows = { { "1" } }, row_count = 1 })
      run("SELECT 2", { headers = { "n" }, rows = { { "2" } }, row_count = 1 })
      UI.history_back()
      assert.are.equal("1", first_cell())
      assert.is_not_nil(
        vim.wo[vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))].winbar:find("history 1/1", 1, true)
      )
      UI.history_forward()
      assert.are.equal("2", first_cell())
    end)

    it("comes back to a live error, not the last table shown", function()
      run("SELECT 1", { headers = { "n" }, rows = { { "1" } }, row_count = 1 })
      run("SELECT nope", nil, "Unknown column 'nope'")
      UI.history_back()
      assert.are.equal("1", first_cell())
      UI.history_forward()
      assert.is_not_nil(table.concat(results_lines(), "\n"):find("Unknown column 'nope'", 1, true))
    end)
  end)

  describe("keys legend", function()
    it("lists every results key in a float that g? closes again", function()
      UI.open()
      local results_buf = vim.fn.bufnr("[abcql] Query Results")
      local results_win = vim.fn.bufwinid(results_buf)
      vim.api.nvim_set_current_win(results_win)

      vim.cmd("normal g?")
      local win = vim.api.nvim_get_current_win()
      assert.are_not.equal(results_win, win)
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):lower()
      vim.cmd("normal g?")
      local still_open = vim.api.nvim_win_is_valid(win)
      pcall(vim.api.nvim_win_close, win, true)

      local missing = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(results_buf, "n")) do
        if map.lhs ~= "g?" and not text:find(map.lhs:lower(), 1, true) then
          table.insert(missing, map.lhs)
        end
      end
      assert.are.same({}, missing)
      assert.is_false(still_open)
      assert.are.equal(results_win, vim.api.nvim_get_current_win())
    end)
  end)

  describe("running indicator", function()
    it("sets and clears the running winbar", function()
      UI.open()
      local ds = require("abcql.db").connectionRegistry:get_datasource("dev")
      UI.set_running("select sleep(1)", ds)
      local results_win = vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))
      assert.is_not_nil(vim.wo[results_win].winbar:find("running", 1, true))
      assert.is_not_nil(vim.wo[results_win].winbar:find("g? keys", 1, true))
      assert.has_no.errors(UI.clear_running)
    end)
  end)

  describe("toggle_tree", function()
    it("opens and closes the tree window", function()
      UI.open()
      UI.toggle_tree()
      assert.is_true(UI.tree_visible())
      local tree_buf = vim.fn.bufnr("[abcql] Data Sources")
      local lines = vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false)
      assert.is_not_nil(lines[2]:find("dev", 1, true))
      UI.toggle_tree()
      assert.is_false(UI.tree_visible())
      assert.has_no.errors(UI.toggle_tree)
      assert.is_true(UI.tree_visible())
    end)
  end)

  describe("close", function()
    it("keeps a pre-existing editor buffer and removes the panels", function()
      local buf = sql_buffer()
      UI.open()
      UI.close()
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      assert.are.equal(-1, vim.fn.bufnr("[abcql] Query Results"))
      assert.is_false(UI.is_valid())
    end)
  end)
end)
