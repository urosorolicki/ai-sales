# infra

Everything needed to run the stack, other than the compose file itself.

```
infra/
├── docker/
│   ├── postgres/initdb/   runs once on a fresh data directory
│   └── redis/redis.conf   Redis configuration, no credentials
└── scripts/
    ├── bootstrap.sh       first-run setup, generates secrets
    ├── migrate.sh         applies migrations, tracked and checksummed
    └── secrets-scan.sh    fails if a credential is about to be committed
```

## infra/docker/postgres/initdb

Runs **only** when PostgreSQL initialises an empty data directory. It creates
the `n8n` schema, which n8n needs to exist before it starts and will not create
itself.

If the volume already exists, these scripts do not run. On an existing database
missing the schema, create it by hand:

```sql
CREATE SCHEMA IF NOT EXISTS n8n;
```

Application tables are **not** created here. They come from
`postgres/migrations/` through `make migrate`, so that schema changes after the
first boot go through the same path as the first one.

## infra/docker/redis/redis.conf

No password in the file. `requirepass` is passed on the command line from
`${REDIS_PASSWORD}`, so no credential exists in a tracked file.

`FLUSHALL`, `FLUSHDB` and `CONFIG` are renamed to nothing. None of them have a
legitimate use in this workload, and two of them are what a compromised Redis
gets used for.

## infra/scripts/bootstrap.sh

Creates `.env` and `Caddyfile` from the templates and generates the secrets that
must be random. Never overwrites an existing `.env`. Run by `make init`.

## infra/scripts/migrate.sh

Applies `postgres/migrations/*.sql` in filename order, once each, recording a
SHA-256 in `schema_migrations`.

- Each migration runs in a single transaction. It applies completely or not at
  all.
- An already-applied migration whose file has changed is reported as **DRIFT**
  and the run aborts. Never edit an applied migration; add a new one.
- `--status` lists applied and pending. `--check` exits non-zero if anything is
  pending, which is what a deploy check should call.

Runs psql inside the container, so no local PostgreSQL client is needed.

## infra/scripts/secrets-scan.sh

Checks tracked files for credential-shaped strings: provider API key prefixes,
AWS access key ids, Telegram bot tokens, private key headers, and non-empty
assignments to any of the secret variables outside `.env`.

It is a backstop, not a guarantee. `.gitignore` and not pasting secrets into
files are the actual controls. Run it before every commit:

```bash
make secrets-scan
```
