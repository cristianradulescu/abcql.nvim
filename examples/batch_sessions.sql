-- abcql: employees_test_db
--
-- Examples for batch runs: a selection holding several statements (or the whole buffer) is sent
-- to abcql-backend as ONE request and runs on ONE connection, so session state survives from one
-- statement to the next within that run: transactions, `SET @var`, `USE`, temporary tables.
-- When the run ends the connection closes, so state never carries over to the next run, and an
-- open transaction is rolled back by the server, never committed.
--
-- How to use: run each block as a selection (`vip` selects one block, they have no blank lines).
-- Don't run the whole buffer: it would run the setup, the failing examples and the cleanup together.
-- Only the last statement's result is shown; step back through the earlier ones with `<C-o>`/`[h`
-- in the results window. The Output tab shows the whole batch as sent.
--
-- The blocks write only to a scratch table, `abcql_batch_demo`, created by the setup block.

-- ---------------------------------------------------------------------------------------------
-- Setup (run first)
-- ---------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS abcql_batch_demo;
CREATE TABLE abcql_batch_demo (id INT PRIMARY KEY, note VARCHAR(50));
INSERT INTO abcql_batch_demo VALUES (1, 'original');

-- Check the scratch table's state; run this on its own after the blocks below
SELECT * FROM abcql_batch_demo ORDER BY id;

-- ---------------------------------------------------------------------------------------------
-- Session variables
-- ---------------------------------------------------------------------------------------------

-- @emp is still set for the second statement
SET @emp := 10001;
SELECT emp_no, first_name, last_name, hire_date FROM employees WHERE emp_no = @emp;

-- A variable assigned by one SELECT feeds the next
SELECT @top := MAX(salary) AS top_salary FROM salaries;
SELECT s.emp_no, e.first_name, e.last_name, s.salary
FROM salaries s
JOIN employees e USING (emp_no)
WHERE s.salary = @top;

-- ---------------------------------------------------------------------------------------------
-- Temporary tables
-- ---------------------------------------------------------------------------------------------

-- The temporary table lives as long as the run's connection, then disappears
CREATE TEMPORARY TABLE top_earners AS
  SELECT emp_no, MAX(salary) AS salary FROM salaries GROUP BY emp_no ORDER BY salary DESC LIMIT 10;
SELECT e.first_name, e.last_name, t.salary
FROM top_earners t
JOIN employees e USING (emp_no)
ORDER BY t.salary DESC;

-- Run on its own afterwards: fails with "Table ... doesn't exist", because the session is gone
SELECT * FROM top_earners;

-- ---------------------------------------------------------------------------------------------
-- USE
-- ---------------------------------------------------------------------------------------------

-- Switches the default database for the rest of this run only
USE information_schema;
SELECT DATABASE() AS current_db, COUNT(*) AS tables_here FROM TABLES WHERE TABLE_SCHEMA = DATABASE();

-- Run on its own afterwards: back to the datasource's database
SELECT DATABASE() AS current_db;

-- ---------------------------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------------------------

-- ROLLBACK: the SELECT (one step back with `<C-o>`) sees 'changed', the table check afterwards
-- shows 'original'
START TRANSACTION;
UPDATE abcql_batch_demo SET note = 'changed' WHERE id = 1;
SELECT * FROM abcql_batch_demo ORDER BY id;
ROLLBACK;

-- COMMIT: the table check afterwards shows 'committed'
START TRANSACTION;
UPDATE abcql_batch_demo SET note = 'committed' WHERE id = 1;
COMMIT;

-- Left open: no COMMIT, so the server rolls back when the run's connection closes. The last
-- result shows 'uncommitted'; the table check afterwards does not
START TRANSACTION;
UPDATE abcql_batch_demo SET note = 'uncommitted' WHERE id = 1;
SELECT * FROM abcql_batch_demo ORDER BY id;

-- ---------------------------------------------------------------------------------------------
-- Errors stop the batch
-- ---------------------------------------------------------------------------------------------

-- The first INSERT runs (autocommit), the SELECT fails and is highlighted, the last INSERT never
-- runs: the table check afterwards has id 2 but not id 3
INSERT INTO abcql_batch_demo VALUES (2, 'before the error');
SELECT * FROM abcql_batch_demo_missing;
INSERT INTO abcql_batch_demo VALUES (3, 'never runs');

-- Inside a transaction: MySQL keeps the transaction open after an error, but the batch stops
-- before COMMIT and the closed connection rolls it back, so id 4 never appears
START TRANSACTION;
INSERT INTO abcql_batch_demo VALUES (4, 'rolled back');
SELECT * FROM abcql_batch_demo_missing;
COMMIT;

-- ---------------------------------------------------------------------------------------------
-- Cancel
-- ---------------------------------------------------------------------------------------------

-- Press `<C-c>` in the results window (or `:AbcqlQueryCancel`) during the SLEEP. The message says
-- statements up to and including the one running may have been applied (cancel only drops the
-- connection; the server may still finish the SLEEP): the autocommitted id 5 stays
DELETE FROM abcql_batch_demo WHERE id = 5;
INSERT INTO abcql_batch_demo VALUES (5, 'autocommitted');
DO SLEEP(30);

-- Cancelling inside a transaction rolls it back: id 6 never appears
START TRANSACTION;
INSERT INTO abcql_batch_demo VALUES (6, 'cancelled');
DO SLEEP(30);
COMMIT;

-- ---------------------------------------------------------------------------------------------
-- Safety checks still apply to every statement in a batch
-- ---------------------------------------------------------------------------------------------

-- Dangerous DELETE: one prompt up front lists it. Declining runs nothing, not even the first
-- SELECT. Accepting is still harmless here because of the ROLLBACK
SELECT COUNT(*) AS before_delete FROM abcql_batch_demo;
START TRANSACTION;
DELETE FROM abcql_batch_demo;
SELECT COUNT(*) AS inside_transaction FROM abcql_batch_demo;
ROLLBACK;

-- Auto-LIMIT is applied per statement: the first SELECT gets `LIMIT n` (one step back in
-- history), the second keeps the LIMIT you wrote
SELECT * FROM salaries;
SELECT * FROM salaries LIMIT 5;

-- On a datasource with `readonly = true`, this whole batch is refused because of the UPDATE
SELECT * FROM abcql_batch_demo;
UPDATE abcql_batch_demo SET note = 'readonly?' WHERE id = 1;

-- ---------------------------------------------------------------------------------------------
-- Separate runs don't share a session
-- ---------------------------------------------------------------------------------------------

-- Run these two one at a time with the cursor on each: the SELECT shows NULL
SET @not_kept := 42;

SELECT @not_kept;

-- ---------------------------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS abcql_batch_demo;
