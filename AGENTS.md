# AGENTS.md — abcql.nvim

Neovim plugin (Lua) providing a DataGrip/DBeaver-style database client. Currently MySQL-only. Requires Neovim >= 0.11.0 and `nvim-lua/plenary.nvim`.

## Developer Commands

All commands are in the `Makefile`:

```sh
make lint        # luacheck lua/ tests/
make format      # stylua --check . (check only, does NOT fix)
make format-fix  # stylua . (fix in place)
make check       # lint + format (CI-equivalent)
make test        # both test suites (see below)
```

## Two Separate Test Suites

`make test` runs both:

**1. Unit tests (plenary/busted):**
```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```
- `tests/minimal_init.lua` auto-clones plenary to `/tmp/plenary.nvim` (override with `PLENARY_DIR` env var).
- Test files: `tests/abcql/**/*_spec.lua`

**2. Integration/smoke test (requires live MySQL):**
```sh
nvim --headless -u NONE -c "luafile tests/minimal_test.lua"
```
- Connects to `mysql://dbuser:dbpassword@localhost:3306/bookstore`.
- Fails offline — not suitable for CI without a live MySQL server.

**Run a single test file:**
```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/abcql/config_spec.lua"
```

## Architecture

- `lua/abcql/init.lua` — plugin entry point
- `lua/abcql/db/adapter/` — adapter pattern; `mysql.lua` is the only concrete impl; adding a DB = new file here
- `lua/abcql/config.lua` — metatable proxy; do not hold a reference to the internal table directly
- `lua/abcql/db/init.lua` — buffer-to-datasource registry keyed by `bufnr`; LSP server starts when a datasource activates
- `plugin/abcql.lua` — registers all `:AbcqlXxx` commands at startup; guarded by `vim.g.loaded_abcql`
- `ftplugin/sql.lua` — runs for every `sql` filetype buffer (sets winbar, attaches highlights)

## External Binaries Required

| Binary | Purpose |
|---|---|
| `mysql` | Query execution (must be on PATH) |
| `jq` | JSON export |
| `secret-tool` | Linux keyring (optional) |
| `proxychains4` | SOCKS proxy datasources (optional) |

`${VAR_NAME}` env var expansion is supported in DSN strings.

## Linter / Formatter Config

- **luacheck**: `std = "luajit"`, `vim` is a read global, `max_line_length = 999`, `212/_.*` suppressed
- **stylua**: `column_width = 120`, 2-space indent, `AutoPreferDouble` quotes, `call_parentheses = "Always"`, `collapse_simple_statement = "Never"`, `sort_requires = false`
- **sqlfluff**: dialect `mysql`, keywords UPPERCASE, identifiers lowercase

## Testing Conventions

- Reset module cache between tests: `package.loaded["abcql.config"] = nil`
- Mock `vim.notify` to `function() end` in `before_each`, restore in `after_each`
- No snapshot tests, no fixture files
- Test tree mirrors source tree: `tests/abcql/` mirrors `lua/abcql/`

## No CI

No `.github/` workflows exist. Verification is manual via `make check && make test`.
