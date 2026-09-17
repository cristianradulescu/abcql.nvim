# abcql.nvim

> **A Better Client for Query Languages — inside Neovim.**

`abcql.nvim` is a modern, DataGrip and DBeaver inspired database client built entirely for Neovim.  
Run SQL queries, explore schemas, inspect results, and manage connections — all from your favorite editor.

![Overview](./docs/abcql-overview.png)

---

## Features

- Connect to MySQL databases via connection strings
- Manage multiple datasources/environments, with a per-project default and per-file
  `-- abcql: <name>` overrides so `.sql` files attach themselves
- Run the statement under the cursor, a visual selection, or a whole file; cancel long queries
- Confirmation prompts only for statements that write (configurable), `readonly` datasources
- Results panel with cell popup/yank, cell motions, row cap, and a context winbar
  (datasource, statement, row count, duration)
- Schema and table explorer (toggle with `<leader>ST`; hidden by default) with reload, filter,
  and yank/insert of qualified names
- Query history with a picker to re-run or paste past queries
- Export query results to CSV, TSV, and JSON formats
- SQL completion with LSP support (databases, tables, columns, keywords)
- Queries run through `abcql-backend`, a small Go binary bundled in this repo that talks to MySQL
  directly (no `mysql` CLI required) — see [Backend](#backend)

---

## Installation

`abcql.nvim` ships with `abcql-backend`, a Go binary that executes your queries. It needs to be built
once (and again after each plugin update) — see [Backend](#backend).

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "cristianradulescu/abcql.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  build = "make build",
  config = function()
    require("abcql").setup()

    local abcql_ui = require("abcql.ui")
    vim.keymap.set({ "n" }, "<leader>SS", function() abcql_ui.open() end, { desc = "abcql open" })
    vim.keymap.set({ "n" }, "<leader>SC", function() abcql_ui.close() end, { desc = "abcql close" })
    vim.keymap.set({ "n" }, "<leader>ST", function() abcql_ui.toggle_tree() end, { desc = "abcql tree" })
    vim.keymap.set({ "n" }, "<leader>SR", function() abcql_ui.toggle_results() end, { desc = "abcql results" })
    vim.keymap.set({ "n" }, "<leader>Se", function() require("abcql.db.query").execute_query_at_cursor() end, { desc = "abcql execute query" })
    vim.keymap.set({ "x" }, "<leader>Se", "<Esc><Cmd>AbcqlQueryRunSelection<CR>", { desc = "abcql execute selection" })
    vim.keymap.set({ "n" }, "<leader>SE", function() require("abcql.db.query").execute_buffer() end, { desc = "abcql execute whole buffer" })
    vim.keymap.set({ "n" }, "<leader>SD", function() require("abcql.db").activate_datasource(vim.api.nvim_get_current_buf()) end, { desc = "abcql activate datasource" })
    vim.keymap.set({ "n" }, "<leader>SH", function() require("abcql.history").pick() end, { desc = "abcql query history" })
    vim.keymap.set({ "n" }, "<leader>Sxc", function() require("abcql.export").export_current("csv") end, { desc = "abcql export csv" })
    vim.keymap.set({ "n" }, "<leader>Sxj", function() require("abcql.export").export_current("json") end, { desc = "abcql export json" })
  end
}
```

---

## Configuration

### Datasources

Datasources can be configured in three ways, with the following priority (highest first):

1. **Local config file** (`.abcql.lua` in current working directory) - project-specific
2. **User config file** (`~/.config/nvim/abcql/datasources.lua`) - global defaults

#### Using a Local Config File (Recommended)

Create a `.abcql.lua` file in your project root:

```lua
-- .abcql.lua
return {
  datasources = {
    dev = "mysql://user:password@localhost:3306/myapp_dev",
    test = "mysql://user:password@localhost:3306/myapp_test",
  },
}
```

You can use `:AbcqlConfigInit` to generate a template file, `:AbcqlDatasourceAdd` to add entries
to it interactively, and `:AbcqlDatasourceUpdate` to edit them later.

> **Important:** Add `.abcql.lua` to your `.gitignore` to avoid committing credentials.

#### Default Datasource and Per-File Overrides

When you run a statement in a SQL buffer that has no datasource yet, abcql resolves one in this
order and attaches it without prompting:

1. A `-- abcql: <name>` comment in the first 10 lines of the file (`-- abcql: datasource=<name>`
   also works)
2. `default = "<name>"` in `.abcql.lua` (or the user config, or `setup({ default = ... })`)
3. The datasource you picked most recently in this session (disable with
   `query.auto_attach = false`)
4. Otherwise the `vim.ui.select` picker opens

```lua
-- .abcql.lua
return {
  default = "dev",
  datasources = {
    dev = "mysql://user:password@localhost:3306/myapp_dev",
    prod = { dsn = "mysql://user:password@db:3306/myapp", readonly = true },
  },
}
```

`:AbcqlDatasourceAttach [name]` attaches a datasource explicitly (with tab completion); without a name it
opens the picker. The attached datasource is shown in the buffer's winbar.

#### Safety Flags

Table-style datasources accept three optional flags:

| Flag        | Values                          | Effect                                                                 |
|-------------|---------------------------------|------------------------------------------------------------------------|
| `readonly`  | `true`                          | Refuses INSERT/UPDATE/DELETE/DDL; shown as `[readonly]` in the winbar  |
| `confirm`   | `"always"`, `"writes"`, `"never"` | Overrides the global `query.confirm` policy for this datasource       |
| `highlight` | a highlight group name          | Colors the datasource name in the winbar (e.g. `"DiagnosticError"`)   |

```lua
prod = {
  dsn = "mysql://user@db-internal:3306/myapp",
  secret = { service = "abcql", account = "prod-db-password" },
  readonly = true,
  confirm = "always",
  highlight = "DiagnosticError",
},
```

#### SOCKS Proxy Support

To connect through a SOCKS proxy (e.g., SSH tunnel, VPN), use a table-style datasource config with a `proxy` field. `abcql-backend` dials the proxy natively — no external `proxychains4` dependency needed.

```lua
return {
  datasources = {
    prod = {
      dsn = "mysql://user:password@db-internal:3306/myapp",
      proxy = "socks5://127.0.0.1:1080",
    },
  },
}
```

Supported proxy types: `socks5://host:port`.

Environment variables work in the proxy field too: `proxy = "socks5://${PROXY_HOST}:${PROXY_PORT}"`.

#### Environment Variable Expansion

DSN strings support environment variable expansion using `${VAR_NAME}` syntax:

```lua
return {
  datasources = {
    dev = "${DATABASE_URL}",
    staging = "mysql://user:${DB_PASSWORD}@staging:3306/myapp",
  },
}
```

#### Linux Keyring Secrets (secret-tool)

On Linux (GNOME Keyring / Secret Service), you can keep database passwords out of config files and environment variables.

1. Store the secret in keyring:

```bash
secret-tool store --label="abcql prod password" service abcql account prod-db-password
```

2. Reference it from datasource config:

```lua
return {
  datasources = {
    prod = {
      dsn = "mysql://user@db-internal:3306/myapp",
      secret = {
        service = "abcql",
        account = "prod-db-password",
      },
    },
  },
}
```

`provider` is optional and defaults to `"secret-tool"`.

> **Requirements:** install `secret-tool` (package `libsecret-tools` on Debian/Ubuntu).

#### Datasource Commands

- `:AbcqlDatasourceAttach [name]` - Attach a datasource to the current buffer (picker when no name)
- `:AbcqlDatasourceAdd [local|user]` - Add a datasource interactively (name, DSN, optional
  readonly / always-confirm / SOCKS proxy); it is appended to `.abcql.lua` or the user config
  (created from the template if missing), datasources are reloaded, and you can attach it to the
  current SQL buffer right away. When `secret-tool` is installed it also offers to keep the
  password in the keyring instead of the file: the password is stored under
  `service abcql / account <name>-db-password`, stripped from the DSN, and referenced with a
  `secret = { ... }` block
- `:AbcqlDatasourceUpdate [name]` - Edit a datasource that lives in a config file: a menu lets
  you change the DSN, the password (in the DSN, or moved to / taken back from the keyring),
  readonly, the confirm policy and the proxy, then `Save` rewrites just that entry in place
- `:AbcqlConfigInit` - Create a template `.abcql.lua` in the current directory
- `:AbcqlConfigInit user` - Create a template in the user config directory
- `:AbcqlDatasourceList` - Show all configured datasources with their source
- `:AbcqlDatasourceReload` - Reload datasources from config files (also rebuilds the tree)

### Plugin Options

Everything below is optional; these are the defaults:

```lua
require("abcql").setup({
  default = nil,            -- datasource attached to SQL buffers automatically (see above)
  backend = {
    path = nil,             -- custom path to abcql-backend
    timeout_ms = 30000,     -- per-query timeout
  },
  ui = {
    results_height = 0.4,   -- fraction of the screen (< 1) or absolute number of lines
    tree_width = 30,        -- datasource tree width in columns
    icons = true,           -- Nerd Font icons in the tree; false for plain ASCII
    cell_max_width = 50,    -- truncate wider cells (K shows the full value)
  },
  query = {
    confirm = "writes",     -- "always" | "writes" | "never": when to show the confirmation prompt
    max_rows = 1000,        -- rows fetched per query (0 = unlimited); the footer says when capped
    auto_attach = true,     -- reuse the last picked datasource for new SQL buffers
    treesitter = true,      -- use the tree-sitter sql parser for statement boundaries if installed
  },
})
```

---

## Backend

Queries are executed by `abcql-backend`, a small Go binary in this repo (`backend/`) that connects to
MySQL directly via a native driver — no `mysql` CLI dependency. It's built with:

```sh
make build
```

which compiles `bin/abcql-backend`. If you use lazy.nvim, add `build = "make build"` to the plugin spec
(see [Installation](#installation)) so it's built automatically on install and update.

The binary also works standalone, independent of Neovim:

```sh
echo '{"engine":"mysql","host":"127.0.0.1","port":3306,"user":"root","database":"shop","sql":"select 1"}' \
  | bin/abcql-backend exec
```

By default, abcql.nvim looks for `bin/abcql-backend` next to the plugin itself. To use a binary built
elsewhere, set `backend.path` in `setup()`:

```lua
require("abcql").setup({
  backend = {
    path = "/custom/path/to/abcql-backend",
    timeout_ms = 30000, -- default query timeout
  },
})
```

---

## Usage

### Commands

Every command is `Abcql<Subject><Action>`, so typing `:AbcqlDatasource` and pressing `<Tab>`
lists all datasource actions:

| Subject      | Commands                                                                                     |
|--------------|----------------------------------------------------------------------------------------------|
| `Ui`         | `AbcqlUiOpen`, `AbcqlUiClose`                                                                |
| `Results`    | `AbcqlResultsToggle`                                                                         |
| `Tree`       | `AbcqlTreeToggle`                                                                            |
| `Query`      | `AbcqlQueryRun`, `AbcqlQueryRunSelection`, `AbcqlQueryRunBuffer`, `AbcqlQueryCancel`         |
| `Datasource` | `AbcqlDatasourceAttach [name]`, `AbcqlDatasourceAdd [local\|user]`, `AbcqlDatasourceUpdate [name]`, `AbcqlDatasourceList`, `AbcqlDatasourceReload` |
| `History`    | `AbcqlHistoryPick`, `AbcqlHistoryBack`, `AbcqlHistoryForward`, `AbcqlHistoryInfo`, `AbcqlHistoryClear` |
| `Schema`     | `AbcqlSchemaRefresh`                                                                         |
| `Export`     | `AbcqlExportCsv`, `AbcqlExportTsv`, `AbcqlExportJson`                                        |
| `Config`     | `AbcqlConfigInit [local\|user]`                                                              |

### Trying it Out

No database handy? `make test-db-up` spins up a MySQL container preloaded with the
[employees sample database](https://github.com/datacharmer/test_db) (see `docker/README.md`). Then:

```sh
cp examples/.abcql.lua .abcql.lua
nvim examples/queries.sql
```

Put the cursor on one of the sample queries and press `<leader>Se`. The example config declares
`employees` as the default datasource (and the file carries a `-- abcql: employees` comment), so
the datasource attaches itself, the UI opens, and the results appear below the editor.

### Running Queries

| Action                                   | Command / mapping                                   |
|------------------------------------------|-----------------------------------------------------|
| Run the statement under the cursor       | `:AbcqlQueryRun` (`<leader>Se` in the example config) |
| Run the visual selection as one statement| `:AbcqlQueryRunSelection` (visual `<leader>Se`)      |
| Run every statement in the buffer        | `:AbcqlQueryRunBuffer` (`<leader>SE`)                |
| Cancel the running query                 | `:AbcqlQueryCancel`, or `<C-c>` in the results panel     |
| Browse history                           | `:AbcqlHistoryPick` (`<leader>SH`)                      |

Statements are split on `;` with awareness of strings, backtick identifiers and `--`/`#`/`/* */`
comments, so several statements can share a line and a `;` inside a string does not split. When a
tree-sitter `sql` parser is installed it is used instead whenever it parses the buffer cleanly.

A confirmation float appears only for statements that write (INSERT/UPDATE/DELETE/DDL...) unless
`query.confirm` or the datasource's `confirm` flag says otherwise. `<CR>` runs, `q`/`<Esc>` cancels.
Running a whole buffer confirms once for the batch and stops at the first error.

While a query runs the results winbar shows `running… 1.2s (<C-c> cancel)`. Cancelling kills the
backend process and records the attempt in history.

### Results Panel

The winbar above the results shows the datasource/database, the statement, and the row count and
duration. Result sets are capped at `query.max_rows`; the footer reads `showing first 1,000 rows
(max_rows limit)` when the cap was hit.

| Key             | Action                                                |
|-----------------|-------------------------------------------------------|
| `K` / `<CR>`    | Open the full cell value in a float (`y` yanks it)    |
| `yc`            | Yank the cell under the cursor                        |
| `yr`            | Yank the row under the cursor (tab-separated)         |
| `<Tab>` / `<S-Tab>` | Move to the next / previous cell                  |
| `<C-o>` / `<C-i>`, `[h` / `]h` | Older / newer entry in query history   |
| `<C-c>`         | Cancel the running query                              |

### Datasource Tree

`:AbcqlTreeToggle` (`<leader>ST`) opens the explorer to the right of the editor. It expands the
datasource attached to the editor buffer (and the database from its DSN) automatically.

| Key          | Action                                                     |
|--------------|------------------------------------------------------------|
| `<CR>`       | Expand / collapse (children load lazily)                   |
| `R`          | Reload the node from the database (picks up new tables)    |
| `r`          | Redraw                                                     |
| `y`          | Yank the qualified, escaped name (db.table, backticked)     |
| `i`          | Insert that name at the cursor in the editor               |
| `f`          | Jump to a loaded table via `vim.ui.select`                 |
| `<leader>Se` | Browse the table (`SELECT * ... LIMIT 1000`)               |

Set `ui = { icons = false }` if you do not use a Nerd Font.

### Query History

Every execution (success, error or cancellation) is stored under `stdpath("data")/abcql/query_history`
(last 100 entries, up to 1000 rows each). `:AbcqlHistoryPick` opens a picker over recent entries; for the
chosen one you can re-run it on its original datasource, insert it below the cursor, or show the
stored result. `:AbcqlHistoryBack` / `:AbcqlHistoryForward` (or `<C-o>` / `<C-i>` in the results
panel) step through entries in place, with the query shown above the result. `:AbcqlHistoryClear`
and `:AbcqlHistoryInfo` are also available.

### Healthcheck

Run Neovim's built-in healthcheck for abcql:

```vim
:checkhealth abcql
```

It validates:

- The `abcql-backend` binary is present and runnable
- Optional JSON export dependency (`jq`)
- Optional tree-sitter `sql` parser (used for statement boundaries when present)
- Datasource config structure
- Linux keyring secret configuration and lookup (`secret-tool`) when `secret` refs are configured

### SQL Language Features (built-in LSP)

`abcql.nvim` registers an in-process language server with Neovim's built-in LSP client as soon as a
datasource is attached to a buffer, so the usual LSP mappings and plugins (blink/cmp, `K`, `gO`,
code actions, symbol pickers) work in SQL files without any external server. Context is derived
from the statement under the cursor, so multi-line SELECT lists, aliases declared after the cursor
and files with many statements all behave.

| Feature | What you get |
|---|---|
| Completion | Databases after `USE`; tables after `FROM`/`JOIN`/`INTO`/`UPDATE` (comma lists too); columns of the statement's tables after `SELECT`/`WHERE`/`ON`/`SET`/`ORDER BY`..., `alias.` and `table.` qualified; keywords always, ranked last |
| INSERT snippets | After `INSERT INTO`, each table also offers a `(columns) VALUES (…)` snippet with one tab stop per column |
| Hover (`K`) | A table shows its columns, types, primary key and foreign keys; a column shows its type, table and key info |
| Document symbols (`gO`, symbol pickers) | One symbol per statement, named by its first keyword and tables |
| Workspace symbols (`vim.lsp.buf.workspace_symbol`) | Fuzzy lookup of tables and columns of the datasource |
| Code actions | Run this statement, browse the table under the cursor, expand `SELECT *` to the column list, insert an INSERT template for the table under the cursor |
| Diagnostics | Tables that do not exist in the datasource are flagged as warnings (CTE names and `CREATE` statements are ignored) |

The schema is loaded once per datasource with one query per database and shared by every buffer
attached to it; `:AbcqlSchemaRefresh` reloads it, and a successful `CREATE`/`ALTER`/`DROP`/`RENAME`
run through abcql reloads it automatically. Table lookups are case-insensitive.

#### LSP Commands

- `:AbcqlSchemaRefresh` - Reload schema cache for the current buffer's datasource

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
