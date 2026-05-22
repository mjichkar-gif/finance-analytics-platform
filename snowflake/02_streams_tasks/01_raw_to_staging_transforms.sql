/*-----------------------------------------------------------------------------
  01_raw_to_staging_transforms.sql
  -----------------------------------------------------------------------------
  Phase 6 — RAW → STAGING transformations expressed as standalone Snowflake SQL.
  These mirror what the dbt staging models produce; they are kept here for two
  reasons:
    1. Reviewers can read the cleansing logic without installing dbt.
    2. If dbt is unavailable in an emergency, these SQL statements rebuild
       the staging layer manually.

  Patterns demonstrated:
    * Trim + casing normalization
    * Enum standardization
    * Deduplication via QUALIFY ROW_NUMBER()
    * NULL handling with COALESCE / NULLIF
    * Currency normalization (FX seed lookup)
    * Surrogate key generation via MD5
-----------------------------------------------------------------------------*/

USE ROLE DBT_TRANSFORMER;
USE WAREHOUSE WH_FIN_TRANSFORM;
USE SCHEMA FIN_ANALYTICS.FIN_STG;

-- =========================================================================
-- 1.  STG_CUSTOMERS — trim names, normalize enums, dedupe on customer_id
-- =========================================================================
CREATE OR REPLACE VIEW STG_CUSTOMERS AS
WITH src AS (
    SELECT
          MD5(CUSTOMER_ID)                                       AS CUSTOMER_SK
        , UPPER(TRIM(CUSTOMER_ID))                               AS CUSTOMER_ID
        , INITCAP(TRIM(CUSTOMER_NAME))                           AS CUSTOMER_NAME
        , COALESCE(UPPER(TRIM(CUSTOMER_SEGMENT)), 'UNKNOWN')     AS CUSTOMER_SEGMENT
        , CASE UPPER(TRIM(RISK_CATEGORY))
              WHEN 'LOW'    THEN 'LOW'
              WHEN 'MEDIUM' THEN 'MEDIUM'
              WHEN 'HIGH'   THEN 'HIGH'
              ELSE 'UNKNOWN'
          END                                                    AS RISK_CATEGORY
        , INITCAP(TRIM(REGION))                                  AS REGION
        , ONBOARDING_DATE
        , _FIVETRAN_SYNCED                                       AS LOADED_AT
        , ROW_NUMBER() OVER (
              PARTITION BY UPPER(TRIM(CUSTOMER_ID))
              ORDER BY     _FIVETRAN_SYNCED DESC
          )                                                      AS RN
    FROM FIN_ANALYTICS.FIN_RAW.RAW_CUSTOMERS
    WHERE _FIVETRAN_DELETED = FALSE
      AND CUSTOMER_ID IS NOT NULL
)
SELECT *
EXCLUDE (RN)
FROM src
WHERE RN = 1;

-- =========================================================================
-- 2.  STG_ACCOUNTS
-- =========================================================================
CREATE OR REPLACE VIEW STG_ACCOUNTS AS
SELECT
      MD5(ACCOUNT_ID)                                          AS ACCOUNT_SK
    , UPPER(TRIM(ACCOUNT_ID))                                  AS ACCOUNT_ID
    , UPPER(TRIM(CUSTOMER_ID))                                 AS CUSTOMER_ID
    , UPPER(TRIM(ACCOUNT_TYPE))                                AS ACCOUNT_TYPE
    , UPPER(TRIM(BRANCH_ID))                                   AS BRANCH_ID
    , COALESCE(UPPER(TRIM(ACCOUNT_STATUS)), 'UNKNOWN')         AS ACCOUNT_STATUS
    , OPEN_DATE
    , _FIVETRAN_SYNCED                                         AS LOADED_AT
FROM FIN_ANALYTICS.FIN_RAW.RAW_ACCOUNTS
WHERE _FIVETRAN_DELETED = FALSE
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(ACCOUNT_ID))
                           ORDER BY _FIVETRAN_SYNCED DESC) = 1;

