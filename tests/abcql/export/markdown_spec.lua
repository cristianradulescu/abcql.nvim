describe("Markdown Exporter", function()
  local Markdown = require("abcql.export.markdown")

  it("renders a padded pipe table", function()
    local lines = Markdown.export({ headers = { "id", "name" }, rows = { { "1", "alice" }, { "22", "bo" } } })
    assert.are.same({
      "| id  | name  |",
      "| --- | ----- |",
      "| 1   | alice |",
      "| 22  | bo    |",
    }, lines)
  end)

  it("escapes pipes and turns line breaks into <br>", function()
    local lines = Markdown.export({ headers = { "v" }, rows = { { "a|b" }, { "x\r\ny\nz" } } })
    assert.are.same("| a\\|b        |", lines[3])
    assert.are.same("| x<br>y<br>z |", lines[4])
  end)

  it("keeps NULLs and handles nil cells", function()
    local lines = Markdown.export({ headers = { "a", "b" }, rows = { { "NULL" } } })
    assert.are.same("| NULL | NULL |", lines[3])
  end)

  it("pads by display width", function()
    local lines = Markdown.export({ headers = { "n" }, rows = { { "héllo" }, { "日本" } } })
    assert.are.same("| héllo |", lines[3])
    assert.are.same("| 日本  |", lines[4])
  end)

  it("renders only the header for empty results", function()
    local lines = Markdown.export({ headers = { "a" }, rows = {} })
    assert.are.same({ "| a   |", "| --- |" }, lines)
  end)

  it("errors on invalid results", function()
    local _, err = Markdown.export(nil)
    assert.is_not_nil(err)
  end)
end)
