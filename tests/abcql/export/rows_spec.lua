describe("Rows Exporter", function()
  local Rows = require("abcql.export.rows")

  local function run(rows, headers)
    return Rows.export({ headers = headers or { "v" }, rows = rows })
  end

  it("puts each value on its own line, unquoted", function()
    assert.are.same({ "1", "it's", "c" }, run({ { "1" }, { "it's" }, { "c" } }))
  end)

  it("skips NULLs", function()
    assert.are.same({ "a", "b" }, run({ { "a" }, { "NULL" }, { "b" } }))
  end)

  it("flattens every column of a row", function()
    assert.are.same({ "1", "a", "2", "b" }, run({ { "1", "a" }, { "2", "b" } }, { "id", "name" }))
  end)

  it("replaces newlines inside a value with spaces", function()
    assert.are.same({ "a b c" }, run({ { "a\nb\r\nc" } }))
  end)

  it("errors when there are no values", function()
    local _, err = run({ { "NULL" } })
    assert.is_not_nil(err)
  end)
end)
