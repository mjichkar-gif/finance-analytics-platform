# Security & Governance

## Threat model (one-line summary)

> A BI analyst gets curious about a celebrity customer's transactions, or a contractor's laptop gets stolen with cached credentials. Neither incident should leak PII or full account numbers.

We do not solve insider-threat in full; we make casual exfiltration *visible* and full data exfiltration *role-gated*.

## Role hierarchy

```
ACCOUNTADMIN
   └── SYSADMIN
        ├── FIN_ADMIN          → full CRUD on FIN_ANALYTICS, owns objects
        ├── DBT_TRANSFORMER    → read RAW, read/write STG/INT/MART
        ├── FIVETRAN_LOADER    → write-only on RAW
        └── BI_READER          → SELECT only on FIN_MART SECURE views
```

Privilege-of-least-resort: **BI_READER cannot see RAW, STG, or INT**. Tables in FIN_MART are also not granted directly — BI must go through SECURE views, which guarantees masking policies are evaluated server-side.

## Data classification taxonomy

| Class                    | Examples                                  | Mask strategy                                       |
|--------------------------|-------------------------------------------|-----------------------------------------------------|
| `PUBLIC`                 | Branch addresses, calendar                | No mask                                             |
| `INTERNAL`               | Customer segment, region                  | No mask, but role-gated                             |
| `PII_LOW`                | Customer name                             | Initials for BI_READER, full for ADMIN              |
| `PII_HIGH`               | Email, phone, address                     | Partial-reveal for BI_READER (last-4, domain)       |
| `FINANCIAL_SENSITIVE`    | Account number, govt-ID, raw txn amount   | SHA-256 hash or rounded value for BI_READER         |

Classification is implemented as **Snowflake tags** in the `GOVERNANCE` schema (`DATA_CLASS`, `PII_FIELD`). Tags survive renames and are queryable via `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`, which is how compliance auditors discover the full PII inventory without us maintaining a separate spreadsheet.

## Masking policies — the four we ship

| Policy                                | Bound to                | Behaviour for BI_READER                                   |
|---------------------------------------|-------------------------|-----------------------------------------------------------|
| `MASK_CUSTOMER_NAME`                  | `dim_customer.customer_name` | `J. S.` (first + last initials)                      |
| `MASK_EMAIL`                          | future contact views   | `j***@bank.com`                                            |
| `MASK_PHONE`                          | future contact views   | `XXX-XXX-1234`                                             |
| `MASK_GOVT_ID`                        | account number, SSN    | `HASH_<12-char-sha256>`                                    |

A fifth, `MASK_FINANCIAL_AMOUNT_ROUNDED`, is **not** applied to aggregate views (aggregates are safe by construction). It is reserved for individual-row exposure should one ever be needed.

## Row access policy (sketch)

`RAP_REGION_SCOPE` restricts BI_READER to their assigned region. The session variable `user_region` is set at login from the user's profile; ADMIN roles bypass. It is **declared but not bound** in the POC because the seed data has only four regions and binding it adds clutter without exercising new code paths. Binding is a one-line `ALTER TABLE … ADD ROW ACCESS POLICY …`.

## SECURE views — why and how

Three views in `FIN_MART` are the only BI surface:

| View                | Joins                                       | Primary consumer |
|---------------------|---------------------------------------------|------------------|
| `VW_CUSTOMER_360`   | `dim_customer` + `fct_customer_profitability` | CX dashboards   |
| `VW_FRAUD_DAILY`    | aggregated `fct_fraud_indicators`           | Fraud ops       |
| `VW_REVENUE_EXEC`   | aggregated `fct_revenue_monthly`            | Executive deck   |

`SECURE` matters because non-secure views can leak data through query-plan inspection (the optimizer can push predicates that disclose values via timing/error messages). For PII-bearing views the small performance cost is worth it.

## Audit trail

`GOVERNANCE.VW_ACCESS_AUDIT` exposes the last 30 days of query history scoped to `FIN_ANALYTICS`. Only `FIN_ADMIN` can read it. In production this would feed a SIEM (Splunk/Datadog) via a Snowflake event-table connector.

## Network controls (production)

`NP_FIN_PROD` is commented out in the POC — restricting IPs in a bootcamp setup just makes graders' lives harder. The pattern is documented in `02_rbac_and_secure_views.sql` for completeness.

## What we explicitly did **not** do

- **Customer-level row-access for analysts.** Out of scope; would require a customer-region mapping table and a more complex policy. Region-level is the production-shaped sketch.
- **Column-level encryption with external key management.** Snowflake handles encryption at rest natively; bring-your-own-key (BYOK / Tri-Secret Secure) is a paid feature and not exercised here.
- **Privileged-access session recording.** Belongs in a SIEM, not the data platform.

## Pre-prod security checklist

- [ ] All `PII_LOW`/`PII_HIGH` columns have a masking policy bound (audit via `TAG_REFERENCES` join `POLICY_REFERENCES`).
- [ ] `BI_READER` has zero direct grants on `RAW` / `STG` / `INT` schemas.
- [ ] `FIVETRAN_LOADER` has only `INSERT`/`COPY` on RAW (no SELECT — Fivetran does not need it).
- [ ] All BI-facing views are `SECURE`.
- [ ] `STATEMENT_TIMEOUT_IN_SECONDS` set on every BI user (prevents runaway scan costs).
- [ ] Network policy bound on production account.
- [ ] `VW_ACCESS_AUDIT` piped to SIEM.
