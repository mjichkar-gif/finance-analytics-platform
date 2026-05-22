# Bootcamp Learnings — One Pager

## What I built
An end-to-end finance analytics platform: Google Sheets → Fivetran → Snowflake → dbt → governed marts with Streams/Tasks for 5-minute fraud detection. 20 deliverables across architecture, ingestion, transformation, modelling, DQ, security, and project artefacts.

## What clicked

**dbt is a discipline, not a tool.** The value isn't `dbt run` — it's the contract that every model has tests, lineage, and docs. Once I wrote the first `_models.yml` for staging, every subsequent layer wrote itself faster because the pattern was already proven.

**Surrogate keys earn their keep.** MD5 hashes via `dbt_utils.generate_surrogate_key` survived three rebuilds and a natural-key rename. Sequences would have forced a full-refresh of every downstream fact.

**Streams + Tasks are operational, dbt is analytical.** Trying to do fraud-flagging in dbt would have required a 5-min schedule — wasteful and fragile. Picking the right engine per SLA was the biggest design call.

**Tag-based masking is the right governance abstraction.** One policy per data class, bound to columns via tags, survives renames and is queryable from `TAG_REFERENCES`. Direct column-bound masks would have meant chasing every rename.

## What I struggled with

**Late-arriving data.** First version of `fct_transactions` lost rows that landed after the incremental cutoff. Fixed with a 24-hour overlap (parameterised in `dbt_project.yml`). Lesson: incrementals must always assume the world is slower than you think.

**SCD-2 cutoff semantics.** Snapshot logic flips `is_current = FALSE` on the *previous* row, not the incoming one — easy to get backwards and hard to detect without explicit test rows. I now write a "before snap / after snap" comparison query for every SCD-2 dimension.

**The "two transformation engines" boundary.** Initially built fraud detection in dbt; latency was unacceptable. Migrating it to Streams/Tasks meant rewriting the fraud rules in vanilla Snowflake SQL — they were no longer composable with the dbt macro library. Lesson: pick the engine *before* writing the logic, and accept that some duplication of rule definitions is the cost of having two cadences.

## What I'd do differently

1. **Write the DQ framework first, models second.** Several models I built then had tests bolted on; if DQ had been the scaffold from day one, the models would have been shaped by their tests.
2. **Seed exchange rates from an API on day one.** The CSV seed was fine for the POC but every demo brought the "what about prod" question. Doing the API connector early would have made the platform feel more honest.
3. **Build the smallest mart first.** I built `fct_transactions` (the largest) before `dim_branch` (the smallest). Reversing the order would have given me a complete vertical slice — source → ingest → STG → INT → MART → test — in half a day, against which everything else could be measured.

## Numbers

- **49 files** in the repo across architecture, data, dbt, snowflake, docs, jira, bitbucket, dashboards, presentation.
- **20 dbt models** (6 staging, 2 intermediate, 4 dims, 5 finance facts, 3 risk facts).
- **5 DQ categories** × multiple checks → ~12 distinct validation procedures.
- **4 masking policies** + 2 governance tags + 3 SECURE views.
- **2 SCD-2 snapshots**.
- **4 sprints** in the Jira plan, **47 story points** total.

## One sentence

Building this platform taught me that the hard part of data engineering is not transformations — it's deciding which compromises to make explicit, documenting them in places reviewers will actually find, and putting tests where future-me will be glad they exist.
