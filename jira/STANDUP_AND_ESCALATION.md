# Daily Slack Standup Template

Posted to `#fin-de-bootcamp` by 10:00 IST every working day.

---

```
📅 Daily Update — [DATE]
👤 [YOUR NAME]
🎯 Sprint: [N] — [THEME]
📊 Sprint progress: [X]/[Y] points done

✅ Yesterday
   • <FIN-XXX.Y>  one-line outcome (not "worked on")
   • <FIN-XXX.Y>  …

🎯 Today
   • <FIN-XXX.Y>  concrete next deliverable
   • <FIN-XXX.Y>  …

🚧 Blockers
   • [None] OR
   • <FIN-XXX>  description, who-can-unblock, impact-if-not-resolved-by-EOD

🔗 PR/Demo links: <list any open PRs>
```

---

## Examples

### Good update

```
📅 Daily Update — 2026-05-22
👤 Aditi
🎯 Sprint: 3 — Risk/fraud + Streams/Tasks
📊 Sprint progress: 6/10 points done

✅ Yesterday
   • FIN-106.2  Built fct_fraud_indicators with rapid-fire detection; PR open
   • FIN-107.1  Created STG_TRANSACTIONS_INCR sink table, validated MERGE logic locally

🎯 Today
   • FIN-107.3  Wire root task TSK_MERGE_STG_TRANSACTIONS and resume it
   • FIN-107.4  Build child task TSK_FLAG_SUSPICIOUS_TXN, validate end-to-end

🚧 Blockers
   • None

🔗 PRs: bitbucket.org/.../pull-requests/47
```

### Bad update (don't do this)

```
- Worked on fraud stuff
- Will continue today
- No blockers
```

Why it's bad: no story IDs, no measurable outcome, "worked on" doesn't tell the team what shipped.

---

# Blocker Escalation Template

When a blocker risks slipping the sprint, escalate within 24h. Post in `#fin-de-bootcamp` with `@channel` and DM the team lead.

---

```
🚨 BLOCKER — needs decision/action

Story:       FIN-XXX — <title>
Blocked at:  <task ID and description>
Blocked by:  <person | team | external dependency | ambiguity>
Duration:    <hours/days since blocked>
Sprint risk: <will/may/won't slip — and which stories>

What I've tried:
  1. <attempt 1 + outcome>
  2. <attempt 2 + outcome>

What I need:
  • <specific ask — decision, access, review, info>
  • <by when>

Workaround in flight:
  <if any — what I'm doing while waiting>
```

---

## Example

```
🚨 BLOCKER — needs decision/action

Story:       FIN-102 — Fivetran ingestion
Blocked at:  FIN-102.2 — Fivetran → Snowflake key-pair auth
Blocked by:  Awaiting Snowflake account owner to add public key to Fivetran service user
Duration:    36 hours
Sprint risk: WILL slip — FIN-103 cannot start until RAW has data

What I've tried:
  1. Generated key pair and posted public key to #fin-platform channel — no response
  2. Pinged @account-owner directly — read but no action

What I need:
  • Public key uploaded to Snowflake user FIVETRAN_LOADER
  • By EOD today, otherwise we burn day 4 of sprint 1

Workaround in flight:
  Using sample CSVs loaded via SnowSQL into RAW so FIN-103 staging work
  can proceed against representative data; will swap to Fivetran-loaded
  rows once unblocked.
```

---

# Escalation matrix

| Blocked duration | Action                                    |
|------------------|-------------------------------------------|
| ≤ 4 hours        | Ping in stand-up channel                  |
| 4 – 24 hours     | DM the person directly + stand-up channel |
| ≥ 24 hours       | Post escalation template, DM team lead    |
| ≥ 48 hours       | Add to risk register; sprint plan adjusted in next planning |

The goal of escalation is **never** to assign blame — it is to get the team's collective attention on the smallest set of unblocking actions.
