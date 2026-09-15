# Employees test database

`compose.yml` (repo root) spins up a MySQL 8.4 server and loads
[datacharmer/test_db](https://github.com/datacharmer/test_db)'s `employees` sample database into it —
6 tables, ~300k employees and 2.8M salary rows, useful for exercising the tree view, completion, and
result pagination against a non-trivial schema.

## Usage

```sh
make test-db-up     # docker compose up -d, then tails the import log
make test-db-down   # stop the containers (add ARGS=-v to also delete the data volume)
make test-db-logs   # re-attach to the loader's log output
```

or directly with `docker compose` from the repo root.

Two services:

- `mysql` — the server, exposed on `localhost:${MYSQL_PORT:-33060}`.
- `employees-loader` — a one-shot container that clones `test_db` (cached in a volume, so this only
  happens once), runs `employees.sql` per the [repo's install instructions](https://github.com/datacharmer/test_db#installation),
  verifies the import against `test_employees_sha2.sql`, and grants `MYSQL_USER` access. It exits
  after a successful run and is safe to re-run (`docker compose up`) — it skips the import if the
  `employees` database already exists.

The first import takes a minute or two. Follow progress with `make test-db-logs` (or
`docker compose logs -f employees-loader`).

## Connecting from abcql.nvim

Defaults are `dbuser` / `dbpassword`, matching the rest of this project's test fixtures.
`examples/.abcql.lua` already has a matching datasource — copy it to the repo root as `.abcql.lua`:

```sh
cp examples/.abcql.lua .abcql.lua
```

```lua
-- examples/.abcql.lua
return {
  datasources = {
    employees = "mysql://dbuser:dbpassword@0.0.0.0:33060/employees",
  },
}
```

Then open `examples/queries.sql` — it has a handful of ready-to-run statements (`show tables`,
`select * from employees limit 100`, etc.) against this schema — activate the `employees` datasource
(`:AbcqlOpen`, then `<leader>SD`) and run one with `<leader>Se`.

## Configuration

Override any of these via a `.env` file in the repo root (see `compose.yml`) or exported env
vars before `docker compose up`:

| Variable              | Default        | Notes                                          |
|-----------------------|----------------|-------------------------------------------------|
| `MYSQL_ROOT_PASSWORD` | `rootpassword` | Used by the loader to run the import            |
| `MYSQL_USER`          | `dbuser`       | Non-root user granted access to `employees`     |
| `MYSQL_PASSWORD`      | `dbpassword`   | Password for `MYSQL_USER`                       |
| `MYSQL_PORT`          | `33060`        | Host port; change if you already have MySQL there |

Data persists in the `abcql_employees_mysql_data` docker volume across `docker compose down`; use
`down -v` (or `make test-db-down ARGS=-v`) to reset it.
