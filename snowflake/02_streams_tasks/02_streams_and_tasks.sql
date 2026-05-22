/*-----------------------------------------------------------------------------
  02_streams_and_tasks.sql
  -----------------------------------------------------------------------------
  Phase 7 — Snowflake Streams & Tasks for near-real-time CDC on the highest
  velocity table (RAW_TRANSACTIONS).

  Design:
    * STREAM   on RAW_TRANSACTIONS captures inserts / updates / deletes since
               last consumption. Type = STANDARD (we want all DML).
    * STG_TRANSACTIONS_INCR is a CDC sink — a real table, MERGEd into by a task
                          every 5 minutes. Used by the fraud-monitoring layer
                          that cannot wait for the hourly dbt run.
    * TASK     on a 5-minute schedule consumes the stream, applies the same
               cleansing rules as the staging view, and MERGEs into
               STG_TRANSACTIONS_INCR.
    * Root + child task DAG so we can extend with downstream fraud-rule tasks.

  Why both Streams and dbt?
    * dbt = batch analytical layer (hourly). Reproducible, testable.
    * Streams + Tasks = operational micro-batch (5 min). Fraud team sees
                        suspicious activity inside one EMI cycle.
-----------------------------------------------------------------------------*/

USE ROLE FIN_ADMIN;
USE WAREHOUSE WH_FIN_TRANSFORM;
USE SCHEMA FIN_ANALYTICS.FIN_STG;

-- =========================================================================
-- 1.  CDC sink table
-- =========================================================================
CREATE TABLE IF NOT EXISTS STG_TRANSACTIONS_INCR (
      TRANSACTION_SK         VARCHAR
    , TRANSACTION_ID         VARCHAR
    , ACCOUNT_ID             VARCHAR
    , TRANSACTION_TYPE       VARCHAR
    , AMOUNT                 NUMBER(18,2)
    , CURRENCY               VARCHAR
    , MERCHANT_CATEGORY      VARCHAR
    , TRANSACTION_TIMESTAMP  TIMESTAMP_NTZ
    , TRANSACTION_DATE       DATE
    , TRANSACTION_STATUS     VARCHAR
    , LOADED_AT              TIMESTAMP_NTZ
    , CDC_OPERATION          VARCHAR        -- INSERT / UPDATE / DELETE
    , INGESTED_AT            TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()
    , CONSTRAINT PK_STG_TXN_INCR PRIMARY KEY (TRANSACTION_SK)
)
CLUSTER BY (TRANSACTION_DATE);

-- =========================================================================
-- 2.  Stream
-- =========================================================================
CREATE OR REPLACE STREAM STR_RAW_TRANSACTIONS
    ON TABLE FIN_ANALYTICS.FIN_RAW.RAW_TRANSACTIONS
    APPEND_ONLY = FALSE                       -- we want UPDATE + DELETE
    SHOW_INITIAL_ROWS = TRUE
    COMMENT = 'CDC on RAW_TRANSACTIONS consumed by TSK_MERGE_STG_TRANSACTIONS';

-- =========================================================================
-- 3.  Root task — MERGE the CDC delta into the staging table
-- =========================================================================
CREATE OR REPLACE TASK TSK_MERGE_STG_TRANSACTIONS
    WAREHOUSE = WH_FIN_TRANSFORM
    SCHEDULE  = '5 MINUTE'
    COMMENT   = 'Drains STR_RAW_TRANSACTIONS into STG_TRANSACTIONS_INCR'
WHEN
    SYSTEM$STREAM_HAS_DATA('STR_RAW_TRANSACTIONS')
