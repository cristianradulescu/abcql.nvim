show databases;

show tables;

select * from employees limit 100;

select * from departments limit 100;

select * from titles limit 100;

select
  e.emp_no,
  e.first_name,
  e.last_name,
  d.dept_no,
  d.dept_name
from employees e
join dept_emp de on de.emp_no = e.emp_no
join departments d on d.dept_no = de.dept_no
limit 10;
