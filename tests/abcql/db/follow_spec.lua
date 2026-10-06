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
