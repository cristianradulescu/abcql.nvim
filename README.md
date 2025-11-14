# abcql.nvim

> **A Better Client for Query Languages — inside Neovim.**

`abcql.nvim` is a modern, DataGrip and DBeaver inspired database client built entirely for Neovim.  
Run SQL queries, explore schemas, inspect results, and manage connections — all from your favorite editor.

---

## Features

- Connect to MySQL databases via connection strings
- Manage multiple datasources/environments
- Syntax highlighting for SQL queries
- Interactive query execution with results in split windows  
- Schema and table explorer
- Export query results to CSV, TSV, and JSON formats

---

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "cristianradulescu/abcql.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("abcql").setup({
      datasources = {
        bookstore_dev = "mysql://dbuser:dbpassword@localhost:3306/bookstore",
        bookstore_test = "mysql://dbuser:dbpassword@test-srv:3306/bookstore",
        bookstore_prod = "mysql://dbuser:dbpassword@prod-srv:3306/bookstore",
        music_dev = "mysql://dbuser:dbpassword@localhost:3306/music",
      },
    })

    local abcql_ui = require("abcql.ui")
    vim.keymap.set({ "n" }, "<leader>SS", function() abcql_ui.open() end, { desc = "abcql open" })
    vim.keymap.set({ "n" }, "<leader>SC", function() abcql_ui.close() end, { desc = "abcql close" })
    vim.keymap.set({ "n" }, "<leader>ST", function() abcql_ui.toggle_tree() end, { desc = "abcql tree" })
    vim.keymap.set({ "n" }, "<leader>SR", function() abcql_ui.toggle_results() end, { desc = "abcql results" })
    vim.keymap.set({ "n" }, "<leader>Se", function() require("abcql.db.query").execute_query_at_cursor() end, { desc = "abcql execute query" })
    vim.keymap.set({ "n" }, "<leader>SD", function() require("abcql.db").activate_datasource(vim.api.nvim_get_current_buf()) end, { desc = "abcql activate datasource" })
    vim.keymap.set({ "n" }, "<leader>Sxc", function() require("abcql.export").export_current("csv") end, { desc = "abcql export csv" })
    vim.keymap.set({ "n" }, "<leader>Sxj", function() require("abcql.export").export_current("json") end, { desc = "abcql export json" })
  end
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
