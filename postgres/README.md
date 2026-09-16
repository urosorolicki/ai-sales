# postgres

## Layout

```
postgres/
├── migrations/   applied in filename order, exactly once each
└── seeds/        optional data, applied by hand
```

## Migrations

```bash
make migrate            # apply pending
make migrate-status     # what is applied, what is pending
```

| File | Contents |
|---|---|
| `0001_extensions.sql` | citext, pg_trgm, `schema_migrations`, `set_updated_at()`, `normalize_domain()` |
| `0002_companies.sql` | `companies`, generated `total_score` and `score_band` |
| `0003_people.sql` | `people` |
| `0004_signals.sql` | `signals`, deduplicated per company and type |
| `0005_leads.sql` | `leads` |
| `0006_agent_runs.sql` | `agent_runs`, generated `duration_ms` |
| `0007_suppression.sql` | `suppression_list`, `is_suppressed()` |
| `0008_outreach.sql` | `outreach`, suppression enforcement trigger |
| `0009_conversations.sql` | `conversations`, `messages` |
| `0010_views.sql` | read models for Telegram, reports and health |
| `0011_notifications.sql` | `notifications` outbox, `queue_notification()`, `v_pending_notifications` |
| `0012_fetch_throttle.sql` | `domain_fetch_log`, `claim_domain_fetch()` |
| `0013_enrichment.sql` | `people.source_url` and `discovery_method`, `enrichment` agent name |

### Rules

**Never edit an applied migration.** The runner stores a checksum and refuses to
continue if a file changed after it was applied. Add a new numbered file.

**One concern per file.** Easier to read, easier to revert, and a failure names
the thing that failed.

**Forward only.** There are no down migrations. Rolling back means restoring a
backup, which is the honest option at this scale - a down migration that has
never been tested is not a rollback plan.

## What the database enforces

These are constraints, not conventions, because a workflow bug should produce a
failed transaction rather than a wrong outcome:

| Rule | Mechanism |
|---|---|
| Never contact a suppressed address | `BEFORE INSERT OR UPDATE` trigger on `outreach` |
| Score band always matches its components | Generated columns on `companies` |
| No duplicate signal per company and type | Unique index on `(company_id, signal_type, md5(signal))` |
| No duplicate follow-up | Unique index on `(lead_id, sequence_step)` |
| No duplicate person by email | Partial unique index on `people(email)` |
| One conversation per external thread | Unique constraint on `(channel, external_thread_id)` |
| `sent` implies `sent_at` | Check constraint |
| `approved` implies an approver | Check constraint |
| `error` implies an error message | Check constraint on `agent_runs` |
| One alert per deduplication identity | Unique index on `notifications(dedup_key)` |
| One fetch per domain per cooldown | `claim_domain_fetch()`, test and stamp in one statement |
| No duplicate person by name per company | Unique index on `(company_id, lower(btrim(full_name)))` |

The last two follow the same reasoning as the rest of this table. Deduplicating
alerts in each workflow would mean five copies of the rule and five chances to
get it wrong; a unique index means a second row for the same alert cannot be
written at all. `docs/notifications.md` explains what happens instead.

## Seeds

```bash
make seed-demo     # postgres/seeds/0002_demo_data.sql, example.org only
```

`0001_suppression_baseline.sql` is a template. Fill in your own domain and
current clients and apply it before any outreach runs.

## Views

| View | Used by |
|---|---|
| `v_approval_queue` | Telegram `/leads`, WF-05 |
| `v_hot_companies` | Telegram `/hot` |
| `v_open_opportunities` | WF-10 |
| `v_daily_stats` | WF-100 |
| `v_agent_health` | WF-101 |

Query these rather than rebuilding the joins in a workflow. A change in shape
then happens in one place.

## Schemas

`public` holds the application. `n8n` holds n8n's own tables. One database, one
backup, no cross-talk.
