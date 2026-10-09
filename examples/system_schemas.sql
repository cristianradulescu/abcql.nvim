-- abcql: employees_test_db
--
-- Queries against the server's built-in schemas (information_schema, performance_schema, mysql, sys).
-- They show up in the datasource tree and in completion next to the configured database, so no
-- extra datasource entry is needed. All statements here are read-only.

-- Table sizes in the configured database, largest first
SELECT
  table_name,
  table_rows,
  ROUND(data_length / 1024 / 1024, 2) AS data_mb,
  ROUND(index_length / 1024 / 1024, 2) AS index_mb,
  ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb
FROM information_schema.tables
WHERE table_schema = 'employees'
ORDER BY data_length + index_length DESC;

-- Size of every database on the server
SELECT
  table_schema,
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS total_mb
FROM information_schema.tables
GROUP BY table_schema
ORDER BY SUM(data_length + index_length) DESC;

-- Columns of a table
SELECT column_name, column_type, is_nullable, column_key
FROM information_schema.columns
WHERE table_schema = 'employees' AND table_name = 'employees'
ORDER BY ordinal_position;

-- Indexes of the configured database
SELECT index_name, non_unique, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns_
FROM information_schema.statistics
WHERE table_schema = 'employees'
GROUP BY table_name, index_name, non_unique;

-- Running connections
SELECT id, user, host, db, command, time, state
FROM information_schema.processlist;

-- Slowest statements by total time (performance_schema)
SELECT
  digest_text,
  count_star,
  ROUND(sum_timer_wait / 1e12, 3) AS total_s,
  ROUND(avg_timer_wait / 1e12, 6) AS avg_s
FROM performance_schema.events_statements_summary_by_digest
ORDER BY sum_timer_wait DESC
LIMIT 10;

-- Accounts (mysql schema; needs privileges)
SELECT user, host FROM mysql.user;

-- Tables read with full table scans (sys schema, MySQL 5.7+ / MariaDB 10.6+)
SELECT * FROM sys.schema_tables_with_full_table_scans LIMIT 10;
