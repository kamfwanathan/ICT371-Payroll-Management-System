-- ICT371 Q6: Monthly Payroll Processing  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT ck_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit();

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
  ('Alice Mulenga', 8000, 1500, 1200, TRUE),
  ('Brian Tembo',   6500, 1000,  900, TRUE),
  ('Chola Mumba',   7200,  800, 1000, TRUE),
  ('Dalitso Phiri', 5000,  500,  700, TRUE),
  ('Esther Zimba',  9000, 2000, 1500, TRUE);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure with a query FOR loop; any exception aborts the whole call
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE rec RECORD;
BEGIN
  IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
    RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
  END IF;
  FOR rec IN
    SELECT employee_id, basic_salary, allowance
    FROM employees WHERE active ORDER BY employee_id
  LOOP
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (rec.employee_id, p_month,
            rec.basic_salary + rec.allowance,
            fn_net_pay(rec.employee_id))          -- raises if the calculation is invalid
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END;
$$;

-- Two payroll months (all employees active at the time)
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Later changes: one employee becomes inactive, one salary changes (trigger fires)
UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;
UPDATE employees SET allowance = 1500 WHERE employee_id = 1;    -- salary unchanged: no audit row
-- Tests:
-- CALL pr_process_payroll(DATE '2026-09-15');     -- error: not a month start
-- CALL pr_process_payroll(DATE '2026-09-01');     -- rerun: nothing changes
-- SELECT fn_net_pay(1);

-- (e) View: LEFT side is payroll, so inactive employees' history remains
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no filter on e.active

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index: pay_month leads, unlike UNIQUE (employee_id, pay_month)
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
-- Justification: the existing unique index starts with employee_id, so it cannot
-- efficiently serve "all employees for one month". This single-column index is not a duplicate.
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Schedule: 02:00 on the 1st, for the first day of the previous month
SELECT cron.schedule('process_payroll_monthly', '0 2 1 * *',
  $cron$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cron$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job
WHERE jobname = 'process_payroll_monthly';
SELECT runid, job_pid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll_monthly')
ORDER BY start_time DESC;

SELECT * FROM salary_audit;
