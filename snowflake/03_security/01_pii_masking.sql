-- =====================================================================
-- PII MASKING & CLASSIFICATION
-- Layer: applied to MART (and selectively STG) views
-- Strategy: Tag-based Dynamic Data Masking — one policy per data class,
--           bound to columns via object tags. Tags survive renames.
-- =====================================================================

USE ROLE FIN_ADMIN;
USE DATABASE FIN_ANALYTICS;

-- ---------------------------------------------------------------------
-- Step 1: tags for data classification (governance vocabulary)
-- ---------------------------------------------------------------------
CREATE TAG IF NOT EXISTS GOVERNANCE.DATA_CLASS
    ALLOWED_VALUES 'PUBLIC', 'INTERNAL', 'PII_LOW', 'PII_HIGH', 'FINANCIAL_SENSITIVE'
    COMMENT = 'Data sensitivity classification driving masking policies.';

CREATE TAG IF NOT EXISTS GOVERNANCE.PII_FIELD
    ALLOWED_VALUES 'NAME', 'EMAIL', 'PHONE', 'GOVT_ID', 'ADDRESS'
    COMMENT = 'PII sub-classification — drives field-shape-preserving masks.';

-- Note: GOVERNANCE schema is created on demand; if it doesn't exist:
CREATE SCHEMA IF NOT EXISTS FIN_ANALYTICS.GOVERNANCE
    COMMENT = 'Holds tags and masking policies — separate from data schemas.';

-- ---------------------------------------------------------------------
-- Step 2: masking policies
-- ---------------------------------------------------------------------

-- Customer name: BI_READER sees initials only; FIN_ADMIN/DBT_TRANSFORMER sees full
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASK_CUSTOMER_NAME AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'DBT_TRANSFORMER', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() = 'BI_READER' THEN
            COALESCE(
                LEFT(SPLIT_PART(val, ' ', 1), 1) || '. ' ||
                LEFT(SPLIT_PART(val, ' ', -1), 1) || '.',
                '***'
            )
        ELSE '***MASKED***'
    END;

-- Email: BI_READER sees domain only (j***@bank.com); FIN_ADMIN sees full
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASK_EMAIL AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'DBT_TRANSFORMER', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() = 'BI_READER' THEN
            LEFT(SPLIT_PART(val, '@', 1), 1) || '***@' || SPLIT_PART(val, '@', 2)
        ELSE '***MASKED***'
    END;

-- Phone: BI_READER sees last-4 only
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASK_PHONE AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'DBT_TRANSFORMER', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() = 'BI_READER' THEN
            'XXX-XXX-' || RIGHT(REGEXP_REPLACE(val, '[^0-9]', ''), 4)
        ELSE '***MASKED***'
    END;

-- Government ID / account number: only FIN_ADMIN sees raw; others get hash
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASK_GOVT_ID AS
    (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() IN ('DBT_TRANSFORMER', 'BI_READER') THEN
            'HASH_' || LEFT(SHA2(val, 256), 12)
        ELSE '***MASKED***'
    END;

-- Financial amount: numeric mask — round to nearest 1000 for BI_READER on raw txn views
-- (NOT applied to aggregates; only individual-row exposure)
CREATE OR REPLACE MASKING POLICY GOVERNANCE.MASK_FINANCIAL_AMOUNT_ROUNDED AS
    (val NUMBER) RETURNS NUMBER ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'DBT_TRANSFORMER', 'ACCOUNTADMIN') THEN val
        WHEN CURRENT_ROLE() = 'BI_READER' THEN ROUND(val / 1000.0) * 1000
        ELSE NULL
    END;

-- ---------------------------------------------------------------------
-- Step 3: apply tags + masks to DIM_CUSTOMER
-- ---------------------------------------------------------------------
ALTER TABLE FIN_ANALYTICS.FIN_MART.DIM_CUSTOMER
    MODIFY COLUMN customer_name
    SET TAG GOVERNANCE.DATA_CLASS = 'PII_LOW',
            GOVERNANCE.PII_FIELD  = 'NAME';

ALTER TABLE FIN_ANALYTICS.FIN_MART.DIM_CUSTOMER
    MODIFY COLUMN customer_name
    SET MASKING POLICY GOVERNANCE.MASK_CUSTOMER_NAME;

-- Email and phone exist on customer in some BI views — example pattern:
-- ALTER VIEW FIN_ANALYTICS.FIN_MART.VW_CUSTOMER_CONTACT
--     MODIFY COLUMN email_address SET MASKING POLICY GOVERNANCE.MASK_EMAIL;

-- ---------------------------------------------------------------------
-- Step 4: account-level masking on DIM_ACCOUNT
-- ---------------------------------------------------------------------
-- Account number is FINANCIAL_SENSITIVE — same pattern as govt-id
ALTER TABLE FIN_ANALYTICS.FIN_MART.DIM_ACCOUNT
    MODIFY COLUMN account_id
    SET TAG GOVERNANCE.DATA_CLASS = 'FINANCIAL_SENSITIVE';

-- (account_id is a natural key — we do NOT mask it because surrogate keys
--  flow through; downstream joins would break. Pattern shown for reference.)

-- ---------------------------------------------------------------------
-- Step 5: row access policy example — region-scoped BI_READER
-- ---------------------------------------------------------------------
CREATE OR REPLACE ROW ACCESS POLICY GOVERNANCE.RAP_REGION_SCOPE
    AS (region STRING) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() IN ('FIN_ADMIN', 'DBT_TRANSFORMER', 'ACCOUNTADMIN') THEN TRUE
        -- BI_READER sees only their assigned region (mapped via session var or table)
        WHEN CURRENT_ROLE() = 'BI_READER' THEN
            region = COALESCE(
                CURRENT_SESSION_VARIABLE('user_region'),
                'NORTH'  -- default
            )
        ELSE FALSE
    END;

-- ALTER TABLE FIN_ANALYTICS.FIN_MART.FCT_BRANCH_PERFORMANCE
--     ADD ROW ACCESS POLICY GOVERNANCE.RAP_REGION_SCOPE ON (region);

-- ---------------------------------------------------------------------
-- Step 6: governance discoverability — find all PII columns
-- ---------------------------------------------------------------------
-- One-liner audit query (run as ACCOUNTADMIN):
--
--   SELECT object_database, object_schema, object_name, column_name,
--          tag_name, tag_value
--   FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
--   WHERE tag_name IN ('DATA_CLASS', 'PII_FIELD')
--   ORDER BY 1, 2, 3, 4;
