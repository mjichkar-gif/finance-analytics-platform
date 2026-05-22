/*-----------------------------------------------------------------------------
  02_raw_tables.sql
  -----------------------------------------------------------------------------
  Raw landed tables. In production these are auto-created by Fivetran on first
  sync of the Google Sheets source — DDL is captured here as documentation
  and to support a clean POC bootstrap from CSV.

  Conventions:
    * Schema  = FIN_RAW
    * Naming  = RAW_<source_entity>
    * Types   = source-faithful (VARCHAR for ids, NUMBER for decimals,
                TIMESTAMP_NTZ for datetimes). No business casting here.
    * Audit   = every table carries _FIVETRAN_SYNCED and _FIVETRAN_DELETED
-----------------------------------------------------------------------------*/

USE ROLE FIN_ADMIN;
USE WAREHOUSE WH_FIN_INGEST;
USE SCHEMA FIN_ANALYTICS.FIN_RAW;

CREATE TABLE IF NOT EXISTS RAW_CUSTOMERS (
    CUSTOMER_ID         VARCHAR,
    CUSTOMER_NAME       VARCHAR,
    CUSTOMER_SEGMENT    VARCHAR,
    RISK_CATEGORY       VARCHAR,
    REGION              VARCHAR,
    ONBOARDING_DATE     DATE,
    _FIVETRAN_SYNCED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED   BOOLEAN       DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS RAW_ACCOUNTS (
    ACCOUNT_ID          VARCHAR,
    CUSTOMER_ID         VARCHAR,
    ACCOUNT_TYPE        VARCHAR,
    BRANCH_ID           VARCHAR,
    ACCOUNT_STATUS      VARCHAR,
    OPEN_DATE           DATE,
    _FIVETRAN_SYNCED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED   BOOLEAN       DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS RAW_TRANSACTIONS (
    TRANSACTION_ID          VARCHAR,
    ACCOUNT_ID              VARCHAR,
    TRANSACTION_TYPE        VARCHAR,
    AMOUNT                  NUMBER(18,2),
    CURRENCY                VARCHAR,
    MERCHANT_CATEGORY       VARCHAR,
    TRANSACTION_TIMESTAMP   TIMESTAMP_NTZ,
    TRANSACTION_STATUS      VARCHAR,
    _FIVETRAN_SYNCED        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED       BOOLEAN       DEFAULT FALSE
)
CLUSTER BY (TRANSACTION_TIMESTAMP);

CREATE TABLE IF NOT EXISTS RAW_LOANS (
    LOAN_ID             VARCHAR,
    CUSTOMER_ID         VARCHAR,
    LOAN_TYPE           VARCHAR,
    LOAN_AMOUNT         NUMBER(18,2),
    INTEREST_RATE       NUMBER(6,2),
    EMI_AMOUNT          NUMBER(18,2),
    LOAN_STATUS         VARCHAR,
    DISBURSEMENT_DATE   DATE,
    _FIVETRAN_SYNCED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED   BOOLEAN       DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS RAW_BRANCHES (
    BRANCH_ID           VARCHAR,
    BRANCH_NAME         VARCHAR,
    CITY                VARCHAR,
    STATE               VARCHAR,
    REGION              VARCHAR,
    _FIVETRAN_SYNCED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED   BOOLEAN       DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS RAW_CALENDAR_DIM (
    DATE_KEY            DATE,
    MONTH               NUMBER(2,0),
    QUARTER             NUMBER(1,0),
    YEAR                NUMBER(4,0),
    FISCAL_PERIOD       VARCHAR,
    _FIVETRAN_SYNCED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _FIVETRAN_DELETED   BOOLEAN       DEFAULT FALSE
);
