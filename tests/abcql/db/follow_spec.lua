local Cache = require("abcql.lsp.cache")
local Follow = require("abcql.db.follow")

describe("Follow", function()
  local cache, datasource

  before_each(function()
    cache = Cache.new()
    cache.caches["dev"] = {
      databases = { "shop", "other" },
      tables = { shop = { "Customers", "orders", "order_items", "invoices" }, other = { "orders" } },
      columns = {
        ["shop.Customers"] = { { name = "id", type = "int unsigned" }, { name = "code", type = "varchar(10)" } },
        ["shop.orders"] = { { name = "id", type = "int" }, { name = "customer_id", type = "int unsigned" } },
        ["shop.order_items"] = {
          { name = "order_id", type = "int" },
          { name = "line", type = "int" },
          { name = "customer_code", type = "varchar(10)" },
        },
        ["shop.invoices"] = {
          { name = "order_id", type = "int" },
          { name = "line", type = "int" },
          { name = "customer_id", type = "int unsigned" },
        },
        ["other.orders"] = { { name = "id", type = "int" } },
      },
      constraints = {
        ["shop.orders"] = {
          primary_key = { "id" },
          foreign_keys = {
            { column = "customer_id", ref_table = "customers", ref_column = "id", constraint = "fk_cust" },
          },
        },
        ["shop.order_items"] = {
          primary_key = { "order_id", "line" },
          foreign_keys = {
            { column = "order_id", ref_table = "orders", ref_column = "id", constraint = "fk_order" },
            { column = "customer_code", ref_table = "Customers", ref_column = "code", constraint = "fk_code" },
          },
        },
        ["shop.invoices"] = {
          primary_key = {},
          foreign_keys = {
            { column = "order_id", ref_table = "order_items", ref_column = "order_id", constraint = "fk_item" },
            { column = "line", ref_table = "order_items", ref_column = "line", constraint = "fk_item" },
            { column = "customer_id", ref_table = "Customers", ref_column = "id", constraint = "fk_inv_cust" },
          },
        },
      },
      metadata = { loaded_at = 0 },
    }
    datasource = {
      name = "dev",
      adapter = {
        config = { database = "shop" },
        escape_identifier = function(_, name)
          return "`" .. name .. "`"
        end,
        escape_value = function(_, value)
          return value:gsub("'", "''")
        end,
      },
    }
  end)

  describe("targets", function()
    it("finds the foreign key of a column of a queried table", function()
      local targets =
        Follow.targets(cache, "dev", "shop", "SELECT * FROM orders WHERE id > 3", { "id", "customer_id" }, 2)
      assert.are.equal(1, #targets)
      assert.are.same({
        database = "shop",
        table = "orders",
        ref_database = "shop",
        ref_table = "Customers",
        columns = { "customer_id" },
        ref_columns = { "id" },
        col_indices = { 2 },
      }, targets[1])
    end)

    it("finds nothing for a column that is not a foreign key", function()
      assert.are.same({}, Follow.targets(cache, "dev", "shop", "SELECT * FROM orders", { "id", "customer_id" }, 1))
    end)

    it("ignores tables the query doesn't use", function()
      local targets = Follow.targets(cache, "dev", "shop", "SELECT * FROM customers", { "customer_id" }, 1)
      assert.are.same({}, targets)
    end)

    it("needs every column of a composite key in the result", function()
      local sql = "SELECT * FROM invoices"
      assert.are.same({}, Follow.targets(cache, "dev", "shop", sql, { "order_id", "customer_id" }, 1))
      local targets = Follow.targets(cache, "dev", "shop", sql, { "line", "order_id", "customer_id" }, 2)
      assert.are.equal(1, #targets)
      assert.are.same({ "order_id", "line" }, targets[1].columns)
      assert.are.same({ 2, 1 }, targets[1].col_indices)
    end)

    it("lists keys of joined tables pointing at the same row once", function()
      local sql = "SELECT o.customer_id FROM orders o JOIN invoices i ON i.order_id = o.id"
      local targets = Follow.targets(cache, "dev", "shop", sql, { "customer_id" }, 1)
      assert.are.equal(1, #targets)
    end)

    it("offers every key when a shared column name points at different tables", function()
      local sql = "SELECT * FROM order_items JOIN invoices USING (order_id, line)"
      local targets = Follow.targets(cache, "dev", "shop", sql, { "order_id", "line", "customer_code" }, 1)
      assert.are.same(
        { "order_items.order_id → orders.id", "invoices.(order_id, line) → order_items.(order_id, line)" },
        vim.tbl_map(Follow.label, targets)
      )
    end)
  end)

  describe("build_sql", function()
    local function target_for(sql, headers, col)
      return Follow.targets(cache, "dev", "shop", sql, headers, col)[1]
    end

    it("selects the referenced row, with a bare number for a numeric column", function()
      local target = target_for("SELECT * FROM orders", { "id", "customer_id" }, 2)
      assert.are.equal(
        "SELECT * FROM `Customers` WHERE `id` = 42",
        Follow.build_sql(cache, datasource, target, { "7", "42" })
      )
    end)

    it("quotes and escapes values of other columns", function()
      local target = target_for("SELECT * FROM order_items", { "order_id", "customer_code" }, 2)
      assert.are.equal(
        "SELECT * FROM `Customers` WHERE `code` = 'O''Brien'",
        Follow.build_sql(cache, datasource, target, { "1", "O'Brien" })
      )
    end)

    it("matches every column of a composite key", function()
      local target = target_for("SELECT * FROM invoices", { "order_id", "line" }, 1)
      assert.are.equal(
        "SELECT * FROM `order_items` WHERE `order_id` = 5 AND `line` = 2",
        Follow.build_sql(cache, datasource, target, { "5", "2" })
      )
    end)

    it("qualifies a table outside the connection's database", function()
      datasource.adapter.config.database = "other"
      local target = target_for("SELECT * FROM orders", { "id", "customer_id" }, 2)
      assert.are.equal(
        "SELECT * FROM `shop`.`Customers` WHERE `id` = 42",
        Follow.build_sql(cache, datasource, target, { "7", "42" })
      )
    end)

    it("refuses a NULL key", function()
      local target = target_for("SELECT * FROM orders", { "id", "customer_id" }, 2)
      local sql, err = Follow.build_sql(cache, datasource, target, { "7", "NULL" })
      assert.is_nil(sql)
      assert.are.equal("customer_id is NULL, it references nothing", err)
    end)
  end)

  describe("preview_lines", function()
    local target

    before_each(function()
      target = Follow.targets(cache, "dev", "shop", "SELECT * FROM orders", { "id", "customer_id" }, 2)[1]
    end)

    it("lists every column of the referenced row, aligned", function()
      local result = {
        headers = { "id", "code", "a", "b", "c", "d" },
        rows = { { "42", "multi\nline", "1", vim.NIL, "3", "4" } },
      }
      assert.are.same({
        "→ orders.customer_id → Customers.id",
        "  id    42",
        "  code  multi ↵ line",
        "  a     1",
        "  b     NULL",
        "  c     3",
        "  d     4",
      }, Follow.preview_lines(target, result, nil, 80))
    end)

    it("cuts values so each line fits the width", function()
      local result = { headers = { "id", "title" }, rows = { { "42", "Lorem ipsum dolor sit amet" } } }
      local lines = Follow.preview_lines(target, result, nil, 20)
      assert.are.same({ "  id     42", "  title  Lorem ipsu…" }, { lines[2], lines[3] })
      assert.are.equal(20, vim.fn.strdisplaywidth(lines[3]))
    end)

    it("returns the byte range of each column name", function()
      local result = { headers = { "id", "name" }, rows = { { "42", "Alice" } } }
      local _, names = Follow.preview_lines(target, result, nil, 80)
      assert.are.same({
        { line = 2, col_start = 2, col_end = 4 },
        { line = 3, col_start = 2, col_end = 6 },
      }, names)
    end)

    it("says when no row is referenced", function()
      local lines = Follow.preview_lines(target, { headers = { "id" }, rows = {} }, nil, 80)
      assert.are.equal("  (no referenced row found)", lines[2])
    end)

    it("shows the error", function()
      local lines = Follow.preview_lines(target, nil, "boom\nagain", 80)
      assert.are.equal("  boom again", lines[2])
    end)
  end)

  describe("preview", function()
    local LSP, Query
    local original_has_schema, original_get_cache, original_execute

    before_each(function()
      LSP, Query = require("abcql.lsp"), require("abcql.db.query")
      original_has_schema, original_get_cache, original_execute = LSP.has_schema, LSP.get_cache, Query.execute_async
      LSP.has_schema = function()
        return true
      end
      LSP.get_cache = function()
        return cache
      end
    end)

    after_each(function()
      LSP.has_schema, LSP.get_cache, Query.execute_async = original_has_schema, original_get_cache, original_execute
    end)

    it("fetches the referenced row, one row only", function()
      local sent, got
      Query.execute_async = function(adapter, sql, callback, opts)
        sent = { sql = sql, opts = opts }
        callback({ headers = { "id" }, rows = { { "42" } } }, nil)
      end
      local results = { headers = { "id", "customer_id" }, rows = { { "7", "42" } } }
      Follow.preview(datasource, "shop", "SELECT * FROM orders", results, 1, 2, 80, function(lines)
        got = lines
      end)
      assert.are.equal("SELECT * FROM `Customers` WHERE `id` = 42", sent.sql)
      assert.are.same({ max_rows = 1 }, sent.opts)
      assert.are.same({ "→ orders.customer_id → Customers.id", "  id  42" }, got)
    end)

    it("does nothing for a column that is not a foreign key or a NULL key", function()
      Query.execute_async = function()
        error("should not run")
      end
      local results = { headers = { "id", "customer_id" }, rows = { { "7", "NULL" } } }
      Follow.preview(datasource, "shop", "SELECT * FROM orders", results, 1, 1, 80, function()
        error("should not call back")
      end)
      Follow.preview(datasource, "shop", "SELECT * FROM orders", results, 1, 2, 80, function()
        error("should not call back")
      end)
    end)
  end)

  describe("follow", function()
    local original_has_schema, original_get_cache, original_run, original_notify

    before_each(function()
      local LSP = require("abcql.lsp")
      local Query = require("abcql.db.query")
      original_has_schema, original_get_cache, original_run = LSP.has_schema, LSP.get_cache, Query.run
      original_notify = vim.notify
      LSP.has_schema = function()
        return true
      end
      LSP.get_cache = function()
        return cache
      end
    end)

    after_each(function()
      local LSP = require("abcql.lsp")
      LSP.has_schema, LSP.get_cache = original_has_schema, original_get_cache
      require("abcql.db.query").run = original_run
      vim.notify = original_notify
    end)

    it("runs the SELECT through Query.run without a confirmation", function()
      local ran
      require("abcql.db.query").run = function(sql, ds, opts)
        ran = { sql = sql, ds = ds, opts = opts }
      end
      local results = { headers = { "id", "customer_id" }, rows = { { "7", "42" } } }
      Follow.follow(datasource, "shop", "SELECT * FROM orders", results, 1, 2)
      assert.are.equal("SELECT * FROM `Customers` WHERE `id` = 42", ran.sql)
      assert.are.equal(datasource, ran.ds)
      assert.are.same({ confirm = false }, ran.opts)
    end)

    it("says so when the column is not a foreign key", function()
      local message
      vim.notify = function(msg)
        message = msg
      end
      require("abcql.db.query").run = function()
        error("should not run")
      end
      local results = { headers = { "id", "customer_id" }, rows = { { "7", "42" } } }
      Follow.follow(datasource, "shop", "SELECT * FROM orders", results, 1, 1)
      assert.are.equal("abcql: id is not a foreign key of the queried tables", message)
    end)
  end)
end)
