# Changelog

All notable changes to abcql.nvim are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The plugin and
`abcql-backend` share one version; see [Versioning](README.md#versioning) for what counts as a
breaking change.

## [Unreleased]

## [1.0.0] - 2026-11-13

First stable release. Breaking changes to the public interface (commands, `setup()` options,
datasource config, default keys, highlight groups, the `AbcqlDatasourceAttached` event and the
`abcql-backend` CLI/JSON protocol) only land in a new major version from here on.

Requires Neovim >= 0.11.0, `nvim-lua/plenary.nvim`, and Go to build `abcql-backend`
(`make build`). Optional: `jq` (JSON export), `secret-tool` (Linux keyring), the tree-sitter `sql`
parser.

### Added

- **Connections**: MySQL servers and SQLite files from DSNs (`mysql://`, `sqlite://`). Datasources
  come from `setup()`, `~/.config/nvim/abcql/datasources.lua` and a project `.abcql.lua` (later
  wins), with `${VAR}` expansion, TLS options, SOCKS5 proxies and passwords kept in the Linux
  keyring (`secret-tool`) instead of the DSN.
- **Datasource management**: `:AbcqlDatasourceAttach`, `Add`, `Update`, `List`, `Reload` and
  `:AbcqlConfigInit`. Each buffer has its own datasource; a `default` datasource or a
  `-- abcql: <name>` comment attaches SQL files on open. Config files and history are written with
  private permissions.
- **Running queries**: the statement under the cursor, a visual selection or the whole buffer
  (`:AbcqlQueryRun`, `:AbcqlQueryRunSelection`, `:AbcqlQueryRunBuffer`), cancellable with `<C-c>` /
  `:AbcqlQueryCancel`. A selection or buffer runs as one batch on one connection and stops at the
  first error. Statement splitting understands quotes, backticks and comments, and uses tree-sitter
  when it parses cleanly. The last run statement is highlighted by its outcome.
- **Safety**: confirmation for writes (`confirm = "always" | "writes" | "never"`), `readonly`
  datasources, a dangerous-statement lint (UPDATE/DELETE without WHERE, `WHERE 1=1`, TRUNCATE) that
  warns while editing and always asks before running, and an auto-LIMIT for plain SELECTs plus a
  `max_rows` cap for everything else.
- **Persistent sessions** (opt-in, MySQL): `session = "persistent"` keeps one connection per buffer,
  so transactions, `SET @var`, `USE` and temporary tables survive between runs. The winbar shows
  the transaction state; `:AbcqlTransactionCommit`, `:AbcqlTransactionRollback` and
  `:AbcqlSessionClose` act on it. Implicit commits are confirmed, and a session with an open
  transaction asks Commit / Rollback (default) / Cancel before it goes away. abcql never commits on
  your behalf.
- **Results panel**: Result and Output (the SQL as sent) tabs, a sticky header, a cell popup (`K`),
  cell/row/column yank, `<Tab>` cell motions, local sort and filters, `gf` to follow a foreign key
  (the popup previews the referenced row), readable binary and BIT values, a `g?` key legend and a
  winbar with datasource, row count and duration or a running timer.
- **Schema tree**: databases, tables, columns, constraints and indexes, loaded lazily, with reload,
  filter, yank/insert of qualified names and table browsing. MySQL system schemas are listed next to
  the configured database.
- **SQL language features**: an in-process LSP with completion of databases, tables, columns and
  keywords, join conditions and foreign-key JOIN suggestions, hover, document and workspace
  symbols, code actions (run, browse, expand `*`, INSERT template) and diagnostics for unknown
  tables and dangerous statements. `:AbcqlSchemaRefresh` reloads the schema, which also happens
  after DDL.
- **Query history**: every run (success, error or cancellation) is saved, with in-place navigation
  (`<C-o>` / `<C-i>`, `:AbcqlHistoryBack` / `Forward`) and a picker (`:AbcqlHistoryPick`) to re-run,
  insert or show an entry. `history_rows = false` keeps the SQL and outcome without the rows.
- **Export**: `:AbcqlExport` to a file and `:AbcqlExportCopy` to the clipboard as CSV, TSV, JSON,
  Markdown, `INSERT` or `UPDATE` statements, a comma-separated value list or one value per line,
  honoring the current sort and filters.
- **abcql-backend**: a Go binary that runs queries through native drivers (no `mysql`/`sqlite3`
  CLI), usable standalone through a JSON protocol on stdin/stdout (`exec`, `serve`, `version`).
- **Health check**: `:checkhealth abcql` checks the backend, including that it was built from the
  same version as the plugin, the optional dependencies, the datasource config and keyring secrets.
- `require("abcql").version` and `make version` report the release version.

[Unreleased]: https://github.com/cristianradulescu/abcql.nvim/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/cristianradulescu/abcql.nvim/releases/tag/v1.0.0
