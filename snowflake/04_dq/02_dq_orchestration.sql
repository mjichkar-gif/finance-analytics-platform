-- =====================================================================
-- DQ ORCHESTRATION + MONITORING VIEWS
-- =====================================================================

USE ROLE FIN_ADMIN;
USE DATABASE FIN_ANALYTICS;
USE SCHEMA FIN_AUDIT;

-- ---------------------------------------------------------------------
-- Hourly DQ task — runs full suite every hour
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK TSK_DQ_VALIDATION
    WAREHOUSE        = WH_FIN_TRANSFORM
    SCHEDULE         = '60 MINUTE'
    COMMENT          = 'Runs the DQ validation suite hourly across RAW and STG layers.'
    USER_TASK_TIMEOUT_MS = 600000      -- 10-minute ceiling
AS
    CALL FIN_AUDIT.SP_RUN_DQ_SUITE();

ALTER TASK TSK_DQ_VALIDATION RESUME;

-- ---------------------------------------------------------------------
-- VW_DQ_LATEST — most recent run per check (for dashboards)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW VW_DQ_LATEST AS
SELECT *
FROM FIN_AUDIT.DQ_CHECK_RESULTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY CHECK_NAME ORDER BY EXECUTED_AT DESC) = 1;

-- ---------------------------------------------------------------------
-- VW_DQ_FAILURES_OPEN — currently failing checks (drives Slack alerts)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW VW_DQ_FAILURES_OPEN AS
SELECT
    CHECK_NAME,
    CHECK_CATEGORY,
    LAYER,
    TARGET_OBJECT,
    SEVERITY,
    OBSERVED_VALUE,
    THRESHOLD_VALUE,
    CHECK_DETAILS,
    EXECUTED_AT
FROM FIN_AUDIT.VW_DQ_LATEST
WHERE STATUS = 'FAIL'
ORDER BY
    CASE SEVERITY WHEN 'ERROR' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END,
    EXECUTED_AT DESC;

-- ---------------------------------------------------------------------
-- VW_DQ_SCORECARD — daily roll-up (pass rate, breach counts)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW VW_DQ_SCORECARD AS
SELECT
    DATE_TRUNC('day', EXECUTED_AT)                        AS check_date,
    LAYER,
    CHECK_CATEGORY,
    COUNT(*)                                              AS total_checks,
    SUM(IFF(STATUS = 'PASS', 1, 0))                       AS passed,
    SUM(IFF(STATUS = 'FAIL', 1, 0))                       AS failed,
    ROUND(SUM(IFF(STATUS = 'PASS', 1, 0)) * 100.0
          / NULLIF(COUNT(*), 0), 2)                       AS pass_rate_pct,
    SUM(IFF(STATUS = 'FAIL' AND SEVERITY = 'ERROR', 1, 0)) AS error_count,
    SUM(IFF(STATUS = 'FAIL' AND SEVERITY = 'WARN', 1, 0))  AS warn_count
FROM FIN_AUDIT.DQ_CHECK_RESULTS
WHERE EXECUTED_AT >= DATEADD('day', -30, CURRENT_DATE)
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 2, 3;

-- ---------------------------------------------------------------------
-- Reconciliation view — STG row counts vs RAW (ingest completeness)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW VW_LAYER_RECONCILIATION AS
WITH raw_counts AS (
    SELECT 'CUSTOMERS' AS entity, COUNT(*) AS raw_count
    FROM FIN_ANALYTICS.FIN_RAW.RAW_CUSTOMERS
    WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
    UNION ALL
    SELECT 'ACCOUNTS', COUNT(*)
    FROM FIN_ANALYTICS.FIN_RAW.RAW_ACCOUNTS
    WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
    UNION ALL
    SELECT 'TRANSACTIONS', COUNT(*)
    FROM FIN_ANALYTICS.FIN_RAW.RAW_TRANSACTIONS
    WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
    UNION ALL
    SELECT 'LOANS', COUNT(*)
    FROM FIN_ANALYTICS.FIN_RAW.RAW_LOANS
    WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
    UNION ALL
    SELECT 'BRANCHES', COUNT(*)
    FROM FIN_ANALYTICS.FIN_RAW.RAW_BRANCHES
    WHERE NVL(_FIVETRAN_DELETED, FALSE) = FALSE
),
stg_counts AS (
    SELECT 'CUSTOMERS'    AS entity, COUNT(*) AS stg_count FROM FIN_ANALYTICS.FIN_STG.STG_CUSTOMERS
    UNION ALL
    SELECT 'ACCOUNTS',    COUNT(*) FROM FIN_ANALYTICS.FIN_STG.STG_ACCOUNTS
    UNION ALL
    SELECT 'TRANSACTIONS', COUNT(*) FROM FIN_ANALYTICS.FIN_STG.STG_TRANSACTIONS
    UNION ALL
    SELECT 'LOANS',       COUNT(*) FROM FIN_ANALYTICS.FIN_STG.STG_LOANS
    UNION ALL
    SELECT 'BRANCHES',    COUNT(*) FROM FIN_ANALYTICS.FIN_STG.STG_BRANCHES
)
SELECT
    r.entity,
    r.raw_count,
    s.stg_count,
    r.raw_count - s.stg_count          AS row_diff,
    ROUND((s.stg_count * 100.0) / NULLIF(r.raw_count, 0), 2) AS retention_pct,
    CASE
        WHEN r.raw_count = 0 THEN 'NO_DATA'
        WHEN ABS(r.raw_count - s.stg_count) > r.raw_count * 0.05 THEN 'DRIFT_HIGH'
        WHEN r.raw_count <> s.stg_count THEN 'DRIFT_LOW'
        ELSE 'OK'
    END AS reconciliation_status
FROM raw_counts r
JOIN stg_counts s USING (entity)
ORDER BY entity;
