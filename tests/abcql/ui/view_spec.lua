local View = require("abcql.ui.view")

describe("abcql.ui.view", function()
  local results

  --- Values of one column in view order
  local function column(view, col)
    local out = {}
    for _, i in ipairs(View.compute(results, view)) do
      table.insert(out, results.rows[i][col])
    end
    return out
  end

  before_each(function()
    results = {
      headers = { "id", "name", "total", "created_at", "data" },
      rows = {
        { "1", "Alice", "10", "2024-03-01 10:00:00", "0x0A" },
        { "2", "bob", "9", "2024-01-15 08:30:00", "0xFF" },
        { "3", "Carol", "NULL", "2023-12-31 23:59:59", "NULL" },
        { "4", "dave", "100", "NULL", "0x01" },
        { "5", "Eve", "9", "2024-01-15 08:30:00", "0x0B" },
      },
    }
  end)

  describe("compute", function()
    it("returns every row in order without a view", function()
      assert.are.same({ 1, 2, 3, 4, 5 }, View.compute(results, nil))
      assert.are.same({ 1, 2, 3, 4, 5 }, View.compute(results, View.new()))
    end)

    it("handles an empty result", function()
      assert.are.same({}, View.compute({ headers = { "a" }, rows = {} }, View.new()))
    end)
  end)

  describe("sort", function()
    it("compares numeric columns as numbers", function()
      local view = View.new()
      View.cycle_sort(view, 3)
      assert.are.same({ "NULL", "9", "9", "10", "100" }, column(view, 3))
    end)

    it("puts NULLs first ascending and last descending", function()
      local view = { sort = { col = 3, dir = "desc" }, filters = {} }
      assert.are.same({ "100", "10", "9", "9", "NULL" }, column(view, 3))
    end)

    it("keeps ties in the original order in both directions", function()
      assert.are.same({ 4, 1, 2, 5, 3 }, View.compute(results, { sort = { col = 3, dir = "desc" }, filters = {} }))
      assert.are.same({ 3, 2, 5, 1, 4 }, View.compute(results, { sort = { col = 3, dir = "asc" }, filters = {} }))
    end)

    it("compares text columns byte-wise", function()
      local view = { sort = { col = 2, dir = "asc" }, filters = {} }
      assert.are.same({ "Alice", "Carol", "Eve", "bob", "dave" }, column(view, 2))
    end)

    it("orders ISO datetimes chronologically", function()
      local view = { sort = { col = 4, dir = "asc" }, filters = {} }
      assert.are.same(
        { "NULL", "2023-12-31 23:59:59", "2024-01-15 08:30:00", "2024-01-15 08:30:00", "2024-03-01 10:00:00" },
        column(view, 4)
      )
    end)

    it("treats hex binary cells as text, not numbers", function()
      local view = { sort = { col = 5, dir = "asc" }, filters = {} }
      assert.are.same({ "NULL", "0x01", "0x0A", "0x0B", "0xFF" }, column(view, 5))
    end)

    it("falls back to text when any cell is not a number", function()
      results.rows[1][3] = "n/a"
      local view = { sort = { col = 3, dir = "asc" }, filters = {} }
      assert.are.same({ "NULL", "100", "9", "9", "n/a" }, column(view, 3))
    end)

    it("handles decimals, negatives and exponents", function()
      results = { headers = { "n" }, rows = { { "1.5" }, { "-2" }, { "1e3" }, { "0.25" } } }
      local view = { sort = { col = 1, dir = "asc" }, filters = {} }
      assert.are.same({ "-2", "0.25", "1.5", "1e3" }, column(view, 1))
    end)

    it("cycles asc → desc → off, and restarts at asc on another column", function()
      local view = View.new()
      View.cycle_sort(view, 2)
      assert.are.same({ col = 2, dir = "asc" }, view.sort)
      View.cycle_sort(view, 2)
      assert.are.same({ col = 2, dir = "desc" }, view.sort)
      View.cycle_sort(view, 2)
      assert.is_nil(view.sort)
      View.cycle_sort(view, 2)
      View.cycle_sort(view, 3)
      assert.are.same({ col = 3, dir = "asc" }, view.sort)
    end)
  end)

  describe("filters", function()
    it("keeps rows equal to a cell value", function()
      local view = View.new()
      View.add_filter(view, View.cell_filter(3, "9"))
      assert.are.same({ 2, 5 }, View.compute(results, view))
    end)

    it("drops rows equal to a cell value, keeping NULLs", function()
      local view = View.new()
      View.add_filter(view, View.cell_filter(3, "9", true))
      assert.are.same({ 1, 3, 4 }, View.compute(results, view))
    end)

    it("turns a NULL cell into IS NULL / IS NOT NULL", function()
      assert.are.same({ kind = "null", col = 3 }, View.cell_filter(3, "NULL"))
      assert.are.same({ kind = "not_null", col = 3 }, View.cell_filter(3, nil, true))
      local view = View.new()
      View.add_filter(view, View.cell_filter(3, "NULL"))
      assert.are.same({ 3 }, View.compute(results, view))
      view = View.new()
      View.add_filter(view, View.cell_filter(3, "NULL", true))
      assert.are.same({ 1, 2, 4, 5 }, View.compute(results, view))
    end)

    it("matches text case-insensitively in any column", function()
      local view = View.new()
      View.add_filter(view, View.parse_text_filter("AL", results.headers))
      assert.are.same({ 1 }, View.compute(results, view))
    end)

    it("restricts text to one column with col:text", function()
      local filter = View.parse_text_filter("Created_At:2024-01", results.headers)
      assert.are.same({ kind = "text", col = 4, text = "2024-01" }, filter)
      local view = View.new()
      View.add_filter(view, filter)
      assert.are.same({ 2, 5 }, View.compute(results, view))
    end)

    it("keeps a colon prefix that is not a column name as text", function()
      assert.are.same({ kind = "text", text = "08:30" }, View.parse_text_filter("08:30", results.headers))
    end)

    it("ignores empty input", function()
      assert.is_nil(View.parse_text_filter("", results.headers))
      assert.is_nil(View.parse_text_filter(nil, results.headers))
      assert.is_nil(View.parse_text_filter("name:", results.headers))
    end)

    it("combines filters with AND and applies the sort after filtering", function()
      local view = View.new()
      View.add_filter(view, View.parse_text_filter("2024", results.headers))
      View.add_filter(view, View.cell_filter(3, "10", true))
      View.cycle_sort(view, 1)
      View.cycle_sort(view, 1)
      assert.are.same({ 5, 2 }, View.compute(results, view))
    end)

    it("pops the last filter and clears everything", function()
      local view = View.new()
      View.add_filter(view, View.cell_filter(3, "9"))
      View.add_filter(view, View.cell_filter(2, "bob"))
      assert.is_true(View.pop_filter(view))
      assert.are.same({ 2, 5 }, View.compute(results, view))
      View.cycle_sort(view, 1)
      View.clear(view)
      assert.is_false(View.is_active(view))
      assert.is_false(View.pop_filter(view))
    end)
  end)

  describe("description", function()
    it("describes filters and sort for the footer", function()
      local view = View.new()
      View.add_filter(view, View.cell_filter(2, "O'Brien"))
      View.add_filter(view, View.cell_filter(3, "NULL", true))
      View.add_filter(view, View.parse_text_filter("x", results.headers))
      View.add_filter(view, View.parse_text_filter("name:y", results.headers))
      View.cycle_sort(view, 4)
      View.cycle_sort(view, 4)
      assert.are.same({
        "filter: name = 'O''Brien' AND total IS NOT NULL AND contains 'x' AND name contains 'y'",
        "sorted by created_at ▼",
      }, View.describe(view, results.headers))
      assert.are.same({}, View.describe(View.new(), results.headers))
    end)

    it("adds the sort indicator to the sorted header only", function()
      local view = View.new()
      View.cycle_sort(view, 2)
      assert.are.same({ "id", "name ▲", "total", "created_at", "data" }, View.header_labels(results.headers, view))
      assert.are.same(results.headers, View.header_labels(results.headers, nil))
    end)

    it("materializes the visible rows", function()
      local view = View.new()
      View.add_filter(view, View.cell_filter(3, "9"))
      assert.are.same({ results.rows[2], results.rows[5] }, View.rows(results, View.compute(results, view)))
    end)
  end)
end)
