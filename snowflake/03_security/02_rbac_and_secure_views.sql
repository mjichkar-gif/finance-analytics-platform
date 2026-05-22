-- =====================================================================
-- RBAC HARDENING + SECURE VIEWS
-- Purpose: ensure BI_READER sees only mart-layer data via SECURE views,
--          with masking policies enforced and no leakage from query plans.
-- =====================================================================

USE ROLE FIN_ADMIN;
USE DATABASE FIN_ANALYTICS;

-- ---------------------------------------------------------------------
-- Verify role hierarchy (idempotent — re-asserts the setup file)
-- ---------------------------------------------------------------------
-- BI_READER  -> SYSADMIN -> ACCOUNTADMIN
GRANT ROLE BI_READER         TO ROLE SYSADMIN;
GRANT ROLE DBT_TRANSFORMER   TO ROLE SYSADMIN;
GRANT ROLE FIVETRAN_LOADER   TO ROLE SYSADMIN;
GRANT ROLE FIN_ADMIN         TO ROLE SYSADMIN;

-- ---------------------------------------------------------------------
-- BI_READER privileges — read-only, mart-only, no usage on RAW/STG/INT
-- ---------------------------------------------------------------------
REVOKE ALL PRIVILEGES ON SCHEMA FIN_ANALYTICS.FIN_RAW FROM ROLE BI_READER;
REVOKE ALL PRIVILEGES ON SCHEMA FIN_ANALYTICS.FIN_STG FROM ROLE BI_READER;
REVOKE ALL PRIVILEGES ON SCHEMA FIN_ANALYTICS.FIN_INT FROM ROLE BI_READER;

GRANT USAGE ON DATABASE FIN_ANALYTICS                 TO ROLE BI_READER;
GRANT USAGE ON SCHEMA FIN_ANALYTICS.FIN_MART          TO ROLE BI_READER;
GRANT USAGE ON SCHEMA FIN_ANALYTICS.GOVERNANCE        TO ROLE BI_READER;
GRANT USAGE ON WAREHOUSE WH_FIN_REPORTING             TO ROLE BI_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA FIN_ANALYTICS.FIN_MART TO ROLE BI_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA FIN_ANALYTICS.FIN_MART TO ROLE BI_READER;
-- Explicitly NOT granting SELECT on tables — BI must go through SECURE views
-- (so masking policies and row-access policies enforce consistently).

-- ---------------------------------------------------------------------
-- Secure views — present mart facts to BI with PII masked + business labels
-- ---------------------------------------------------------------------

-- Customer 360 view: combines dim + LTV + risk, with masking active
CREATE OR REPLACE SECURE VIEW FIN_ANALYTICS.FIN_MART.VW_CUSTOMER_360 AS
SELECT
    c.customer_sk,
    c.customer_id,
    c.customer_name,                  -- masking policy applies
    c.customer_segment,
    c.risk_category,
    c.region,
    c.kyc_status,
    c.is_current,
    p.lifetime_value_usd,
    p.profit_estimate,
    p.risk_value_segment,
    p.transaction_count_l12m,
    p.avg_transaction_amount_usd
FROM FIN_ANALYTICS.FIN_MART.DIM_CUSTOMER c
LEFT JOIN FIN_ANALYTICS.FIN_MART.FCT_CUSTOMER_PROFITABILITY p
    ON c.customer_id = p.customer_id
WHERE c.is_current = TRUE;

COMMENT ON VIEW FIN_ANALYTICS.FIN_MART.VW_CUSTOMER_360 IS
    'BI-facing customer view. PII masked per BI_READER policy. Joins current dim_customer with latest profitability.';

-- Transaction view for fraud analysts (DBT_TRANSFORMER role)
-- Uses pre-aggregated daily roll-up, NEVER raw txn rows
CREATE OR REPLACE SECURE VIEW FIN_ANALYTICS.FIN_MART.VW_FRAUD_DAILY AS
SELECT
    transaction_date,
    region,
    customer_segment,
    COUNT(*)                                AS flagged_count,
    SUM(amount_usd)                         AS flagged_amount_usd,
    SUM(IFF(is_blocked_flag, 1, 0))         AS blocked_count,
    SUM(IFF(is_round_high_value_flag, 1, 0)) AS round_hv_count,
    SUM(IFF(is_high_value_flag, 1, 0))      AS hv_count
FROM FIN_ANALYTICS.FIN_MART.FCT_FRAUD_INDICATORS
GROUP BY 1, 2, 3;

GRANT SELECT ON VIEW FIN_ANALYTICS.FIN_MART.VW_FRAUD_DAILY TO ROLE DBT_TRANSFORMER;
GRANT SELECT ON VIEW FIN_ANALYTICS.FIN_MART.VW_FRAUD_DAILY TO ROLE BI_READER;

-- Revenue executive view
CREATE OR REPLACE SECURE VIEW FIN_ANALYTICS.FIN_MART.VW_REVENUE_EXEC AS
SELECT
    revenue_month,
    customer_segment,
    region,
    SUM(net_revenue_usd)                            AS revenue_usd,
    SUM(transaction_count)                          AS txn_count,
    SUM(active_customer_count)                      AS active_customers
FROM FIN_ANALYTICS.FIN_MART.FCT_REVENUE_MONTHLY
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- Audit: who-touched-what (for compliance review)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW FIN_ANALYTICS.GOVERNANCE.VW_ACCESS_AUDIT AS
SELECT
    user_name,
    role_name,
    query_text,
    database_name,
    schema_name,
    start_time,
    execution_status,
    total_elapsed_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP)
  AND database_name = 'FIN_ANALYTICS'
  AND query_type IN ('SELECT', 'CREATE_TABLE_AS_SELECT', 'MERGE', 'UPDATE', 'DELETE');

-- Only FIN_ADMIN can see access audit
GRANT SELECT ON VIEW FIN_ANALYTICS.GOVERNANCE.VW_ACCESS_AUDIT TO ROLE FIN_ADMIN;

-- ---------------------------------------------------------------------
-- Network policy stub (production hardening)
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE NETWORK POLICY NP_FIN_PROD
--     ALLOWED_IP_LIST = ('10.0.0.0/8', '203.0.113.0/24')   -- VPN + office
--     BLOCKED_IP_LIST = ()
--     COMMENT         = 'Restricts FIN_ANALYTICS access to corporate network.';
-- ALTER ACCOUNT SET NETWORK_POLICY = NP_FIN_PROD;

-- ---------------------------------------------------------------------
-- Session-level safety: idle timeout + statement timeout for BI_READER
-- ---------------------------------------------------------------------
ALTER USER IF EXISTS bi_user_template SET
    STATEMENT_TIMEOUT_IN_SECONDS    = 300,
    CLIENT_SESSION_KEEP_ALIVE       = FALSE,
    DEFAULT_WAREHOUSE               = WH_FIN_REPORTING,
    DEFAULT_ROLE                    = BI_READER;
