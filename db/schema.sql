-- Jamii Savings: accounts table (1a balance API, P1-1A-02).
-- Idempotent: safe to run against an existing database.

CREATE DATABASE IF NOT EXISTS jamii;
USE jamii;

CREATE TABLE IF NOT EXISTS accounts (
    account_number CHAR(10)      NOT NULL PRIMARY KEY,
    customer_id    INT           NOT NULL,
    status         ENUM('ACTIVE', 'DORMANT', 'CLOSED') NOT NULL DEFAULT 'ACTIVE',
    balance_amount DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    currency       CHAR(3)       NOT NULL DEFAULT 'KES',
    created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_customer_id (customer_id)
);
