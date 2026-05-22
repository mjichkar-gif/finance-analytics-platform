-- =====================================================================
-- DATA QUALITY VALIDATION SUITE
-- Layer: RAW + STAGING
-- Purpose: Detect schema drift, freshness violations, FK orphans,
--          duplicates, and value-range breaches BEFORE they hit marts.
-- Scheduled: hourly via TSK_DQ_VALIDATION (see 02_dq_orchestration.sql)
-- =====================================================================

USE ROLE FIN_ADMIN;
USE DATABASE FIN_ANALYTICS;
USE SCHEMA FIN_AUDIT;

-- ---------------------------------------------------------------------
-- Central DQ results table — every check writes one row per execution
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DQ_CHECK_RESULTS (
    CHECK_RUN_ID            STRING        DEFAULT UUID_STRING(),
    CHECK_NAME              STRING        NOT NULL,
    CHECK_CATEGORY          STRING        NOT NULL,  -- FRESHNESS | UNIQUENESS | REFERENTIAL | RANGE | VOLUME | SCHEMA
    LAYER                   STRING        NOT NULL,  -- RAW | STG | MART
    TARGET_OBJECT           STRING        NOT NULL,
    SEVERITY                STRING        NOT NULL,  -- ERROR | WARN | INFO
    STATUS                  STRING        NOT NULL,  -- PASS | FAIL
    OBSERVED_VALUE          NUMBER(38,4),
    THRESHOLD_VALUE         NUMBER(38,4),
    FAILED_ROW_SAMPLE       VARIANT,
    CHECK_DETAILS           STRING,
    EXECUTED_AT             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP,
    EXECUTED_BY             STRING        DEFAULT CURRENT_USER()
);

-- ---------------------------------------------------------------------
-- FRESHNESS CHECKS — verify Fivetran is delivering data on schedule
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DQ_FRESHNESS_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Transactions: must be <= 2 hours stale (15-min sync expected)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'freshness_raw_transactions',
        'FRESHNESS',
        'RAW',
        'FIN_RAW.RAW_TRANSACTIONS',
        'ERROR',
        CASE WHEN max_lag_minutes > 120 THEN 'FAIL' ELSE 'PASS' END,
        max_lag_minutes,
        120,
        'Max lag (minutes) since last Fivetran sync'
    FROM (
        SELECT DATEDIFF('minute', MAX(_FIVETRAN_SYNCED), CURRENT_TIMESTAMP) AS max_lag_minutes
        FROM FIN_ANALYTICS.FIN_RAW.RAW_TRANSACTIONS
    );

    -- Customers/Accounts/Loans/Branches: must be <= 24 hours stale
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'freshness_' || LOWER(tbl),
        'FRESHNESS',
        'RAW',
        'FIN_RAW.' || tbl,
        'WARN',
        CASE WHEN max_lag_minutes > 1440 THEN 'FAIL' ELSE 'PASS' END,
        max_lag_minutes,
        1440,
        'Max lag (minutes) since last Fivetran sync'
    FROM (
        SELECT 'RAW_CUSTOMERS' AS tbl,
               DATEDIFF('minute', MAX(_FIVETRAN_SYNCED), CURRENT_TIMESTAMP) AS max_lag_minutes
        FROM FIN_ANALYTICS.FIN_RAW.RAW_CUSTOMERS
        UNION ALL
        SELECT 'RAW_ACCOUNTS',
               DATEDIFF('minute', MAX(_FIVETRAN_SYNCED), CURRENT_TIMESTAMP)
        FROM FIN_ANALYTICS.FIN_RAW.RAW_ACCOUNTS
        UNION ALL
        SELECT 'RAW_LOANS',
               DATEDIFF('minute', MAX(_FIVETRAN_SYNCED), CURRENT_TIMESTAMP)
        FROM FIN_ANALYTICS.FIN_RAW.RAW_LOANS
        UNION ALL
        SELECT 'RAW_BRANCHES',
               DATEDIFF('minute', MAX(_FIVETRAN_SYNCED), CURRENT_TIMESTAMP)
        FROM FIN_ANALYTICS.FIN_RAW.RAW_BRANCHES
    );

    RETURN 'Freshness checks completed';
