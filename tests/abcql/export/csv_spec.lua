-- tests/abcql/export/csv_spec.lua
describe("CSV Exporter", function()
  local CSV

  before_each(function()
    CSV = require("abcql.export.csv")
  end)

  it("should export simple results to CSV", function()
    local results = {
      headers = { "id", "name", "email" },
      rows = {
        { "1", "John Doe", "john@example.com" },
        { "2", "Jane Smith", "jane@example.com" },
      },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal(3, #lines) -- header + 2 rows
    assert.are.equal("id,name,email", lines[1])
    assert.are.equal("1,John Doe,john@example.com", lines[2])
    assert.are.equal("2,Jane Smith,jane@example.com", lines[3])
  end)

  it("should escape fields with commas", function()
    local results = {
      headers = { "id", "address" },
      rows = {
        { "1", "123 Main St, Apt 4" },
      },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal('1,"123 Main St, Apt 4"', lines[2])
  end)

  it("should escape fields with double quotes", function()
    local results = {
      headers = { "id", "quote" },
      rows = {
        { "1", 'He said "hello"' },
      },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal('1,"He said ""hello"""', lines[2])
  end)

  it("should escape fields with newlines", function()
    local results = {
      headers = { "id", "text" },
      rows = {
        { "1", "line1\nline2" },
      },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal('1,"line1\nline2"', lines[2])
  end)

  it("should handle empty results", function()
    local results = {
      headers = { "id", "name" },
      rows = {},
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal(1, #lines) -- only header
    assert.are.equal("id,name", lines[1])
  end)

  it("should handle nil values", function()
    local results = {
      headers = { "id", "optional" },
      rows = {
        { "1", nil },
      },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal("1,", lines[2]) -- nil becomes empty field
  end)

  it("should return error for nil results", function()
    local lines, err = CSV.export(nil)

    assert.is_nil(lines)
    assert.are.equal("No results to export", err)
  end)

  it("should return error for missing headers", function()
    local results = {
      rows = {},
    }

    local lines, err = CSV.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing headers", err)
  end)

  it("should return error for missing rows", function()
    local results = {
      headers = { "id" },
    }

    local lines, err = CSV.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing rows", err)
  end)
end)
