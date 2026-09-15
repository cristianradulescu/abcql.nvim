# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`abcql.nvim` is a Neovim plugin (Lua, requires Neovim >= 0.11.0) implementing a DataGrip/DBeaver-style
database client inside the editor: connection management, a query editor + results UI, schema tree,
SQL completion via an in-process LSP, and result export.

## Commands

```bash
make lint          # luacheck lua/ tests/
make format        # stylua --check . (verify formatting)
make format-fix    # stylua . (apply formatting)
make check         # lint + format
make test          # run the full test suite (see below)
```

Tests run via `PlenaryBustedDirectory` against `tests/minimal_init.lua` (auto-clones
`nvim-lua/plenary.nvim` to `/tmp/plenary.nvim` if missing, or set `PLENARY_DIR`), followed by
`tests/minimal_test.lua`, a headless smoke test against a real `mysql` connection
(`mysql://dbuser:dbpassword@localhost:3306/bookstore`) — it needs that server reachable to pass.

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

Style: 2-space indent, double quotes, always-parenthesized calls (see `.stylua.toml`); `luacheck`
ignores unused-arg warnings (rule 212) and ships a relaxed `busted` global set for `tests/`.

## Architecture

### No MySQL client library — everything shells out

There is no MySQL driver dependency. `abcql.db.adapter.mysql` builds argv for the `mysql` CLI
(`-h`, `-P`, `-u`, `-D`, `--batch`, `-e <query>`, `--skip-column-names`, `-vvv` for write queries
to force tabular "Query OK, N rows affected" output) and `abcql.db.query` runs it via `vim.system`
(async `execute_async` / blocking `execute_sync`), parsing tab-delimited stdout. Passwords never hit
argv: `prepare_command` writes a temp `--defaults-extra-file` per invocation and cleans it up via a
`cleanup` callback threaded through both call paths. SOCKS proxying wraps the argv with
`proxychains4 -q -f <generated-config>` (`abcql.db.adapter.base:build_command`).

Adding a new database engine means implementing `abcql.db.adapter.base`'s interface (`get_command`,
`get_args`/`prepare_command`, `parse_output`, `get_databases`/`get_tables`/`get_columns`,
`escape_identifier`) and registering it in `abcql.db.Database.setup` via
`connectionRegistry:register_adapter(scheme, AdapterClass)` — the DSN scheme (e.g. `mysql://`)
selects the adapter.

### Layered config resolution

Datasources merge from three sources, later wins: `setup()` opts → `~/.config/nvim/abcql/datasources.lua`
(user) → `.abcql.lua` in cwd (local/project, highest priority). `abcql.config.loader` does the
merging and tags each datasource with `source`/`source_path` for `:AbcqlListDatasources`. DSN and
proxy strings support `${VAR_NAME}` env expansion. Passwords can also be deferred to a keyring lookup
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
results + optional datasource-tree layout — there's no multi-instance support. `winfixbuf` pins the
results/tree windows to their buffers; a `BufEnter` autocmd guard redirects any foreign buffer that
lands there back to the editor window. `WinClosed` autocmds on the editor window tear down the whole
layout (editor is the anchor); closing results/tree only clears that panel's state. Editor buffer
ownership matters on `UI.close()`: buffers abcql created itself (`editor_buf_owned`) get deleted,
pre-existing user buffers are left alone. `abcql.ui.tree` and `abcql.ui.init` have a circular
dependency broken via `Tree.set_display_fn(...)`, registered from `UI.open`.

### Query lifecycle

`abcql.db.query.execute_query_at_cursor` extracts the semicolon-delimited statement under the cursor,
shows a floating confirmation prompt (`<CR>` confirm / `q`/`<Esc>` cancel), then dispatches through
the active buffer's datasource adapter. Every execution (success or error) is recorded via
`abcql.history`, and results are rendered by `abcql.ui.display` (handles error strings, `write`-type
results, and `select`-type result tables distinctly). History navigation (`<C-o>`/`<C-i>` in the
results buffer, or `:AbcqlHistoryBack`/`Forward`) replays past query+result/error pairs into the same
results buffer.

### Export

`abcql.export.registry` is a name → formatter-function registry (`csv`, `tsv`, `json` register
themselves in `abcql.export.init`); JSON export shells out to `jq` for pretty-printing/escaping and
is skipped if `jq` isn't installed (surfaced via `:checkhealth abcql`).

### Buffer-scoped, not global, active datasource

`abcql.db.Database.buffer_datasources` maps `bufnr -> Datasource`, so different SQL buffers can be
attached to different datasources simultaneously; activating one also starts/restarts that buffer's
LSP client and sets its `winbar`.
