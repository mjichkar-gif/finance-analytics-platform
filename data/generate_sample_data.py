"""
Sample data generator for Enterprise Financial Performance & Risk Analytics Platform.

Generates six CSVs that simulate operational exports landed in Google Sheets:
    customers, accounts, transactions, loans, branches, calendar_dim.

The generator intentionally seeds the data with:
    * Referential integrity across customer -> account -> transaction -> loan
    * Currency variation (USD / INR / EUR / GBP)
    * Fraud / anomaly patterns (large round-number txns, rapid-fire txns, blocked status)
    * NULLs, whitespace, casing inconsistencies, duplicate PKs for DQ tests

Run:
    python generate_sample_data.py
"""
from __future__ import annotations

import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

random.seed(42)

OUT = Path(__file__).parent / "raw"
OUT.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Reference pools
# ---------------------------------------------------------------------------
REGIONS = ["North America", "EMEA", "APAC", "LATAM"]
SEGMENTS = ["Retail", "SMB", "Corporate", "Private Banking", "HNI"]
RISK_CATS = ["LOW", "MEDIUM", "HIGH"]
ACCT_TYPES = ["SAVINGS", "CHECKING", "CREDIT_CARD", "BROKERAGE", "WEALTH"]
ACCT_STATUS = ["ACTIVE", "DORMANT", "CLOSED", "FROZEN"]
TXN_TYPES = ["DEBIT", "CREDIT", "TRANSFER", "FEE", "INTEREST", "REFUND"]
TXN_STATUS = ["COMPLETED", "FAILED", "PENDING", "REVERSED", "BLOCKED"]
MERCHANT_CATS = [
    "GROCERY", "TRAVEL", "ELECTRONICS", "HEALTHCARE", "ATM_WITHDRAWAL",
    "DINING", "UTILITIES", "ECOMMERCE", "INVESTMENT", "INSURANCE",
]
LOAN_TYPES = ["HOME", "AUTO", "PERSONAL", "BUSINESS", "EDUCATION", "GOLD"]
LOAN_STATUS = ["ACTIVE", "CLOSED", "DEFAULTED", "DELINQUENT", "WRITTEN_OFF"]
CURRENCIES = ["USD", "INR", "EUR", "GBP"]

BRANCHES_SEED = [
    ("BR001", "Wall Street Main",        "New York",     "NY", "North America"),
    ("BR002", "Bay Area Tech",           "San Francisco","CA", "North America"),
    ("BR003", "Loop Branch",             "Chicago",      "IL", "North America"),
    ("BR004", "Canary Wharf",            "London",       "GB", "EMEA"),
    ("BR005", "La Défense",              "Paris",        "FR", "EMEA"),
    ("BR006", "Frankfurt Banking Centre","Frankfurt",    "HE", "EMEA"),
    ("BR007", "BKC Mumbai",              "Mumbai",       "MH", "APAC"),
    ("BR008", "Whitefield Tech Park",    "Bangalore",    "KA", "APAC"),
    ("BR009", "Marina Bay",              "Singapore",    "SG", "APAC"),
    ("BR010", "Shibuya Crossing",        "Tokyo",        "JP", "APAC"),
    ("BR011", "Faria Lima",              "Sao Paulo",    "SP", "LATAM"),
    ("BR012", "Polanco",                 "Mexico City",  "MX", "LATAM"),
]


def write_csv(name: str, header: list[str], rows: list[list]) -> None:
    path = OUT / f"{name}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)
    print(f"  wrote {path.relative_to(OUT.parent)}  ({len(rows)} rows)")


# ---------------------------------------------------------------------------
# 1. branches
# ---------------------------------------------------------------------------
def gen_branches() -> list[list]:
    return [list(b) for b in BRANCHES_SEED]


# ---------------------------------------------------------------------------
# 2. customers
# ---------------------------------------------------------------------------
FIRST_NAMES = ["Aarav","Priya","Liam","Olivia","Noah","Emma","Yuki","Hiroshi",
               "Carlos","Sofia","Aiden","Isabella","Wei","Mei","Pierre","Chloe",
               "Hans","Greta","Raj","Anita","Lucas","Mia","Ethan","Ava"]
LAST_NAMES = ["Sharma","Patel","Smith","Johnson","Tanaka","Suzuki","Garcia",
              "Lopez","Chen","Wang","Dubois","Martin","Mueller","Schmidt",
              "Rao","Iyer","Brown","Davis","Wilson","Taylor"]

def gen_customers(n: int = 80) -> list[list]:
    rows = []
    for i in range(1, n + 1):
        cust_id = f"C{i:05d}"
        name = f"{random.choice(FIRST_NAMES)} {random.choice(LAST_NAMES)}"
        segment = random.choices(SEGMENTS, weights=[40,25,15,10,10])[0]
        risk = random.choices(RISK_CATS, weights=[55,30,15])[0]
        region = random.choice(REGIONS)
        onboarding = date(2019,1,1) + timedelta(days=random.randint(0, 2400))
        # Seed a few DQ issues
        if i == 17: name = "  priya patel  "                # whitespace + casing
        if i == 23: segment = None                          # null
        if i == 41: risk = "high"                           # mixed case enum
        rows.append([cust_id, name, segment, risk, region, onboarding.isoformat()])
    # Duplicate primary key for DQ test
    rows.append(["C00005", "Duplicate Record", "Retail", "LOW", "EMEA", "2022-06-15"])
    return rows


