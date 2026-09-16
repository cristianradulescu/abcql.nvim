# AGENTS.md — abcql.nvim

Neovim plugin (Lua) providing a DataGrip/DBeaver-style database client. Currently MySQL-only. Requires
Neovim >= 0.11.0 and `nvim-lua/plenary.nvim`. Query execution is delegated to `abcql-backend`, a Go
binary in `backend/` (its own Go module) — no MySQL client library or CLI dependency on the Lua side.

## Developer Commands

All commands are in the `Makefile`:

```sh
make build       # go build backend/ -> bin/abcql-backend (gitignored; required before executing queries)
make lint        # lint-backend (gofmt -l + go vet on backend/) + luacheck lua/ tests/
make format      # stylua --check . (check only, does NOT fix; Lua only, doesn't touch backend/)
make format-fix  # stylua . (fix in place)
make check       # lint + format (CI-equivalent)
make test        # test-backend (go test ./backend/...) + both Lua test suites (see below)
```

## Three Test Suites

`make test` runs all three:

**1. Go unit tests (`backend/`):**
```sh
cd backend && go test ./...
```
- Plain `go test`, no mocking framework — DB-dependent paths (`execRequest`) are exercised via
  connection-refused/JSON-shape assertions rather than a live server; see `backend/main_test.go`.

**2. Lua unit tests (plenary/busted):**
```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```
- `tests/minimal_init.lua` auto-clones plenary to `/tmp/plenary.nvim` (override with `PLENARY_DIR` env var).
- Test files: `tests/abcql/**/*_spec.lua`. DB-facing modules (`abcql.backend`, adapters) are tested by
  stubbing `vim.system`, not by invoking the real `abcql-backend` binary.

**3. Integration/smoke test (requires live MySQL + a built backend):**
```sh
make build   # bin/abcql-backend must exist first
nvim --headless -u NONE -c "luafile tests/minimal_test.lua"
```
- Connects to `mysql://dbuser:dbpassword@localhost:3306/bookstore`, executed through `abcql-backend`.
- Fails offline, or if `bin/abcql-backend` hasn't been built — not suitable for CI without both.

**Run a single Lua spec file:**
```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/abcql/config_spec.lua"
```

## Employees Test Database (docker)

`compose.yml` + `docker/load-employees.sh` spin up MySQL and import
[datacharmer/test_db](https://github.com/datacharmer/test_db)'s `employees` database (6 tables, ~300k
rows) for manually exercising the tree/completion/results UI against a richer schema than `bookstore`.
Not used by `make test`. See `docker/README.md`; quick start: `make test-db-up`.

`examples/.abcql.lua` (datasource pointing at this container) and `examples/queries.sql` (sample
`SELECT`s against it) are ready to copy/open for manual testing — see "Trying it Out" in `README.md`.

## Architecture

- `backend/` — separate Go module (`abcql-backend`); one `main` package, `go.mod`/`go.sum` at its root, built via `make build` into `bin/abcql-backend` (gitignored). Reads one JSON request from stdin, executes it against MySQL via `database/sql` + `go-sql-driver/mysql`, writes one JSON response to stdout, exits. Also usable standalone (see README "Backend" section).
- `lua/abcql/backend/init.lua` — spawns `bin/abcql-backend` as a one-shot subprocess per query via `vim.system` (`invoke`/`invoke_sync`); resolves the binary path from `config.backend.path` or the plugin's own runtime directory.
- `lua/abcql/init.lua` — plugin entry point
- `lua/abcql/db/adapter/` — adapter pattern; `mysql.lua` is the only concrete impl; adding a DB = new adapter file here **and** a matching engine branch in `backend/mysql.go`'s dispatch (see CLAUDE.md)
- `lua/abcql/config.lua` — metatable proxy; do not hold a reference to the internal table directly
- `lua/abcql/db/init.lua` — buffer-to-datasource registry keyed by `bufnr`; LSP server starts when a datasource activates
- `plugin/abcql.lua` — registers all `:AbcqlXxx` commands at startup; guarded by `vim.g.loaded_abcql`
- `ftplugin/sql.lua` — runs for every `sql` filetype buffer (sets winbar, attaches highlights)

## External Binaries Required

| Binary | Purpose |
|---|---|
| `abcql-backend` | Query execution — built in-repo via `make build`, not installed externally (see `backend/`) |
| `jq` | JSON export |
| `secret-tool` | Linux keyring (optional) |

No `mysql` CLI or `proxychains4` dependency anymore — the Go backend uses a native MySQL driver and
dials SOCKS5 proxies itself (`golang.org/x/net/proxy`).

`${VAR_NAME}` env var expansion is supported in DSN strings.

## Linter / Formatter Config

- **luacheck**: `std = "luajit"`, `vim` is a read global, `max_line_length = 999`, `212/_.*` suppressed
- **stylua**: `column_width = 120`, 2-space indent, `AutoPreferDouble` quotes, `call_parentheses = "Always"`, `collapse_simple_statement = "Never"`, `sort_requires = false` — applies to `lua/`/`tests/` only, not `backend/`
- **sqlfluff**: dialect `mysql`, keywords UPPERCASE, identifiers lowercase
- **backend/** (Go): standard `gofmt`, checked with `gofmt -l ./backend` + `go vet ./...` (`make lint-backend`); no separate style config

## Testing Conventions

- Lua: reset module cache between tests: `package.loaded["abcql.config"] = nil`
- Lua: mock `vim.notify` to `function() end` in `before_each`, restore in `after_each`
- Lua: no snapshot tests, no fixture files
- Lua: test tree mirrors source tree: `tests/abcql/` mirrors `lua/abcql/`
- Go: plain `*_test.go` files next to the code under test in `backend/`, run via `go test ./...`; no mocking library

## No CI

No `.github/` workflows exist. Verification is manual via `make check && make test`.
