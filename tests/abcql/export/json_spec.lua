-- tests/abcql/export/json_spec.lua
describe("JSON Exporter", function()
  local JSON

  before_each(function()
    JSON = require("abcql.export.json")
  end)

  -- Helper function to check if jq is available
  local function is_jq_available()
    return vim.fn.executable("jq") == 1
  end

  if not is_jq_available() then
    pending("jq not available, skipping JSON export tests")
    return
  end

  it("should export simple results to JSON", function()
    local results = {
      headers = { "id", "name" },
      rows = {
        { "1", "John" },
        { "2", "Jane" },
      },
    }

    local lines, err = JSON.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)

    -- Parse back the JSON to verify structure
    local json_str = table.concat(lines, "\n")
    local parsed = vim.fn.json_decode(json_str)

    assert.are.equal(2, #parsed)
    assert.are.equal("1", parsed[1].id)
    assert.are.equal("John", parsed[1].name)
    assert.are.equal("2", parsed[2].id)
    assert.are.equal("Jane", parsed[2].name)
  end)

  it("should handle nil values", function()
    local results = {
      headers = { "id", "optional" },
      rows = {
        { "1", nil },
      },
    }

    local lines, err = JSON.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)

    local json_str = table.concat(lines, "\n")
    local parsed = vim.fn.json_decode(json_str)

    assert.are.equal(1, #parsed)
    assert.are.equal("1", parsed[1].id)
    -- null in JSON becomes vim.NIL in Neovim's json_decode
    assert.are.equal(vim.NIL, parsed[1].optional)
  end)

  it("should escape special characters in strings", function()
    local results = {
      headers = { "id", "text" },
      rows = {
        { "1", 'text with "quotes"' },
        { "2", "text with\nnewline" },
        { "3", "text with\ttab" },
        { "4", "text\\with\\backslash" },
      },
    }

    local lines, err = JSON.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)

    local json_str = table.concat(lines, "\n")
    local parsed = vim.fn.json_decode(json_str)

    assert.are.equal(4, #parsed)
    assert.are.equal('text with "quotes"', parsed[1].text)
    assert.are.equal("text with\nnewline", parsed[2].text)
    assert.are.equal("text with\ttab", parsed[3].text)
    assert.are.equal("text\\with\\backslash", parsed[4].text)
  end)

  it("should handle empty results", function()
    local results = {
      headers = { "id", "name" },
      rows = {},
    }

    local lines, err = JSON.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)

    local json_str = table.concat(lines, "\n")
    local parsed = vim.fn.json_decode(json_str)

    assert.are.equal(0, #parsed)
  end)

  it("should handle multiple columns", function()
    local results = {
      headers = { "id", "name", "email", "age" },
      rows = {
        { "1", "John Doe", "john@example.com", "30" },
      },
    }

    local lines, err = JSON.export(results)

    assert.is_nil(err)
    assert.is_not_nil(lines)

    local json_str = table.concat(lines, "\n")
    local parsed = vim.fn.json_decode(json_str)

    assert.are.equal(1, #parsed)
    assert.are.equal("1", parsed[1].id)
    assert.are.equal("John Doe", parsed[1].name)
    assert.are.equal("john@example.com", parsed[1].email)
    assert.are.equal("30", parsed[1].age)
  end)

  it("should return error for nil results", function()
    local lines, err = JSON.export(nil)

    assert.is_nil(lines)
    assert.are.equal("No results to export", err)
  end)

  it("should return error for missing headers", function()
    local results = {
      rows = {},
    }

    local lines, err = JSON.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing headers", err)
  end)

  it("should return error for missing rows", function()
    local results = {
      headers = { "id" },
    }

    local lines, err = JSON.export(results)

    assert.is_nil(lines)
    assert.are.equal("Results missing rows", err)
  end)
end)
