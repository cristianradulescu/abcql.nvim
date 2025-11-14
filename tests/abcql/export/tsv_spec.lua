-- tests/abcql/export/tsv_spec.lua
describe("TSV Exporter", function()
  local TSV

  before_each(function()
    TSV = require("abcql.export.tsv")
  end)

  it("should export simple results to TSV", function()
    local results = {
      headers = { "id", "name", "email" },
      rows = {
        { "1", "John Doe", "john@example.com" },
        { "2", "Jane Smith", "jane@example.com" },
      },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal(3, #lines) -- header + 2 rows
    assert.are.equal("id\tname\temail", lines[1])
    assert.are.equal("1\tJohn Doe\tjohn@example.com", lines[2])
    assert.are.equal("2\tJane Smith\tjane@example.com", lines[3])
  end)

  it("should sanitize fields with tabs", function()
    local results = {
      headers = { "id", "text" },
      rows = {
        { "1", "text\twith\ttabs" },
      },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal("1\ttext with tabs", lines[2])
  end)

  it("should sanitize fields with newlines", function()
    local results = {
      headers = { "id", "text" },
      rows = {
        { "1", "line1\nline2" },
      },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal("1\tline1 line2", lines[2])
  end)

  it("should sanitize fields with carriage returns", function()
    local results = {
      headers = { "id", "text" },
      rows = {
        { "1", "line1\r\nline2" },
      },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal("1\tline1  line2", lines[2])
  end)

  it("should handle empty results", function()
    local results = {
      headers = { "id", "name" },
      rows = {},
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal(1, #lines) -- only header
    assert.are.equal("id\tname", lines[1])
  end)

  it("should handle nil values", function()
    local results = {
      headers = { "id", "optional" },
      rows = {
        { "1", nil },
      },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)
    assert.are.equal("1\t", lines[2]) -- nil becomes empty field
  end)

  it("should return error for nil results", function()
    local lines, err = TSV.export(nil)

    assert.is_nil(lines)
    assert.are.equal("No results to export", err)
  end)

  it("should return error for missing headers", function()
    local results = {
      rows = {},
    }

    local lines, err = TSV.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing headers", err)
  end)

  it("should return error for missing rows", function()
    local results = {
      headers = { "id" },
    }

    local lines, err = TSV.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing rows", err)
  end)
end)
