describe("Update Exporter", function()
  local Update = require("abcql.export.update")
  local MySQLAdapter = require("abcql.db.adapter.mysql")

  local results = {
    headers = { "id", "name", "note" },
    rows = { { "1", "O'Brien", "NULL" }, { "2", "x", "007" } },
  }

  it("writes one statement per row, leaving the key column out of SET", function()
    assert.are.same({
      "UPDATE users SET name = 'O''Brien', note = NULL WHERE id = 1;",
      "UPDATE users SET name = 'x', note = '007' WHERE id = 2;",
    }, Update.export(results, { table = "users", key_indices = { 1 } }))
  end)

  it("works with a key column in the middle", function()
    local lines = Update.export(results, { table = "t", key_indices = { 2 } })
    assert.are.equal("UPDATE t SET id = 1, note = NULL WHERE name = 'O''Brien';", lines[1])
  end)

  it("matches a NULL key with IS NULL", function()
    local lines = Update.export(results, { table = "t", key_indices = { 3 } })
    assert.are.equal("UPDATE t SET id = 1, name = 'O''Brien' WHERE note IS NULL;", lines[1])
  end)

  it("uses a placeholder table and escapes identifiers through the adapter", function()
    assert.are.equal(
      "UPDATE <table> SET name = 'x' WHERE id = 1;",
      Update.export({ headers = { "id", "name" }, rows = { { "1", "x" } } }, { key_indices = { 1 } })[1]
    )
    local lines = Update.export(
      { headers = { "id", "a b" }, rows = { { "1", "x" } } },
      { table = "t", adapter = MySQLAdapter.new({}), key_indices = { 1 } }
    )
    assert.are.equal("UPDATE `t` SET `a b` = 'x' WHERE `id` = 1;", lines[1])
  end)

  it("joins several WHERE columns with AND and leaves them all out of SET", function()
    local lines = Update.export(results, { table = "t", key_indices = { 1, 3 } })
    assert.are.equal("UPDATE t SET name = 'O''Brien' WHERE id = 1 AND note IS NULL;", lines[1])
    assert.are.equal("UPDATE t SET name = 'x' WHERE id = 2 AND note = '007';", lines[2])
  end)

  it("counts a column picked twice once", function()
    local lines = Update.export(results, { table = "t", key_indices = { 1, 1 } })
    assert.are.equal("UPDATE t SET name = 'O''Brien', note = NULL WHERE id = 1;", lines[1])
  end)

  it("errors when every column is a WHERE column", function()
    local _, err = Update.export(results, { table = "t", key_indices = { 1, 2, 3 } })
    assert.is_not_nil(err)
  end)

  it("errors without a WHERE column", function()
    local _, err = Update.export(results, { table = "t" })
    assert.are.equal("No WHERE column selected", err)
  end)

  it("errors when there is nothing to set", function()
    local _, err = Update.export({ headers = { "id" }, rows = { { "1" } } }, { key_indices = { 1 } })
    assert.is_not_nil(err)
  end)
end)
