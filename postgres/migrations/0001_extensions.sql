-- 0001_extensions.sql
-- Extensions, shared helper functions and the migration ledger.

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     text        PRIMARY KEY,
    checksum    text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE schema_migrations IS
    'Applied migration ledger. Written by infra/scripts/migrate.sh.';

-- Keeps updated_at honest without relying on every writer remembering it.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$fn$;

-- Normalises whatever a provider hands us into a bare registrable domain.
CREATE OR REPLACE FUNCTION normalize_domain(input text)
RETURNS citext
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(lower(btrim(coalesce(input, ''))), '^https?://', ''),
            '^www[.]|/.*$', '', 'g'
        ),
        ''
    )::citext;
$fn$;