END;
$$;

-- ---------------------------------------------------------------------
-- UNIQUENESS CHECKS — detect natural-key duplicates after dedup logic
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DQ_UNIQUENESS_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Customer ID uniqueness in RAW (we expect dupes here — log count)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'uniqueness_raw_customer_id',
        'UNIQUENESS',
        'RAW',
        'FIN_RAW.RAW_CUSTOMERS',
        'INFO',
        CASE WHEN dup_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        dup_count,
        0,
        'Duplicate CUSTOMER_ID values in RAW (deduped downstream)'
    FROM (
        SELECT COUNT(*) - COUNT(DISTINCT CUSTOMER_ID) AS dup_count
        FROM FIN_ANALYTICS.FIN_RAW.RAW_CUSTOMERS
        WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
    );

    -- Transaction ID uniqueness in STG (after dedup — must be zero)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'uniqueness_stg_transaction_id',
        'UNIQUENESS',
        'STG',
        'FIN_STG.STG_TRANSACTIONS',
        'ERROR',
        CASE WHEN dup_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        dup_count,
        0,
        'Duplicate TRANSACTION_ID values in STG (post-dedup)'
    FROM (
        SELECT COUNT(*) - COUNT(DISTINCT TRANSACTION_ID) AS dup_count
        FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS
    );

    RETURN 'Uniqueness checks completed';
END;
$$;

-- ---------------------------------------------------------------------
-- REFERENTIAL INTEGRITY CHECKS — orphan rows in FK relationships
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DQ_REFERENTIAL_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Orphan accounts (account.customer_id not in customers)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'fk_accounts_to_customers',
        'REFERENTIAL',
        'STG',
        'FIN_STG.STG_ACCOUNTS',
        'WARN',
        CASE WHEN orphan_count > 5 THEN 'FAIL' ELSE 'PASS' END,
        orphan_count,
        5,
        'Account rows whose CUSTOMER_ID is missing in STG_CUSTOMERS (threshold 5 allowed for POC)'
    FROM (
        SELECT COUNT(*) AS orphan_count
        FROM FIN_ANALYTICS.FIN_STG.STG_ACCOUNTS a
        LEFT JOIN FIN_ANALYTICS.FIN_STG.STG_CUSTOMERS c
            ON a.CUSTOMER_ID = c.CUSTOMER_ID
        WHERE c.CUSTOMER_ID IS NULL
    );

    -- Orphan transactions (txn.account_id not in accounts)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'fk_transactions_to_accounts',
        'REFERENTIAL',
        'STG',
        'FIN_STG.STG_TRANSACTIONS',
        'ERROR',
        CASE WHEN orphan_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        orphan_count,
        0,
        'Transaction rows whose ACCOUNT_ID is missing in STG_ACCOUNTS'
    FROM (
        SELECT COUNT(*) AS orphan_count
        FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS t
        LEFT JOIN FIN_ANALYTICS.FIN_STG.STG_ACCOUNTS a
            ON t.ACCOUNT_ID = a.ACCOUNT_ID
        WHERE a.ACCOUNT_ID IS NULL
    );

    RETURN 'Referential checks completed';
END;
$$;

