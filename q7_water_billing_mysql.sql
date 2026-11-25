-- Question 7: Water Meter Readings and Billing (MySQL 8.0.16+)
-- CHECK constraints are only enforced from 8.0.16, so use 8.0.16 or later.

DROP DATABASE IF EXISTS water_db;
CREATE DATABASE water_db;
USE water_db;

-- =====================================================================
-- (a) DATABASE AND SEED DATA
-- =====================================================================
CREATE TABLE customers (
    customer_id INT AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE readings (
    reading_id       INT AUTO_INCREMENT PRIMARY KEY,
    customer_id      INT           NOT NULL,
    reading_month    DATE          NOT NULL,
    previous_reading DECIMAL(10,2) NOT NULL,
    current_reading  DECIMAL(10,2) NOT NULL,
    CONSTRAINT fk_read_cust FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),
    CONSTRAINT uq_read_cust_month UNIQUE (customer_id, reading_month),
    CONSTRAINT ck_read_prev  CHECK (previous_reading >= 0),
    CONSTRAINT ck_read_cur   CHECK (current_reading  >= 0),
    CONSTRAINT ck_read_month CHECK (DAY(reading_month) = 1)
) ENGINE=InnoDB;

CREATE TABLE bills (
    bill_id     INT AUTO_INCREMENT PRIMARY KEY,
    reading_id  INT           NOT NULL,
    charge      DECIMAL(10,2) NOT NULL,
    amount_paid DECIMAL(10,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT fk_bill_read FOREIGN KEY (reading_id)
        REFERENCES readings(reading_id),
    CONSTRAINT uq_bill_reading UNIQUE (reading_id),
    CONSTRAINT ck_bill_charge CHECK (charge >= 0),
    CONSTRAINT ck_bill_paid   CHECK (amount_paid >= 0 AND amount_paid <= charge)
) ENGINE=InnoDB;

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     DECIMAL(12,2) NOT NULL,
    CONSTRAINT ck_snap_total CHECK (total_due >= 0)
) ENGINE=InnoDB;

-- Triggers are created in (d) BEFORE the seed readings so the seed data
-- also passes through the validation. (Seed inserts come after section (g).)

-- =====================================================================
-- (b) FUNCTION fn_water_charge
-- First 10 units @ K5, units above 10 @ K8. 0 units = K0.00
-- =====================================================================
DELIMITER $$

CREATE FUNCTION fn_water_charge(p_units DECIMAL(10,2))
RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
    DECLARE v_charge DECIMAL(10,2);

    IF p_units IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Consumption cannot be NULL';
    END IF;

    IF p_units < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Consumption cannot be negative';
    END IF;

    IF p_units <= 10 THEN
        SET v_charge = p_units * 5;
    ELSE
        SET v_charge = 10 * 5 + (p_units - 10) * 8;
    END IF;

    RETURN ROUND(v_charge, 2);
END$$

-- =====================================================================
-- (c) PROCEDURE pr_generate_bill
-- =====================================================================
CREATE PROCEDURE pr_generate_bill(IN p_reading_id INT, IN p_due_on DATE)
BEGIN
    DECLARE v_count  INT DEFAULT 0;
    DECLARE v_prev   DECIMAL(10,2);
    DECLARE v_cur    DECIMAL(10,2);
    DECLARE v_units  DECIMAL(10,2);
    DECLARE v_charge DECIMAL(10,2);

    IF p_due_on IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Due date is required';
    END IF;

    -- Unknown reading?
    SELECT COUNT(*) INTO v_count
    FROM readings WHERE reading_id = p_reading_id;
    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unknown reading';
    END IF;

    -- Already billed? (the UNIQUE key on bills.reading_id is the final guard)
    SELECT COUNT(*) INTO v_count
    FROM bills WHERE reading_id = p_reading_id;
    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Reading already has a bill';
    END IF;

    SELECT previous_reading, current_reading
      INTO v_prev, v_cur
    FROM readings
    WHERE reading_id = p_reading_id;

    SET v_units  = v_cur - v_prev;
    SET v_charge = fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END$$

-- =====================================================================
-- (d) TRIGGERS
-- MySQL has no "BEFORE INSERT OR UPDATE" in one trigger, so two triggers
-- with the same rule are needed. SIGNAL in a BEFORE trigger aborts the
-- statement, so the bad row is never stored (InnoDB also rolls back a
-- multi-row statement as a whole).
-- =====================================================================
CREATE TRIGGER trg_readings_bi
BEFORE INSERT ON readings
FOR EACH ROW
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'current_reading cannot be below previous_reading';
    END IF;
END$$

CREATE TRIGGER trg_readings_bu
BEFORE UPDATE ON readings
FOR EACH ROW
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'current_reading cannot be below previous_reading';
    END IF;
END$$