AS
MERGE INTO STG_TRANSACTIONS_INCR  tgt
USING (
    SELECT
          MD5(TRANSACTION_ID)                                       AS TRANSACTION_SK
        , UPPER(TRIM(TRANSACTION_ID))                               AS TRANSACTION_ID
        , UPPER(TRIM(ACCOUNT_ID))                                   AS ACCOUNT_ID
        , UPPER(TRIM(TRANSACTION_TYPE))                             AS TRANSACTION_TYPE
        , AMOUNT
        , UPPER(TRIM(CURRENCY))                                     AS CURRENCY
        , UPPER(TRIM(MERCHANT_CATEGORY))                            AS MERCHANT_CATEGORY
        , TRANSACTION_TIMESTAMP
        , CAST(TRANSACTION_TIMESTAMP AS DATE)                       AS TRANSACTION_DATE
        , COALESCE(UPPER(TRIM(TRANSACTION_STATUS)), 'UNKNOWN')      AS TRANSACTION_STATUS
        , _FIVETRAN_SYNCED                                          AS LOADED_AT
        , CASE
              WHEN METADATA$ACTION = 'DELETE' AND METADATA$ISUPDATE  THEN 'UPDATE'
              WHEN METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE  THEN 'UPDATE'
              WHEN METADATA$ACTION = 'INSERT'                        THEN 'INSERT'
              WHEN METADATA$ACTION = 'DELETE'                        THEN 'DELETE'
          END                                                       AS CDC_OPERATION
    FROM STR_RAW_TRANSACTIONS
    WHERE TRANSACTION_ID IS NOT NULL
      AND AMOUNT         IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY UPPER(TRIM(TRANSACTION_ID))
        ORDER BY     _FIVETRAN_SYNCED DESC
    ) = 1
) src
ON tgt.TRANSACTION_SK = src.TRANSACTION_SK
WHEN MATCHED AND src.CDC_OPERATION = 'DELETE' THEN DELETE
WHEN MATCHED AND src.CDC_OPERATION = 'UPDATE' THEN UPDATE SET
      tgt.AMOUNT             = src.AMOUNT
    , tgt.CURRENCY           = src.CURRENCY
    , tgt.MERCHANT_CATEGORY  = src.MERCHANT_CATEGORY
    , tgt.TRANSACTION_STATUS = src.TRANSACTION_STATUS
    , tgt.LOADED_AT          = src.LOADED_AT
    , tgt.CDC_OPERATION      = 'UPDATE'
    , tgt.INGESTED_AT        = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND src.CDC_OPERATION = 'INSERT' THEN INSERT (
        TRANSACTION_SK, TRANSACTION_ID, ACCOUNT_ID, TRANSACTION_TYPE, AMOUNT,
        CURRENCY, MERCHANT_CATEGORY, TRANSACTION_TIMESTAMP, TRANSACTION_DATE,
        TRANSACTION_STATUS, LOADED_AT, CDC_OPERATION
   ) VALUES (
        src.TRANSACTION_SK, src.TRANSACTION_ID, src.ACCOUNT_ID, src.TRANSACTION_TYPE, src.AMOUNT,
        src.CURRENCY, src.MERCHANT_CATEGORY, src.TRANSACTION_TIMESTAMP, src.TRANSACTION_DATE,
        src.TRANSACTION_STATUS, src.LOADED_AT, 'INSERT'
   );

-- =========================================================================
-- 4.  Child task — flag suspicious transactions in near real time
-- =========================================================================
CREATE TABLE IF NOT EXISTS FIN_ANALYTICS.FIN_AUDIT.SUSPICIOUS_TRANSACTIONS (
      TRANSACTION_SK   VARCHAR
    , TRANSACTION_ID   VARCHAR
    , ACCOUNT_ID       VARCHAR
    , AMOUNT           NUMBER(18,2)
    , CURRENCY         VARCHAR
    , FLAG_REASON      VARCHAR
    , FLAGGED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TASK TSK_FLAG_SUSPICIOUS_TXN
    WAREHOUSE = WH_FIN_TRANSFORM
    AFTER     = TSK_MERGE_STG_TRANSACTIONS       -- runs only after parent succeeds
    COMMENT   = 'Detects round-number high-value or blocked transactions'
AS
INSERT INTO FIN_ANALYTICS.FIN_AUDIT.SUSPICIOUS_TRANSACTIONS
       (TRANSACTION_SK, TRANSACTION_ID, ACCOUNT_ID, AMOUNT, CURRENCY, FLAG_REASON)
SELECT
      TRANSACTION_SK
    , TRANSACTION_ID
    , ACCOUNT_ID
    , AMOUNT
    , CURRENCY
    , CASE
          WHEN TRANSACTION_STATUS = 'BLOCKED'                    THEN 'STATUS_BLOCKED'
          WHEN AMOUNT >= 50000 AND MOD(AMOUNT, 1000) = 0         THEN 'ROUND_NUMBER_HIGH_VALUE'
          WHEN AMOUNT >= 25000                                   THEN 'HIGH_VALUE'
      END AS FLAG_REASON
FROM STG_TRANSACTIONS_INCR
WHERE INGESTED_AT >= DATEADD('minute', -5, CURRENT_TIMESTAMP())
  AND (
        TRANSACTION_STATUS = 'BLOCKED'
    OR (AMOUNT >= 50000 AND MOD(AMOUNT, 1000) = 0)
    OR AMOUNT >= 25000
  )
  AND TRANSACTION_SK NOT IN (
        SELECT TRANSACTION_SK
        FROM   FIN_ANALYTICS.FIN_AUDIT.SUSPICIOUS_TRANSACTIONS
  );

-- =========================================================================
-- 5.  Enable the DAG
-- =========================================================================
ALTER TASK TSK_FLAG_SUSPICIOUS_TXN   RESUME;
ALTER TASK TSK_MERGE_STG_TRANSACTIONS RESUME;     -- root must be resumed LAST

-- =========================================================================
-- 6.  Operational queries
-- =========================================================================
-- Inspect pending stream rows
-- SELECT SYSTEM$STREAM_HAS_DATA('STR_RAW_TRANSACTIONS');
-- SELECT COUNT(*) FROM STR_RAW_TRANSACTIONS;

-- Task history
-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--     SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
--     TASK_NAME                  => 'TSK_MERGE_STG_TRANSACTIONS'
-- ))
-- ORDER BY SCHEDULED_TIME DESC;

-- Stop the DAG (during maintenance)
-- ALTER TASK TSK_MERGE_STG_TRANSACTIONS SUSPEND;
-- ALTER TASK TSK_FLAG_SUSPICIOUS_TXN   SUSPEND;
