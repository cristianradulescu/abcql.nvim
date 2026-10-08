describe("Values Exporter", function()
  local Values = require("abcql.export.values")

  local function run(rows, headers)
    return Values.export({ headers = headers or { "v" }, rows = rows })
  end

  it("leaves numbers bare", function()
    assert.are.same({ "1, 2, -3.5" }, run({ { "1" }, { "2" }, { "-3.5" } }))
  end)

  it("quotes strings and doubles single quotes", function()
    assert.are.same({ "'a', 'it''s'" }, run({ { "a" }, { "it's" } }))
  end)

  it("quotes everything when any value is non-numeric or has leading zeros", function()
    assert.are.same({ "'1', 'x'" }, run({ { "1" }, { "x" } }))
    assert.are.same({ "'007', '8'" }, run({ { "007" }, { "8" } }))
  end)

  it("skips NULLs", function()
    assert.are.same({ "1, 2" }, run({ { "1" }, { "NULL" }, { "2" } }))
  end)

  it("flattens every column of a row", function()
    assert.are.same({ "'1', 'a'" }, run({ { "1", "a" } }, { "id", "name" }))
  end)

  it("errors when there are no values", function()
    local _, err = run({ { "NULL" } })
    assert.is_not_nil(err)
  end)
end)
