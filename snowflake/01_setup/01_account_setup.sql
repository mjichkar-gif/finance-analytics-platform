/*-----------------------------------------------------------------------------
  01_account_setup.sql
  -----------------------------------------------------------------------------
  Phase 2 — Snowflake foundation for the Finance Analytics Platform.

  Creates:
    * Warehouses  : ingest, transform, reporting (separated for cost attribution)
    * Database    : FIN_ANALYTICS
    * Schemas     : FIN_RAW, FIN_STG, FIN_INT, FIN_MART, FIN_AUDIT
    * Roles       : FIVETRAN_LOADER, DBT_TRANSFORMER, BI_READER, FIN_ADMIN
    * Grants      : least-privilege model
    * File formats and internal stage for CSV bootstrap loads

  Run as ACCOUNTADMIN. Idempotent.
-----------------------------------------------------------------------------*/

USE ROLE ACCOUNTADMIN;

-- =========================================================================
-- 1.  Warehouses  (sized for POC; up-size in higher environments)
-- =========================================================================
CREATE WAREHOUSE IF NOT EXISTS WH_FIN_INGEST
  WAREHOUSE_SIZE  = 'XSMALL'
  AUTO_SUSPEND    = 60
  AUTO_RESUME     = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT         = 'Used by Fivetran for ingestion only';

CREATE WAREHOUSE IF NOT EXISTS WH_FIN_TRANSFORM
  WAREHOUSE_SIZE  = 'XSMALL'
  AUTO_SUSPEND    = 60
  AUTO_RESUME     = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT         = 'Used by dbt and Snowflake tasks';

CREATE WAREHOUSE IF NOT EXISTS WH_FIN_REPORTING
  WAREHOUSE_SIZE  = 'XSMALL'
  AUTO_SUSPEND    = 60
  AUTO_RESUME     = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT         = 'Used by BI/reporting consumers';

-- =========================================================================
-- 2.  Database and schemas (medallion layers)
-- =========================================================================
CREATE DATABASE IF NOT EXISTS FIN_ANALYTICS
  COMMENT = 'Enterprise Financial Performance & Risk Analytics';

USE DATABASE FIN_ANALYTICS;

CREATE SCHEMA IF NOT EXISTS FIN_RAW   COMMENT = 'Landed source data — immutable';
CREATE SCHEMA IF NOT EXISTS FIN_STG   COMMENT = 'Staging — cleansed, typed, conformed';
CREATE SCHEMA IF NOT EXISTS FIN_INT   COMMENT = 'Intermediate — business logic';
CREATE SCHEMA IF NOT EXISTS FIN_MART  COMMENT = 'Marts — star schema, BI contract';
CREATE SCHEMA IF NOT EXISTS FIN_AUDIT COMMENT = 'DQ audit results and run metadata';

-- =========================================================================
-- 3.  Roles
-- =========================================================================
CREATE ROLE IF NOT EXISTS FIN_ADMIN          COMMENT = 'Platform owner';
CREATE ROLE IF NOT EXISTS FIVETRAN_LOADER    COMMENT = 'Fivetran service account role';
CREATE ROLE IF NOT EXISTS DBT_TRANSFORMER    COMMENT = 'dbt service account role';
CREATE ROLE IF NOT EXISTS BI_READER          COMMENT = 'BI tools — read-only on FIN_MART';

GRANT ROLE FIN_ADMIN        TO ROLE SYSADMIN;
GRANT ROLE FIVETRAN_LOADER  TO ROLE FIN_ADMIN;
GRANT ROLE DBT_TRANSFORMER  TO ROLE FIN_ADMIN;
GRANT ROLE BI_READER        TO ROLE FIN_ADMIN;

-- =========================================================================
-- 4.  Grants
-- =========================================================================

--  FIN_ADMIN owns everything
GRANT OWNERSHIP ON DATABASE FIN_ANALYTICS  TO ROLE FIN_ADMIN COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL SCHEMAS IN DATABASE FIN_ANALYTICS TO ROLE FIN_ADMIN COPY CURRENT GRANTS;
GRANT USAGE ON WAREHOUSE WH_FIN_INGEST     TO ROLE FIN_ADMIN;
GRANT USAGE ON WAREHOUSE WH_FIN_TRANSFORM  TO ROLE FIN_ADMIN;
GRANT USAGE ON WAREHOUSE WH_FIN_REPORTING  TO ROLE FIN_ADMIN;

