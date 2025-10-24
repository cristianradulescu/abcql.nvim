# abcql.nvim

> **A Better Client for Query Languages — inside Neovim.**

`abcql.nvim` is a modern, DataGrip and DBeaver inspired database client built entirely for Neovim.  
Run SQL queries, explore schemas, inspect results, and manage connections — all from your favorite editor.

---

## Features

- Connect to MySQL, PostgreSQL, SQLite, and more  
- Interactive query execution with results in split windows  
- Schema and table explorer  

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
