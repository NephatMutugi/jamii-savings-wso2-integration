-- Jamii Savings: seed data for accounts (P1-1A-02).
-- Idempotent: truncate-then-insert, safe to re-run.

USE jamii;

TRUNCATE TABLE accounts;

INSERT INTO accounts (account_number, customer_id, status, balance_amount, currency) VALUES
    ('1000000001', 1, 'ACTIVE',  125430.50, 'KES'),
    ('1000000002', 2, 'DORMANT',    500.00, 'KES'),
    ('1000000003', 3, 'CLOSED',       0.00, 'KES'),
    ('1000000004', 1, 'ACTIVE',   87650.00, 'KES');

-- 9999999999 is deliberately never seeded here: it is the fixed "unknown
-- account" used to prove the 404 path (P1-1A-05). Do not add it.