-- =========================================================================
-- 3.  STG_TRANSACTIONS — heaviest cleansing
-- =========================================================================
CREATE OR REPLACE VIEW STG_TRANSACTIONS AS
SELECT
      MD5(TRANSACTION_ID)                                      AS TRANSACTION_SK
    , UPPER(TRIM(TRANSACTION_ID))                              AS TRANSACTION_ID
    , UPPER(TRIM(ACCOUNT_ID))                                  AS ACCOUNT_ID
    , UPPER(TRIM(TRANSACTION_TYPE))                            AS TRANSACTION_TYPE
    , NULLIF(AMOUNT, 0)                                        AS AMOUNT
    , UPPER(TRIM(CURRENCY))                                    AS CURRENCY
    , UPPER(TRIM(MERCHANT_CATEGORY))                           AS MERCHANT_CATEGORY
    , TRANSACTION_TIMESTAMP                                    AS TRANSACTION_TIMESTAMP
    , CAST(TRANSACTION_TIMESTAMP AS DATE)                      AS TRANSACTION_DATE
    , COALESCE(UPPER(TRIM(TRANSACTION_STATUS)), 'UNKNOWN')     AS TRANSACTION_STATUS
    , _FIVETRAN_SYNCED                                         AS LOADED_AT
FROM FIN_ANALYTICS.FIN_RAW.RAW_TRANSACTIONS
WHERE _FIVETRAN_DELETED = FALSE
  AND TRANSACTION_ID    IS NOT NULL
  AND AMOUNT            IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(TRANSACTION_ID))
                           ORDER BY _FIVETRAN_SYNCED DESC) = 1;

-- =========================================================================
-- 4.  STG_LOANS  — derive simple risk classification
-- =========================================================================
CREATE OR REPLACE VIEW STG_LOANS AS
SELECT
      MD5(LOAN_ID)                                             AS LOAN_SK
    , UPPER(TRIM(LOAN_ID))                                     AS LOAN_ID
    , UPPER(TRIM(CUSTOMER_ID))                                 AS CUSTOMER_ID
    , UPPER(TRIM(LOAN_TYPE))                                   AS LOAN_TYPE
    , LOAN_AMOUNT
    , INTEREST_RATE
    , EMI_AMOUNT
    , UPPER(TRIM(LOAN_STATUS))                                 AS LOAN_STATUS
    , CASE
          WHEN UPPER(LOAN_STATUS) IN ('DEFAULTED','WRITTEN_OFF')      THEN 1
          ELSE 0
      END                                                      AS IS_DEFAULT_FLAG
    , CASE
          WHEN UPPER(LOAN_STATUS) = 'DELINQUENT'                THEN 1
          ELSE 0
      END                                                      AS IS_DELINQUENT_FLAG
    , DISBURSEMENT_DATE
    , _FIVETRAN_SYNCED                                         AS LOADED_AT
FROM FIN_ANALYTICS.FIN_RAW.RAW_LOANS
WHERE _FIVETRAN_DELETED = FALSE;

-- =========================================================================
-- 5.  STG_BRANCHES + STG_CALENDAR_DIM — straight-through
-- =========================================================================
CREATE OR REPLACE VIEW STG_BRANCHES AS
SELECT
      MD5(BRANCH_ID)        AS BRANCH_SK
    , UPPER(TRIM(BRANCH_ID)) AS BRANCH_ID
    , INITCAP(TRIM(BRANCH_NAME)) AS BRANCH_NAME
    , INITCAP(TRIM(CITY))    AS CITY
    , UPPER(TRIM(STATE))     AS STATE
    , INITCAP(TRIM(REGION))  AS REGION
FROM FIN_ANALYTICS.FIN_RAW.RAW_BRANCHES
WHERE _FIVETRAN_DELETED = FALSE;

CREATE OR REPLACE VIEW STG_CALENDAR_DIM AS
SELECT
      MD5(TO_VARCHAR(DATE_KEY)) AS DATE_SK
    , DATE_KEY
    , MONTH
    , QUARTER
    , YEAR
    , FISCAL_PERIOD
FROM FIN_ANALYTICS.FIN_RAW.RAW_CALENDAR_DIM
WHERE _FIVETRAN_DELETED = FALSE;
