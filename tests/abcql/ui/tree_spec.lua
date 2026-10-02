describe("Tree.browse_table_data", function()
  local Tree, Query
  local original_execute_async
  local sent

  local function browse(datasource)
    Tree.browse_table_data({
      type = "table",
      name = "user_role",
      metadata = { datasource = datasource, database_name = "shop", table_name = "user_role" },
    })
  end

  local function datasource(opts)
    return vim.tbl_extend("force", {
      name = "dev",
      adapter = {
        escape_identifier = function(_, name)
          return "`" .. name .. "`"
        end,
      },
    }, opts or {})
  end

  before_each(function()
    package.loaded["abcql.config"] = nil
    package.loaded["abcql.history"] = { save = function() end }
    Tree = require("abcql.ui.tree")
    Query = require("abcql.db.query")
    Tree.set_display_fn(function() end)
    sent = nil
    original_execute_async = Query.execute_async
    Query.execute_async = function(_, sql, callback, opts)
      sent = { sql = sql, opts = opts }
      callback({ rows = {} }, nil)
    end
  end)

  after_each(function()
    Query.execute_async = original_execute_async
    package.loaded["abcql.history"] = nil
  end)

  it("bounds the result with the configured auto-LIMIT and lifts max_rows", function()
    require("abcql.config").setup({ query = { max_rows = 200, auto_limit = 5000 } })
    browse(datasource())
    assert.are.equal("SELECT * FROM `shop`.`user_role` LIMIT 5000", sent.sql)
    assert.are.equal(0, sent.opts.max_rows)
    assert.are.equal("shop", sent.opts.database)
  end)

  it("prefers the datasource auto_limit", function()
    require("abcql.config").setup({ query = { auto_limit = 5000 } })
    browse(datasource({ auto_limit = 50 }))
    assert.are.equal("SELECT * FROM `shop`.`user_role` LIMIT 50", sent.sql)
  end)

  it("leaves the max_rows cap in place when auto-LIMIT is disabled", function()
    require("abcql.config").setup({ query = { max_rows = 200, auto_limit = false } })
    browse(datasource())
    assert.are.equal("SELECT * FROM `shop`.`user_role`", sent.sql)
    assert.is_nil(sent.opts.max_rows)
  end)
end)
