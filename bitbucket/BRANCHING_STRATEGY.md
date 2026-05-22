# Bitbucket — Branching, Commits, PRs

## Repository layout

```
fin-analytics-platform/
├── architecture/        ← design docs
├── bitbucket/           ← THIS file + PR template
├── dashboards/          ← BI specs
├── data/                ← sample CSVs + generator
├── dbt/                 ← all dbt code (PRIMARY workspace)
├── docs/                ← runbooks (Fivetran, DQ, Security)
├── jira/                ← Jira artifacts
├── presentation/        ← walkthrough deck
└── snowflake/           ← raw DDL, stream/task, security, DQ SQL
```

All code is in **one repo** (mono-style). Reasons:
- dbt and Snowflake DDL evolve together — separating them creates lock-step PRs across two repos and the merge order becomes a debugging nightmare.
- Reviewers (and Jira) see one timeline of changes per story.
- CI can fan out to dbt + SQL-lint in a single pipeline.

---

## Branching strategy — trunk-based with short-lived feature branches

```
main          ────●────●────●────●────●────   (always deployable; protected)
                  │    │    │    │    │
feature/...     ──┘    │    │    │    │
hotfix/...             │    │    │    │
release/...   ─────────┴────┴────┴────┘
```

| Branch type        | Naming                                 | Lifetime          | Merges into |
|--------------------|----------------------------------------|-------------------|-------------|
| `main`             | —                                      | forever           | —           |
| `feature/<JIRA>-…` | `feature/FIN-105-fct-revenue-monthly`  | ≤ 3 days          | `main`      |
| `bugfix/<JIRA>-…`  | `bugfix/FIN-208-dedup-edge-case`       | ≤ 1 day           | `main`      |
| `hotfix/<JIRA>-…`  | `hotfix/FIN-301-mask-policy-typo`      | ≤ hours           | `main`      |
| `release/<sprint>` | `release/sprint-3`                     | until tagged      | `main` (tag)|

**No long-lived `develop` branch.** Trunk-based, with environment-promotion gated by tags (`v1.0.0-sprint3`) rather than branches.

### Why trunk-based for this project

- One engineer, sometimes pairing. Long-lived branches create merge debt that doesn't pay off.
- dbt artifacts (manifest, run_results) reconcile cleanly when changes land linearly.
- Fast feedback: PR opens → CI runs → merge same day.

---

## Commit message convention — Conventional Commits

```
<type>(<scope>): <short summary>           ← ≤ 72 chars, imperative

<body — optional, wrap at 80 chars>

<footer — Jira ID and any breaking-change notes>
```

### Types

| Type      | Used for                                         |
|-----------|--------------------------------------------------|
| `feat`    | New model, mart, task, masking policy            |
| `fix`     | Bug in existing logic                            |
| `refactor`| Restructure without behaviour change             |
| `test`    | Add/modify dbt tests or DQ checks                |
| `docs`    | Markdown changes only                            |
| `chore`   | Tooling, dependencies, CI                        |
| `perf`    | Performance tuning (clustering, materialisation) |

### Scope examples

`stg`, `mart`, `dim`, `fct`, `dq`, `security`, `snowflake`, `fivetran`, `ci`.

### Examples

```
feat(mart): add fct_fraud_indicators with rapid-fire detection

Implements 60-min rolling-window count via window function;
flags reasons collected into an array column so BI can unpivot.

Refs: FIN-106
```

```
fix(stg): dedup transactions on natural key, not surrogate

Previous QUALIFY was partitioning on the MD5 hash, which
defeats the purpose when the same TRANSACTION_ID hashes
identically. Switched to TRANSACTION_ID.

Refs: FIN-103
```

```
docs(security): document tag-based masking policy attachment

Refs: FIN-109
```

### What we don't accept

- `update stuff`
- `wip`
- `fix bug`
- Past-tense (`added foo`) — use imperative (`add foo`)

---

## Pull request rules

### Branch protections on `main`

- ≥ 1 approving review required.
- All CI checks green (dbt build on dev, SQL-fluff, yamllint, dbt test).
- Linear history enforced — squash-merge only.
- No direct pushes.

### PR description must include

```markdown
## What
One paragraph: what this changes and why.

## Story
FIN-XXX

## Testing
- [ ] `dbt build --select <models>` on dev
- [ ] `dbt test --select <models>` passed
- [ ] Manual: <describe any data-quality spot-check>

## Risk
- Breaking change? Y/N — if Y, migration steps below.
- Affects production data? Y/N.
- Reviewers should pay extra attention to: <…>

## Screenshots / sample output
<paste row counts, lineage diff, etc.>
```

A template is committed at `.bitbucket/pull_request_template.md` so it pre-fills every PR.

### Review SLA

| Priority | Response time |
|----------|---------------|
| Hotfix   | 1 hour        |
| Normal   | 4 working hours |
| Refactor | 1 working day |

If the PR is open > 24 h with no review, the author pings in `#fin-de-bootcamp`. Stale PRs (> 3 days) are closed and re-opened with a rebase.

---

## CI pipeline (`bitbucket-pipelines.yml` sketch)

```yaml
pipelines:
  pull-requests:
    '**':
      - step:
          name: Lint
          image: python:3.11
          script:
            - pip install sqlfluff yamllint
            - sqlfluff lint dbt/finance_analytics/models --dialect snowflake
            - yamllint dbt/finance_analytics
      - step:
          name: dbt build (dev)
          image: ghcr.io/dbt-labs/dbt-snowflake:1.8.latest
          script:
            - cd dbt/finance_analytics
            - dbt deps
            - dbt build --target ci --fail-fast
          services:
            - snowflake-dev
  branches:
    main:
      - step:
          name: dbt build (prod) + docs publish
          script:
            - dbt build --target prod
            - dbt docs generate --target prod
            - aws s3 sync target/ s3://fin-dbt-docs/ --delete
```

The `ci` target runs against a temporary schema (`CI_<git_sha>`) and tears down on success — cost stays bounded.

---

## Environment promotion

| Env  | Snowflake DB     | Trigger                                   | Audience      |
|------|------------------|-------------------------------------------|---------------|
| dev  | `FIN_ANALYTICS_DEV`  | Each push to feature branch           | Developers    |
| ci   | `FIN_ANALYTICS_CI`   | Each PR (ephemeral schema)            | CI bot        |
| prod | `FIN_ANALYTICS`      | Tag push (`v*.*.*`) on `main`         | BI consumers  |

`profiles.example.yml` documents the three targets; production credentials are key-pair, dev uses password auth, CI uses an OIDC-issued service-account token (out of scope for the bootcamp).

---

## Tagging & releases

After every sprint demo, tag `main`:

```
git tag -a v1.0.0-sprint3 -m "Sprint 3: risk/fraud marts + Streams/Tasks"
git push origin v1.0.0-sprint3
```

Release notes auto-generated from Conventional Commits via `git log v0.9.0..HEAD --pretty=format:"%s"`.
