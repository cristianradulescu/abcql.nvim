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

    it("shows the datasource, query and summary in the results winbar", function()
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
      assert.is_not_nil(winbar:find("select * from t", 1, true))
      assert.is_not_nil(winbar:find("0 rows", 1, true))
    end)

    it("renders errors and clears stored results", function()
      UI.open()
      UI.display({ headers = { "a" }, rows = { { "1" } }, row_count = 1 })
      UI.display("boom")
      assert.is_nil(UI.get_current_results())
      assert.is_not_nil(table.concat(results_lines(), "\n"):find("boom", 1, true))
    end)

    it("shows the query above the results when browsing history", function()
      UI.open()
      UI.display(
        { headers = { "a" }, rows = { { "1" } }, row_count = 1 },
        nil,
        { query = "select 1", history_position = "history 1/3" }
      )
      local lines = results_lines()
      assert.are.equal(" Query:", lines[2])
      assert.are.equal("   select 1", lines[4])
    end)
  end)

  describe("running indicator", function()
    it("sets and clears the running winbar", function()
      UI.open()
      local ds = require("abcql.db").connectionRegistry:get_datasource("dev")
      UI.set_running("select sleep(1)", ds)
      local results_win = vim.fn.bufwinid(vim.fn.bufnr("[abcql] Query Results"))
      assert.is_not_nil(vim.wo[results_win].winbar:find("running", 1, true))
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