--  FIVETRAN_LOADER  →  write only to FIN_RAW
GRANT USAGE    ON WAREHOUSE WH_FIN_INGEST           TO ROLE FIVETRAN_LOADER;
GRANT USAGE    ON DATABASE  FIN_ANALYTICS           TO ROLE FIVETRAN_LOADER;
GRANT USAGE    ON SCHEMA    FIN_ANALYTICS.FIN_RAW   TO ROLE FIVETRAN_LOADER;
GRANT CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT, CREATE PIPE
       ON SCHEMA FIN_ANALYTICS.FIN_RAW              TO ROLE FIVETRAN_LOADER;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE
       ON FUTURE TABLES IN SCHEMA FIN_ANALYTICS.FIN_RAW TO ROLE FIVETRAN_LOADER;

--  DBT_TRANSFORMER  →  read RAW, write STG/INT/MART/AUDIT
GRANT USAGE ON WAREHOUSE WH_FIN_TRANSFORM            TO ROLE DBT_TRANSFORMER;
GRANT USAGE ON DATABASE  FIN_ANALYTICS               TO ROLE DBT_TRANSFORMER;
GRANT USAGE ON SCHEMA FIN_ANALYTICS.FIN_RAW          TO ROLE DBT_TRANSFORMER;
GRANT SELECT ON ALL TABLES IN SCHEMA FIN_ANALYTICS.FIN_RAW    TO ROLE DBT_TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FIN_ANALYTICS.FIN_RAW TO ROLE DBT_TRANSFORMER;

GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE MATERIALIZED VIEW,
      CREATE SEQUENCE, CREATE PROCEDURE, CREATE FUNCTION,
      CREATE STREAM, CREATE TASK
       ON SCHEMA FIN_ANALYTICS.FIN_STG  TO ROLE DBT_TRANSFORMER;
GRANT USAGE, CREATE TABLE, CREATE VIEW
       ON SCHEMA FIN_ANALYTICS.FIN_INT  TO ROLE DBT_TRANSFORMER;
GRANT USAGE, CREATE TABLE, CREATE VIEW, CREATE MATERIALIZED VIEW
       ON SCHEMA FIN_ANALYTICS.FIN_MART TO ROLE DBT_TRANSFORMER;
GRANT USAGE, CREATE TABLE, CREATE VIEW
       ON SCHEMA FIN_ANALYTICS.FIN_AUDIT TO ROLE DBT_TRANSFORMER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DBT_TRANSFORMER;

-- BI_READER  →  read-only on FIN_MART, no PII visibility (see 03_security.sql)
GRANT USAGE ON WAREHOUSE WH_FIN_REPORTING             TO ROLE BI_READER;
GRANT USAGE ON DATABASE  FIN_ANALYTICS                TO ROLE BI_READER;
GRANT USAGE ON SCHEMA FIN_ANALYTICS.FIN_MART          TO ROLE BI_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA FIN_ANALYTICS.FIN_MART        TO ROLE BI_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA FIN_ANALYTICS.FIN_MART     TO ROLE BI_READER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA FIN_ANALYTICS.FIN_MART        TO ROLE BI_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA FIN_ANALYTICS.FIN_MART      TO ROLE BI_READER;

-- =========================================================================
-- 5.  File format + internal stage (for the bootstrap CSV load)
-- =========================================================================
USE SCHEMA FIN_ANALYTICS.FIN_RAW;

CREATE OR REPLACE FILE FORMAT FF_CSV_STD
    TYPE                         = CSV
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF                      = ('','NULL','null')
    EMPTY_FIELD_AS_NULL          = TRUE
    TRIM_SPACE                   = TRUE
    DATE_FORMAT                  = 'YYYY-MM-DD'
    TIMESTAMP_FORMAT             = 'YYYY-MM-DD HH24:MI:SS'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

CREATE STAGE IF NOT EXISTS STG_FIN_BOOTSTRAP
    FILE_FORMAT = FF_CSV_STD
    COMMENT     = 'Internal stage for bootstrap CSV loads (POC). Fivetran will replace this in prod.';