# ---------------------------------------------------------------------------
# 3. accounts
# ---------------------------------------------------------------------------
def gen_accounts(customers: list[list], n: int = 100) -> list[list]:
    rows = []
    cust_ids = [c[0] for c in customers if c[0] != "C00005" or rows == []]
    # Ensure every active customer gets at least one account
    for idx, cid in enumerate(set(cust_ids), start=1):
        acct = f"A{idx:06d}"
        rows.append([
            acct, cid,
            random.choice(ACCT_TYPES),
            random.choice(BRANCHES_SEED)[0],
            random.choices(ACCT_STATUS, weights=[80,10,7,3])[0],
            (date(2019,1,1) + timedelta(days=random.randint(0,2400))).isoformat(),
        ])
    # Add a few extra accounts (multi-account customers)
    extra = max(0, n - len(rows))
    for _ in range(extra):
        idx = len(rows) + 1
        rows.append([
            f"A{idx:06d}",
            random.choice(cust_ids),
            random.choice(ACCT_TYPES),
            random.choice(BRANCHES_SEED)[0],
            random.choice(ACCT_STATUS),
            (date(2020,1,1) + timedelta(days=random.randint(0,1800))).isoformat(),
        ])
    # Inject one orphan account (FK to non-existent customer) for relationship test
    rows.append([f"A{len(rows)+1:06d}", "C99999", "SAVINGS", "BR001", "ACTIVE", "2024-02-01"])
    return rows


# ---------------------------------------------------------------------------
# 4. transactions
# ---------------------------------------------------------------------------
def gen_transactions(accounts: list[list], n: int = 800) -> list[list]:
    rows = []
    acct_ids = [a[0] for a in accounts]
    base = datetime(2024, 1, 1)
    for i in range(1, n + 1):
        txn_id = f"T{i:08d}"
        acct  = random.choice(acct_ids)
        ttype = random.choices(TXN_TYPES, weights=[40,30,15,7,5,3])[0]
        amt   = round(random.uniform(5, 8000), 2)
        # Fraud / anomaly seeding: 2% of txns are round-number high-value
        if random.random() < 0.02:
            amt = float(random.choice([10000, 25000, 50000, 99999]))
        ccy   = random.choices(CURRENCIES, weights=[55,25,12,8])[0]
        mcat  = random.choice(MERCHANT_CATS)
        ts    = base + timedelta(
            days=random.randint(0, 510),
            seconds=random.randint(0, 86399),
        )
        status = random.choices(TXN_STATUS, weights=[85,8,3,2,2])[0]
        rows.append([txn_id, acct, ttype, amt, ccy, mcat, ts.isoformat(sep=" "), status])
    # NULL amount edge case (DQ test target)
    rows.append([f"T{n+1:08d}", random.choice(acct_ids), "DEBIT", None, "USD",
                 "GROCERY", "2025-03-15 10:00:00", "COMPLETED"])
    # Duplicate transaction id (deduplication test target)
    rows.append(rows[0].copy())
    return rows


# ---------------------------------------------------------------------------
# 5. loans
# ---------------------------------------------------------------------------
def gen_loans(customers: list[list], n: int = 70) -> list[list]:
    rows = []
    cust_ids = [c[0] for c in customers]
    for i in range(1, n + 1):
        lid = f"L{i:06d}"
        ltype = random.choice(LOAN_TYPES)
        principal = round(random.uniform(5_000, 750_000), 2)
        rate = round(random.uniform(4.5, 18.0), 2)
        tenure_m = random.choice([12, 24, 36, 60, 120, 240])
        # Simple EMI calc (compounded monthly)
        r = rate / 12 / 100
        emi = round(principal * r * (1+r)**tenure_m / ((1+r)**tenure_m - 1), 2)
        status = random.choices(LOAN_STATUS, weights=[60,20,8,8,4])[0]
        disb = date(2021,1,1) + timedelta(days=random.randint(0, 1500))
        rows.append([lid, random.choice(cust_ids), ltype, principal, rate, emi, status, disb.isoformat()])
    return rows


# ---------------------------------------------------------------------------
# 6. calendar_dim
# ---------------------------------------------------------------------------
def gen_calendar(start=date(2023,1,1), end=date(2026,12,31)) -> list[list]:
    rows, d = [], start
    while d <= end:
        # Company fiscal year starts April (Apr–Jun = Q1)
        fy_month = ((d.month - 4) % 12) + 1
        fy_quarter = (fy_month - 1) // 3 + 1
        fy_year = d.year if d.month >= 4 else d.year - 1
        rows.append([
            d.isoformat(),
            d.month,
            (d.month - 1) // 3 + 1,    # calendar quarter
            d.year,
            f"FY{fy_year}-Q{fy_quarter}",
        ])
        d += timedelta(days=1)
    return rows


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def main() -> None:
    print("Generating raw CSV datasets...")
    branches  = gen_branches()
    customers = gen_customers(80)
    accounts  = gen_accounts(customers, 100)
    transactions = gen_transactions(accounts, 800)
    loans     = gen_loans(customers, 70)
    calendar  = gen_calendar()

    write_csv("branches",     ["branch_id","branch_name","city","state","region"], branches)
    write_csv("customers",    ["customer_id","customer_name","customer_segment","risk_category","region","onboarding_date"], customers)
    write_csv("accounts",     ["account_id","customer_id","account_type","branch_id","account_status","open_date"], accounts)
    write_csv("transactions", ["transaction_id","account_id","transaction_type","amount","currency","merchant_category","transaction_timestamp","transaction_status"], transactions)
    write_csv("loans",        ["loan_id","customer_id","loan_type","loan_amount","interest_rate","emi_amount","loan_status","disbursement_date"], loans)
    write_csv("calendar_dim", ["date_key","month","quarter","year","fiscal_period"], calendar)
    print("Done.")


if __name__ == "__main__":
    main()