-- =====================================================================
-- (g) PROCEDURE pr_refresh_receivables
-- Same date rerun replaces the old total (ON DUPLICATE KEY UPDATE).
-- =====================================================================
CREATE PROCEDURE pr_refresh_receivables()
BEGIN
    DECLARE v_total DECIMAL(12,2);

    SELECT COALESCE(SUM(charge - amount_paid), 0)
      INTO v_total
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total)
    ON DUPLICATE KEY UPDATE total_due = v_total;
END$$

DELIMITER ;

-- =====================================================================
-- SEED DATA
-- Readings: 0 units, exactly 10, 7, 15, 25 and 11 units
-- =====================================================================
INSERT INTO customers (full_name) VALUES
 ('Mary Banda'),
 ('John Phiri'),
 ('Grace Tembo');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),   -- reading 1: 0 units  -> K0.00
 (1, '2026-10-01', 100, 110),   -- reading 2: 10 units -> K50.00
 (2, '2026-09-01', 200, 215),   -- reading 3: 15 units -> K90.00
 (2, '2026-10-01', 215, 222),   -- reading 4: 7 units  -> K35.00
 (3, '2026-09-01',  50,  75),   -- reading 5: 25 units -> K170.00
 (3, '2026-10-01',  75,  86);   -- reading 6: 11 units -> K58.00

-- Bills: September bills are past due; October bills are not yet due
CALL pr_generate_bill(1, '2026-10-15');
CALL pr_generate_bill(3, '2026-10-15');
CALL pr_generate_bill(5, '2026-10-15');
CALL pr_generate_bill(2, '2026-12-15');
CALL pr_generate_bill(4, '2026-12-15');
CALL pr_generate_bill(6, '2026-12-15');

-- Some payments: bill for reading 2 paid in full, reading 3 part-paid
UPDATE bills SET amount_paid = 50 WHERE reading_id = 2;
UPDATE bills SET amount_paid = 40 WHERE reading_id = 3;

-- =====================================================================
-- (e) VIEW
-- =====================================================================
CREATE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- =====================================================================
-- (f) INDEX
-- Overdue searches filter on due_on (a range: due_on < today) and then on
-- amount_paid < charge. A range on due_on is the leading column, so the
-- search seeks only bills already past due instead of scanning all bills.
-- amount_paid and charge are included so the "unpaid" test and the
-- outstanding amount are read from the index itself (covering index);
-- bill_id is carried automatically because InnoDB secondary indexes
-- include the primary key. The existing UNIQUE(reading_id) index cannot
-- help a due_on search, so this is not a duplicate.
-- MySQL has no partial index, so unpaid-only filtering is done by the
-- amount_paid < charge test inside the index.
-- =====================================================================
CREATE INDEX idx_bills_due_unpaid ON bills (due_on, amount_paid, charge);

-- Matching unpaid-bill query
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;
-- Expected: key = idx_bills_due_unpaid, type = range,
--           Extra = Using where; Using index (covering)
-- On a tiny table the optimizer may still choose a full scan; to show the
-- plan it would use on a large table:
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills FORCE INDEX (idx_bills_due_unpaid)
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

-- =====================================================================
-- (g) SCHEDULED JOB: daily at 00:30 (MySQL Event Scheduler)
-- =====================================================================
SET GLOBAL event_scheduler = ON;   -- needs SUPER / SYSTEM_VARIABLES_ADMIN

CREATE EVENT ev_daily_receivables
ON SCHEDULE EVERY 1 DAY
STARTS '2026-11-26 00:30:00'
DO CALL pr_refresh_receivables();

-- Inspect the job
SHOW EVENTS FROM water_db;
SELECT event_name, status, interval_value, interval_field, starts, last_executed
FROM information_schema.EVENTS
WHERE event_schema = 'water_db' AND event_name = 'ev_daily_receivables';

-- =====================================================================
-- TEST SCRIPT
-- =====================================================================
-- Function
SELECT fn_water_charge(0)  AS zero_units,    -- 0.00
       fn_water_charge(10) AS ten_units,     -- 50.00
       fn_water_charge(15) AS fifteen_units; -- 90.00
-- SELECT fn_water_charge(NULL);   -- ERROR
-- SELECT fn_water_charge(-1);     -- ERROR

SELECT * FROM bills;

-- Procedure rejections
-- CALL pr_generate_bill(99, '2026-12-15');  -- ERROR: Unknown reading
-- CALL pr_generate_bill(1,  '2026-12-15');  -- ERROR: already has a bill

-- Trigger rejections (nothing is stored)
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
-- VALUES (1, '2026-11-01', 110, 100);                       -- ERROR
-- UPDATE readings SET current_reading = 1 WHERE reading_id = 2;  -- ERROR
SELECT COUNT(*) FROM readings;   -- still 6

-- View: Mary's zero bill and paid bill are excluded; John 50.00, Grace 170.00
SELECT * FROM v_overdue_bills;

-- Snapshot: run twice, still one row for today (replaced, not duplicated)
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
-- Unpaid total = 50 (John, reading 3) + 170 (Grace, reading 5)
--              + 35 (reading 4) + 58 (reading 6) = 313.00