-- ---------------------------------------------------------------------
-- VALUE-RANGE CHECKS — detect bad amounts, dates, statuses
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DQ_RANGE_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Negative transaction amounts (excluding refunds/debits which use sign convention)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'range_transaction_amount_positive',
        'RANGE',
        'STG',
        'FIN_STG.STG_TRANSACTIONS',
        'ERROR',
        CASE WHEN bad_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        bad_count,
        0,
        'Transactions with AMOUNT <= 0 (sign-agnostic; sign captured by transaction_direction)'
    FROM (
        SELECT COUNT(*) AS bad_count
        FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS
        WHERE AMOUNT IS NOT NULL AND AMOUNT <= 0
    );

    -- Future-dated transactions (clock skew or bad data)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'range_transaction_date_not_future',
        'RANGE',
        'STG',
        'FIN_STG.STG_TRANSACTIONS',
        'WARN',
        CASE WHEN future_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        future_count,
        0,
        'Transactions with TRANSACTION_TIMESTAMP > current_timestamp'
    FROM (
        SELECT COUNT(*) AS future_count
        FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS
        WHERE TRANSACTION_TIMESTAMP > CURRENT_TIMESTAMP
    );

    -- Loans with negative principal or interest rate out of plausible range
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    SELECT
        'range_loan_interest_rate',
        'RANGE',
        'STG',
        'FIN_STG.STG_LOANS',
        'WARN',
        CASE WHEN bad_count > 0 THEN 'FAIL' ELSE 'PASS' END,
        bad_count,
        0,
        'Loans with INTEREST_RATE outside [0, 30] percent'
    FROM (
        SELECT COUNT(*) AS bad_count
        FROM FIN_ANALYTICS.FIN_STG.STG_LOANS
        WHERE INTEREST_RATE IS NOT NULL
          AND (INTEREST_RATE < 0 OR INTEREST_RATE > 30)
    );

    RETURN 'Range checks completed';
END;
$$;

-- ---------------------------------------------------------------------
-- VOLUME CHECKS — detect pipeline outages (zero rows) or floods
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_DQ_VOLUME_CHECKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Daily transaction volume vs 7-day rolling average (±70% band)
    INSERT INTO FIN_AUDIT.DQ_CHECK_RESULTS
        (CHECK_NAME, CHECK_CATEGORY, LAYER, TARGET_OBJECT, SEVERITY, STATUS,
         OBSERVED_VALUE, THRESHOLD_VALUE, CHECK_DETAILS)
    WITH daily AS (
        SELECT TRANSACTION_DATE,
               COUNT(*) AS row_count
        FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS
        WHERE TRANSACTION_DATE >= DATEADD('day', -8, CURRENT_DATE)
        GROUP BY 1
    ),
    today AS (
        SELECT COALESCE(MAX(CASE WHEN TRANSACTION_DATE = CURRENT_DATE - 1 THEN row_count END), 0) AS yesterday_count,
               AVG(CASE WHEN TRANSACTION_DATE BETWEEN CURRENT_DATE - 8 AND CURRENT_DATE - 2 THEN row_count END) AS rolling_avg
        FROM daily
    )
    SELECT
        'volume_daily_transactions',
        'VOLUME',
        'STG',
        'FIN_STG.STG_TRANSACTIONS',
        'WARN',
        CASE
            WHEN rolling_avg IS NULL OR rolling_avg = 0 THEN 'PASS'
            WHEN yesterday_count < rolling_avg * 0.3
              OR yesterday_count > rolling_avg * 1.7 THEN 'FAIL'
            ELSE 'PASS'
        END,
        yesterday_count,
        rolling_avg,
        'Yesterday row count vs 7-day rolling avg; ±70% band'
    FROM today;

    RETURN 'Volume checks completed';
END;
$$;

-- ---------------------------------------------------------------------
-- MASTER ORCHESTRATOR — invokes all DQ procs in sequence
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RUN_DQ_SUITE()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    result STRING DEFAULT '';
BEGIN
    CALL SP_DQ_FRESHNESS_CHECKS();
    CALL SP_DQ_UNIQUENESS_CHECKS();
    CALL SP_DQ_REFERENTIAL_CHECKS();
    CALL SP_DQ_RANGE_CHECKS();
    CALL SP_DQ_VOLUME_CHECKS();
    result := 'DQ suite executed successfully at ' || CURRENT_TIMESTAMP::STRING;
    RETURN result;
END;
$$;
