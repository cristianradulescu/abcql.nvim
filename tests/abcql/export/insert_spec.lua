describe("Insert Exporter", function()
  local Insert = require("abcql.export.insert")
  local MySQLAdapter = require("abcql.db.adapter.mysql")
  local SQLiteAdapter = require("abcql.db.adapter.sqlite")

  local results = {
    headers = { "id", "name", "note" },
    rows = { { "1", "O'Brien", "NULL" }, { "2", "x", "007" } },
  }

  it("writes one multi-row statement for the given table", function()
    assert.are.same({
      "INSERT INTO users (id, name, note)",
      "VALUES",
      "  (1, 'O''Brien', NULL),",
      "  (2, 'x', '007');",
    }, Insert.export(results, { table = "users" }))
  end)

  it("uses a placeholder when the table is unknown", function()
    local lines = Insert.export(results)
    assert.are.equal("INSERT INTO <table> (id, name, note)", lines[1])
  end)

  it("escapes identifiers through the adapter", function()
    local adapter = MySQLAdapter.new({})
    local lines = Insert.export({ headers = { "a b" }, rows = { { "1" } } }, { table = "t", adapter = adapter })
    assert.are.equal("INSERT INTO `t` (`a b`)", lines[1])
  end)

  it("doubles backslashes for MySQL but not SQLite", function()
    local data = { headers = { "p" }, rows = { { "C:\\x" } } }
    local mysql = Insert.export(data, { table = "t", adapter = MySQLAdapter.new({}) })
    local sqlite = Insert.export(data, { table = "t", adapter = SQLiteAdapter.new({}) })
    assert.are.equal("  ('C:\\\\x');", mysql[3])
    assert.are.equal("  ('C:\\x');", sqlite[3])
  end)

  it("keeps BLOB hex bare", function()
    assert.are.equal("  (0xCAFE);", Insert.export({ headers = { "b" }, rows = { { "0xCAFE" } } })[3])
  end)

  it("errors without rows", function()
    local _, err = Insert.export({ headers = { "a" }, rows = {} })
    assert.is_not_nil(err)
  end)
end)
