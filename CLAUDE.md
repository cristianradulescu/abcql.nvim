# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`abcql.nvim` is a Neovim plugin (Lua, requires Neovim >= 0.11.0) implementing a DataGrip/DBeaver-style
database client inside the editor: connection management, a query editor + results UI, schema tree,
SQL completion via an in-process LSP, and result export. Queries are executed by `abcql-backend`, a Go
binary in `backend/` (own Go module) built via `make build` — it talks to the database directly via a
native driver and is usable standalone, independent of Neovim.

## Commands

```bash
make build          # go build backend/ -> bin/abcql-backend (gitignored)
make lint           # lint-backend (gofmt -l + go vet on backend/) + luacheck lua/ tests/
make format         # stylua --check . (verify formatting)
make format-fix     # stylua . (apply formatting)
make check          # lint + format
make test           # test-backend (go test ./backend/...) + the Lua test suite below
```

`bin/abcql-backend` must exist for anything that actually executes a query (the live-MySQL smoke test
below, or manual testing) — run `make build` first; the mocked Lua unit tests don't need it.

The Lua test suite runs via `PlenaryBustedDirectory` against `tests/minimal_init.lua` (auto-clones
`nvim-lua/plenary.nvim` to `/tmp/plenary.nvim` if missing, or set `PLENARY_DIR`), followed by
`tests/minimal_test.lua`, a headless smoke test against a real MySQL connection
(`mysql://dbuser:dbpassword@localhost:3306/bookstore`, executed through `abcql-backend`) — it needs
that server reachable (and the backend built) to pass.

`make test-db-up` starts a separate `compose.yml` stack (see `docker/README.md`) that loads
datacharmer/test_db's `employees` database — a richer schema for manually testing the tree/completion/
results UI. It's unrelated to the `bookstore` fixture above and not part of `make test`.

