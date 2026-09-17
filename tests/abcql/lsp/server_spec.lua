local Cache = require("abcql.lsp.cache")
local Server = require("abcql.lsp.server")

describe("LSP Server", function()
  local cache, server, buf, uri

  local function set_lines(lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  local function params_at(row, col)
    return { textDocument = { uri = uri }, position = { line = row, character = col } }
  end

  local function labels(items)
    local out = {}
    for _, item in ipairs(items) do
      table.insert(out, item.label)
    end
    table.sort(out)
    return out
  end

  local function has(items, label)
    for _, item in ipairs(items) do
      if item.label == label then
        return item
      end
    end
    return nil
  end

  before_each(function()
    package.loaded["abcql.config"] = nil
    cache = Cache.new()
    cache.caches["dev"] = {
      databases = { "shop" },
      tables = { shop = { "Employees", "departments", "dept_emp" } },
      columns = {
        ["shop.Employees"] = { { name = "emp_no", type = "int" }, { name = "first_name", type = "varchar(14)" } },
        ["shop.departments"] = { { name = "dept_no", type = "char(4)" }, { name = "dept_name", type = "varchar(40)" } },
        ["shop.dept_emp"] = { { name = "emp_no", type = "int" }, { name = "dept_no", type = "char(4)" } },
      },
      constraints = {
        ["shop.Employees"] = { primary_key = { "emp_no" }, foreign_keys = {} },
        ["shop.dept_emp"] = {
          primary_key = { "emp_no", "dept_no" },
          foreign_keys = { { column = "dept_no", ref_table = "departments", ref_column = "dept_no" } },
        },
      },
      metadata = { loaded_at = 0 },
    }
    local adapter = {
      escape_identifier = function(_, name)
        return "`" .. name .. "`"
      end,
    }
    server = Server.new(cache, "dev", adapter)
    buf = vim.api.nvim_create_buf(true, false)
    -- Named like a real file so textDocument URIs resolve back to this buffer
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".sql")
    vim.api.nvim_set_current_buf(buf)
    uri = vim.uri_from_bufnr(buf)
  end)

  after_each(function()
    server:handle_shutdown()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  describe("completion", function()
    it("offers columns on the second line of a multi-line SELECT list", function()
      set_lines({ "SELECT", "  emp_no,", "  fi", "FROM Employees;" })
      local items = server:handle_completion(params_at(2, 4))
      assert.is_not_nil(has(items, "first_name"))
      assert.is_nil(has(items, "dept_name"))
    end)

    it("resolves aliases declared after the cursor within the statement", function()
      set_lines({ "SELECT e.", "FROM Employees e;" })
      local items = server:handle_completion(params_at(0, 9))
      assert.are.same(
        { "emp_no", "first_name" },
        labels(vim.tbl_filter(function(i)
          return i.kind == 5
        end, items))
      )
    end)

    it("scopes aliases and tables to the current statement", function()
      set_lines({ "SELECT * FROM departments d;", "", "SELECT d.", "FROM dept_emp d;" })
      local items = server:handle_completion(params_at(2, 9))
      local fields = labels(vim.tbl_filter(function(i)
        return i.kind == 5
      end, items))
      assert.are.same({ "dept_no", "emp_no" }, fields)
    end)

    it("matches table names case-insensitively", function()
      set_lines({ "SELECT  FROM employees;" })
      local items = server:handle_completion(params_at(0, 7))
      assert.is_not_nil(has(items, "first_name"))
    end)

    it("offers tables after a comma in the FROM clause", function()
      set_lines({ "SELECT * FROM Employees, dep" })
      local items = server:handle_completion(params_at(0, 28))
      assert.is_not_nil(has(items, "departments"))
      assert.is_nil(has(items, "dept_name"))
    end)

    it("always includes keywords, ranked after schema items", function()
      set_lines({ "SELECT * FROM Employees WHERE emp_no = 1 AN" })
      local items = server:handle_completion(params_at(0, 43))
      local kw = has(items, "AND")
      assert.is_not_nil(kw)
      set_lines({ "SELECT e FROM Employees" })
      items = server:handle_completion(params_at(0, 8))
      local col = has(items, "emp_no")
      assert.is_not_nil(col)
      assert.is_true(col.sortText < has(items, "EXISTS").sortText)
    end)

    it("offers all columns ranked lower when the statement has no known table", function()
      set_lines({ "SELECT dept_" })
      local items = server:handle_completion(params_at(0, 12))
      local col = has(items, "dept_name")
      assert.is_not_nil(col)
      assert.are.equal("1", col.sortText:sub(1, 1))
    end)

    it("offers tables of a qualified database case-insensitively", function()
      set_lines({ "SELECT * FROM SHOP.dep" })
      local items = server:handle_completion(params_at(0, 22))
      assert.is_not_nil(has(items, "departments"))
    end)

    it("offers INSERT snippets after INSERT INTO", function()
      set_lines({ "INSERT INTO dep" })
      local items = server:handle_completion(params_at(0, 15))
      local snippet = has(items, "departments (…) VALUES (…)")
      assert.is_not_nil(snippet)
      assert.are.equal(2, snippet.insertTextFormat)
      assert.is_not_nil(snippet.insertText:find("${1:dept_no}", 1, true))
    end)

    it("returns nothing without a schema", function()
      cache:clear("dev")
      set_lines({ "SELECT " })
      assert.are.same({}, server:handle_completion(params_at(0, 7)))
    end)
  end)

  describe("hover", function()
    it("describes a table with its columns and keys", function()
      set_lines({ "SELECT * FROM dept_emp;" })
      local hover = server:handle_hover(params_at(0, 16))
      assert.is_not_nil(hover)
      assert.are.equal("markdown", hover.contents.kind)
      assert.is_not_nil(hover.contents.value:find("**shop.dept_emp**", 1, true))
      assert.is_not_nil(hover.contents.value:find("FK → departments.dept_no", 1, true))
      assert.are.equal(14, hover.range.start.character)
    end)

    it("describes an alias-qualified column", function()
      set_lines({ "SELECT e.emp_no FROM Employees e;" })
      local hover = server:handle_hover(params_at(0, 11))
      assert.is_not_nil(hover)
      assert.is_not_nil(hover.contents.value:find("**Employees.emp_no** `int`", 1, true))
      assert.is_not_nil(hover.contents.value:find("Primary key", 1, true))
    end)

    it("finds an unqualified column through the statement's tables", function()
      set_lines({ "SELECT dept_name FROM departments;" })
      local hover = server:handle_hover(params_at(0, 9))
      assert.is_not_nil(hover)
      assert.is_not_nil(hover.contents.value:find("varchar(40)", 1, true))
    end)

    it("returns nil for unknown identifiers", function()
      set_lines({ "SELECT nothing FROM nowhere;" })
      assert.is_nil(server:handle_hover(params_at(0, 9)))
    end)
  end)

  describe("document symbols", function()
    it("lists one symbol per statement", function()
      set_lines({ "SELECT * FROM Employees;", "", "UPDATE departments SET dept_name = 'x'", "WHERE dept_no = 'd1';" })
      local symbols = server:handle_document_symbol({ textDocument = { uri = uri } })
      assert.are.equal(2, #symbols)
      assert.are.equal("SELECT Employees", symbols[1].name)
      assert.are.equal("UPDATE departments", symbols[2].name)
      assert.are.equal(2, symbols[2].range.start.line)
      assert.are.equal(3, symbols[2].range["end"].line)
    end)
  end)

  describe("workspace symbols", function()
    it("returns matching tables and columns", function()
      set_lines({ "" })
      local symbols = server:handle_workspace_symbol({ query = "dep" })
      local names = vim.tbl_map(function(sym)
        return sym.name
      end, symbols)
      assert.is_true(vim.tbl_contains(names, "departments"))
      assert.is_true(vim.tbl_contains(names, "dept_emp"))
      assert.is_true(vim.tbl_contains(names, "dept_name"))
      assert.is_true(vim.tbl_contains(names, "dept_no"))
      assert.is_false(vim.tbl_contains(names, "first_name"))
      assert.is_false(vim.tbl_contains(names, "Employees"))
    end)
  end)

  describe("code actions", function()
    local function action_params(row, col)
      return {
        textDocument = { uri = uri },
        range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
        context = { diagnostics = {} },
      }
    end

    it("offers run, browse, expand-star and INSERT template", function()
      set_lines({ "SELECT * FROM departments;" })
      local actions = server:handle_code_action(action_params(0, 16))
      local titles = {}
      for _, a in ipairs(actions) do
        table.insert(titles, a.title)
      end
      assert.is_true(vim.tbl_contains(titles, "abcql: run this statement"))
      assert.is_true(vim.tbl_contains(titles, "abcql: browse departments"))
      assert.is_true(vim.tbl_contains(titles, "abcql: expand * to the column list"))
      assert.is_true(vim.tbl_contains(titles, "abcql: insert INSERT template for departments"))

      for _, a in ipairs(actions) do
        if a.title == "abcql: expand * to the column list" then
          local edit = a.edit.changes[uri][1]
          assert.are.equal("dept_no, dept_name", edit.newText)
          assert.are.equal(7, edit.range.start.character)
          assert.are.equal(8, edit.range["end"].character)
        elseif a.title == "abcql: browse departments" then
          assert.are.equal("abcql.browse", a.command.command)
          assert.are.equal("SELECT * FROM `shop`.`departments` LIMIT 1000", a.command.arguments[1].sql)
        elseif a.title:match("INSERT template") then
          local edit = a.edit.changes[uri][1]
          assert.is_not_nil(edit.newText:find("INSERT INTO departments (dept_no, dept_name)", 1, true))
          assert.are.equal(0, edit.range.start.line)
        end
      end
    end)

    it("qualifies columns when expanding * over several tables", function()
      set_lines({ "SELECT * FROM Employees e JOIN dept_emp d ON d.emp_no = e.emp_no;" })
      local actions = server:handle_code_action(action_params(0, 3))
      for _, a in ipairs(actions) do
        if a.title == "abcql: expand * to the column list" then
          assert.are.equal(
            "Employees.emp_no, Employees.first_name, dept_emp.emp_no, dept_emp.dept_no",
            a.edit.changes[uri][1].newText
          )
          return
        end
      end
      error("expand action missing")
    end)
  end)

  describe("diagnostics", function()
    it("flags unknown tables with their position", function()
      set_lines({ "SELECT * FROM Employees;", "SELECT *", "FROM nosuch n JOIN departments d;" })
      local diagnostics = server:compute_diagnostics(buf)
      assert.are.equal(1, #diagnostics)
      assert.are.equal(2, diagnostics[1].range.start.line)
      assert.are.equal(5, diagnostics[1].range.start.character)
      assert.is_not_nil(diagnostics[1].message:find("nosuch", 1, true))
    end)

    it("ignores CTE names and CREATE statements", function()
      set_lines({
        "WITH recent AS (SELECT * FROM Employees) SELECT * FROM recent;",
        "CREATE TABLE brand_new (id int);",
      })
      assert.are.same({}, server:compute_diagnostics(buf))
    end)

    it("publishes through the dispatchers after a change", function()
      local published
      server:set_dispatchers({
        notification = function(method, params)
          if method == "textDocument/publishDiagnostics" then
            published = params
          end
        end,
      })
      set_lines({ "SELECT * FROM ghost;" })
      server:handle_notification("textDocument/didChange", { textDocument = { uri = uri } })
      vim.wait(1000, function()
        return published ~= nil
      end)
      assert.is_not_nil(published)
      assert.are.equal(uri, published.uri)
      assert.are.equal(1, #published.diagnostics)
    end)
  end)
end)
