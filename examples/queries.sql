-- abcql: employees

SHOW DATABASES;

SHOW TABLES;

DESCRIBE employees;
SHOW CREATE TABLE employees;

SELECT * FROM employees LIMIT 100;

SELECT * FROM departments LIMIT 100;

SELECT * FROM titles LIMIT 100;

SELECT
  e.emp_no,
  e.first_name,
  e.last_name,
  d.dept_no,
  d.dept_name
FROM employees e
JOIN dept_emp de ON de.emp_no = e.emp_no
JOIN departments d ON d.dept_no = de.dept_no
LIMIT 10;

select * from salaries;

select * from dept_manager;