To run a single spec file directly:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/abcql/db/adapter/mysql_spec.lua"
```

Specs live under `tests/abcql/` mirroring `lua/abcql/` (e.g. `lua/abcql/db/query.lua` ↔
`tests/abcql/db/query_spec.lua` — not all modules have specs yet, check before assuming one exists).
`tests/abcql/ui/init_spec.lua` exercises the real window layout headlessly (open/toggle/display), so
UI regressions such as a panel that can't be re-shown are caught without a database.
The Go backend is a separate module and doesn't follow this mirroring: its tests are plain
`backend/*_test.go` files run via `go test ./...` (`make test-backend`).

Style: 2-space indent, double quotes, always-parenthesized calls (see `.stylua.toml`); `luacheck`
ignores unused-arg warnings (rule 212) and ships a relaxed `busted` global set for `tests/`.

## Architecture

### Go backend does the querying — no shelled-out DB CLI

`backend/` is a standalone Go module (`abcql-backend`) built via `make build` into `bin/abcql-backend`
(gitignored). It's spawned as a one-shot subprocess per operation — `lua/abcql/backend/init.lua`
(`Backend.invoke`/`invoke_sync`) runs it via `vim.system`, writing a JSON request to stdin
(`{engine, host, port, user, password, database, options, proxy, sql, timeout_ms}`) and reading a
single JSON response from stdout (`{query_type, headers, rows, row_count, affected_rows, matched_rows,
changed_rows, warnings, duration_ms}` on success, `{error}` on failure, always valid JSON either way).
No daemon, no connection pooling — same shell-per-query shape as before, but the backend holds a real
`database/sql` + `go-sql-driver/mysql` connection instead of text-scraping the `mysql` CLI's output.
SOCKS5 proxying is dialed natively in Go (`backend/proxy.go`, `golang.org/x/net/proxy`) rather than
wrapping the process with `proxychains4`. NULL cells are still serialized as the literal string
`"NULL"` (not JSON `null`) so `abcql.ui.format`/`abcql.ui.highlights` don't need to special-case
`vim.NIL`.

`abcql.db.adapter.base:build_backend_request` builds that JSON request generically from `self.config`
(host/port/user/password/database/options/proxy — already parsed/secret-resolved by
`abcql.db.connection.registry`) plus the adapter's `ENGINE` field; most adapters don't need to
override it. `abcql.db.query.execute_async`/`execute_sync` call `Backend.invoke`/`invoke_sync` and map
the JSON response straight onto `QueryResult` — there's no CLI-argv-building or tab-delimited-output
parsing left on the Lua side. Passwords travel over the subprocess's stdin pipe only, never argv or a
temp file.

The request also carries `max_rows` (from `query.max_rows`, default 1000); the backend stops
scanning after that many rows and sets `truncated: true`, which the results footer/winbar surface.
`Backend.invoke` returns the `vim.system` handle so `abcql.db.query.cancel` can kill a running
query (reported back as the error string `Query cancelled`).

`MySQLAdapter:get_databases`/`get_tables`/`get_columns`/`get_constraints`/`get_indexes` are just
`INFORMATION_SCHEMA` SQL text run through that same `Query.execute_async`, so schema introspection
(tree view, LSP completion cache) rides the Go backend for free — no separate code path.

Adding a new database engine now takes two changes: a Lua adapter implementing
`abcql.db.adapter.base`'s interface (`get_databases`/`get_tables`/`get_columns`,
`escape_identifier`/`escape_value`, an `ENGINE` string constant) registered via
`connectionRegistry:register_adapter(scheme, AdapterClass)` in `abcql.db.Database.setup`, *and* a
matching branch in the Go backend's `execRequest` (`backend/mysql.go` is currently the only one) that
handles that `Request.Engine` value — the backend is the only thing that actually opens a database
connection now.

### Layered config resolution

Datasources merge from three sources, later wins: `setup()` opts → `~/.config/nvim/abcql/datasources.lua`
(user) → `.abcql.lua` in cwd (local/project, highest priority). `abcql.config.loader` does the
merging and tags each datasource with `source`/`source_path` for `:AbcqlListDatasources`. DSN and
proxy strings support `${VAR_NAME}` env expansion. Table-style datasources may also carry
`readonly`/`confirm`/`highlight` flags, which travel through the loader and
`registry:register_datasource(name, dsn, proxy, secret, opts)` onto the `Datasource` object; each
config file (and `setup()`) may name a `default` datasource, same precedence. `setup()` also has
`ui` (panel sizes, icons, cell width) and `query` (confirm policy, `max_rows`, `auto_attach`,
`treesitter`) sections; modules read them via `require("abcql.config").ui/.query` with local
fallbacks so they still work when config was never set up (tests).

Passwords can also be deferred to a keyring lookup
(`secret = { service, account }` in a datasource, currently Linux `secret-tool` only via
`abcql.secret` → `abcql.secret.linux`) instead of embedding them in the DSN — resolved once at
`registry:register_datasource` time via `abcql.secret.lookup`.

### Fake in-process LSP client

`abcql.lsp` does not spawn an external language server. `LSP.start` calls `vim.lsp.start` with a
`cmd` function that returns a hand-built RPC object (`request`/`notify`/`is_closing`/`terminate`)
whose `request` handler dispatches `initialize`/`textDocument/completion`/`shutdown` directly to
`abcql.lsp.server` in-process — no real process or socket involved. Schema (databases/tables/columns)
is fetched from the adapter and cached per-datasource in `abcql.lsp.cache` before the client starts;
`:AbcqlRefreshSchema` clears and reloads that cache. `abcql.lsp.parser` does lightweight SQL context
detection (are we after `FROM`, inside a column list, etc.) to drive what `abcql.lsp.completion`
offers.

### UI state machine

`abcql.ui` owns a single module-level `state` table (buffers/windows/visibility) for one editor +
results + optional datasource-tree layout — there's no multi-instance support. The results and tree
buffers use `bufhidden=hide` (not `wipe`) so toggling a panel off keeps its buffer; `UI.display`
calls `UI.show_results` to re-open a hidden results window rather than recreating the layout.
`winfixbuf` pins the results/tree windows to their buffers; a `BufEnter` autocmd guard redirects any
foreign buffer that lands there back to the editor window. `WinClosed` autocmds on the editor window
tear down the whole layout (editor is the anchor); closing results/tree only clears that panel's
state. Editor buffer ownership matters on `UI.close()`: buffers abcql created itself
(`editor_buf_owned`) get deleted, pre-existing user buffers are left alone. `abcql.ui.tree` and
`abcql.ui.init` have a circular dependency broken via `Tree.set_display_fn(...)`, registered from
`UI.open`.

Context lives in winbars, not notifications: the editor window's winbar shows the attached
datasource (`Database.winbar_text`, re-applied on `BufWinEnter` since `winbar` is window-local) and
the results window's winbar shows datasource/db • statement • row count/duration (or the running
timer). Cell-level features in the results buffer (`K` popup, `yc`/`yr`, `<Tab>` motions) derive
byte offsets from `state.current_widths` and `state.table_top_line`, so anything that changes the
table's rendering must keep those in sync. All highlighting goes through extmarks
(`highlights.add`); `nvim_buf_add_highlight`/`nvim_buf_set_option` are not used. The tree renders
to `lines, highlights` and keeps its node cache across redraws; `R` (`Tree.reload_node`) drops a
subtree and refetches, `Tree.reset()` drops everything (called from `:AbcqlReloadDatasources`).

### Query lifecycle

`abcql.db.statements` splits buffer text into statements: a character scanner that understands
quotes, backtick identifiers and `--`/`#`/`/* */` comments (so `;` inside those never splits, and
several statements may share a line), with a tree-sitter `sql` pass tried first when the parser is
installed and the tree has no errors. It also classifies statements (`is_write`: anything whose
first keyword isn't SELECT/SHOW/DESCRIBE/EXPLAIN/WITH/USE...). `abcql.db.query` has three entry
points, `execute_query_at_cursor`, `execute_selection` and `execute_buffer` (sequential, stops on
first error), all of which go through `Database.ensure_datasource` and then `Query.run`. `Query.run`
is the single execution path: readonly guard → confirmation float (policy: datasource `confirm` >
`query.confirm`, default only for writes) → `UI.set_running` (winbar timer) → `Backend.invoke`
(handle kept for `Query.cancel`) → `abcql.history` save → `UI.display`. Results are rendered by
`abcql.ui.display` (error strings, `write`-type results, and `select`-type tables). History
navigation (`<C-o>`/`<C-i>`/`[h`/`]h` in the results buffer, or `:AbcqlHistoryBack`/`Forward`)
replays past query+result/error pairs into the same results buffer; `:AbcqlHistory` is a
`vim.ui.select` picker (`History.pick`) that can re-run, insert, or show an entry.

### Export

`abcql.export.registry` is a name → formatter-function registry (`csv`, `tsv`, `json` register
themselves in `abcql.export.init`); JSON export shells out to `jq` for pretty-printing/escaping and
is skipped if `jq` isn't installed (surfaced via `:checkhealth abcql`).

### Buffer-scoped, not global, active datasource

`abcql.db.Database.buffer_datasources` maps `bufnr -> Datasource`, so different SQL buffers can be
attached to different datasources simultaneously; attaching one (`Database.attach_datasource`) also
starts/restarts that buffer's LSP client, sets its `winbar`, and fires the `User
AbcqlDatasourceAttached` autocmd (the tree listens to mark the active datasource). Buffers without
an attachment are resolved lazily by `Database.ensure_datasource` when a query runs: `-- abcql:
<name>` comment in the first 10 lines → configured `default` → last used datasource (if
`query.auto_attach`) → `vim.ui.select` prompt.
