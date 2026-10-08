describe("ui.highlights", function()
  local Highlights = require("abcql.ui.highlights")
  local Format = require("abcql.ui.format")

  it("column_starts is not skewed by multibyte header text", function()
    local widths = { 9, 5 }
    local header = Format.format_row({ "post_id ▼", "name" }, widths)
    local row = Format.format_row({ "19", "Alice" }, widths)
    local h = Highlights.column_starts(header, widths)
    local r = Highlights.column_starts(row, widths)
    assert.equals("name", header:sub(h[2].start, h[2].start + 3))
    assert.equals("Alice", row:sub(r[2].start, r[2].start + 4))
  end)

  it("highlights data cells right of a sorted column from their first character", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local widths = { 9, 5 }
    local lines = {
      Format.create_top_border(widths),
      Format.format_row({ "post_id ▼", "name" }, widths),
      Format.create_separator(widths),
      Format.format_row({ "19", "Alice" }, widths),
      Format.create_bottom_border(widths),
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    Highlights.apply_highlights(buf, { headers = { "post_id ▼", "name" }, rows = { { "19", "Alice" } } }, 0, widths)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { 3, 0 }, { 3, -1 }, { details = true })
    local found
    for _, m in ipairs(marks) do
      if m[4].hl_group == "AbcqlString" then
        found = m
      end
    end
    assert.is_not_nil(found)
    assert.equals("Alice", lines[4]:sub(found[3] + 1, found[4].end_col))
  end)
end)
