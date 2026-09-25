-- abcql: employees_test_db
--
-- Examples for the dangerous-statement lint (`query.lint_dangerous`, on by default).
--
-- Every statement in the first section gets a WARNING diagnostic on its keyword, and running it
-- always opens the confirmation float with the reason in its title, even with `confirm = "never"`.
-- The second section shows look-alikes that are NOT flagged.
--
-- These statements really modify data: press `q` in the confirmation float to cancel.
-- If you do run one, reset the test database: `make test-db-down ARGS=-v && make test-db-up`.

-- ---------------------------------------------------------------------------------------------
-- Flagged
-- ---------------------------------------------------------------------------------------------

-- UPDATE without WHERE affects every row in employees
UPDATE employees SET hire_date = CURDATE();

-- DELETE without WHERE affects every row in salaries
DELETE FROM salaries;

-- Modifiers and SQLite's `OR <conflict>` are skipped when naming the target table
UPDATE LOW_PRIORITY IGNORE titles SET to_date = '9999-01-01';

-- A literal always-true condition is no better than no WHERE at all
DELETE FROM dept_emp WHERE 1;
UPDATE employees SET gender = 'F' WHERE 1 = 1;
DELETE FROM titles WHERE TRUE;

-- A LIMIT caps the damage, but without ORDER BY the rows it hits are arbitrary
DELETE FROM salaries LIMIT 100;
-- ... and with ORDER BY it is still up to 100 rows, not a filter
DELETE FROM salaries ORDER BY from_date LIMIT 100;

-- A WHERE inside a subquery does not restrict the outer statement
UPDATE employees SET first_name = (SELECT 'x' FROM departments WHERE dept_no = 'd001');

-- A WHERE inside a string or comment does not count either
UPDATE departments SET dept_name = 'WHERE id = 1' /* WHERE dept_no = 'd001' */;

-- A CTE's WHERE does not restrict the statement that follows it
WITH recent AS (SELECT emp_no FROM employees WHERE hire_date > '1999-01-01')
UPDATE employees SET last_name = UPPER(last_name);

-- Joins that keep every row of the target table: LEFT/RIGHT, CROSS, NATURAL, comma joins,
-- and a JOIN with no ON/USING
UPDATE employees e LEFT JOIN salaries s ON s.emp_no = e.emp_no SET e.last_name = 'x';
DELETE e FROM employees e CROSS JOIN departments d;
UPDATE employees e, titles t SET t.title = 'Staff';
DELETE e FROM employees e JOIN dept_emp de;

-- TRUNCATE removes every row in the table
TRUNCATE TABLE dept_manager;
TRUNCATE salaries;

-- Several statements on one line are linted one by one: only the DELETE is flagged
SELECT COUNT(*) FROM titles; DELETE FROM titles; SELECT COUNT(*) FROM titles;

-- ---------------------------------------------------------------------------------------------
-- Not flagged
-- ---------------------------------------------------------------------------------------------

-- A real WHERE (a normal write: confirmed only if your `confirm` policy says so)
UPDATE employees SET last_name = 'Smith' WHERE emp_no = 10001;
DELETE FROM salaries WHERE emp_no = 10001 AND from_date < '1990-01-01';
DELETE FROM salaries WHERE emp_no = 10001 LIMIT 1;

-- An inner join with ON/USING already restricts the target table
UPDATE employees e JOIN dept_manager dm ON dm.emp_no = e.emp_no SET e.last_name = UPPER(e.last_name);
DELETE s FROM salaries s INNER JOIN employees e USING (emp_no);

-- DROP is not linted (it goes through the regular write confirmation)
DROP TABLE IF EXISTS scratch;

-- Reads are never flagged
SELECT * FROM employees;
