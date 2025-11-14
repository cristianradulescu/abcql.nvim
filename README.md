# abcql.nvim

> **A Better Client for Query Languages — inside Neovim.**

`abcql.nvim` is a modern, DataGrip and DBeaver inspired database client built entirely for Neovim.  
Run SQL queries, explore schemas, inspect results, and manage connections — all from your favorite editor.

---

## Features

- Connect to MySQL, PostgreSQL, SQLite, and more  
- Interactive query execution with results in split windows  
- Schema and table explorer
- Export query results to CSV, TSV, and JSON formats

---

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "cristianradulescu/abcql.nvim",
  config = function()
    require("abcql").setup()
  end,
}
```

---

## Usage

### Exporting Query Results

After executing a query and viewing results, you can export them to various formats:

#### User Commands

- `:AbcqlExportCsv` - Export current results to CSV format
- `:AbcqlExportTsv` - Export current results to TSV format  
- `:AbcqlExportJson` - Export current results to JSON format (requires `jq` installed)

Files are saved to your current working directory with auto-generated names like `query_YYYYMMDD_HHMMSS.csv`.

#### Export Format Details

**CSV (Comma-Separated Values)**
- RFC 4180 compliant
- Fields containing commas, quotes, or newlines are automatically wrapped in double quotes
- Internal quotes are escaped by doubling them

**TSV (Tab-Separated Values)**
- Tab-separated fields
- Tabs and newlines in values are replaced with spaces
- No quoting required

**JSON**
- Array of objects format
- Pretty-printed using `jq` (must be installed)
- Special characters properly escaped
- Null values preserved
