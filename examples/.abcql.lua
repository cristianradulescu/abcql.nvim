return {
  -- Attached automatically to every SQL buffer in this project
  -- (override per file with a `-- abcql: <name>` comment on the first lines).
  default = "employees_test_db",
  datasources = {
    employees_test_db = "mysql://dbuser:dbpassword@0.0.0.0:33060/employees",
  },
}
