-- 0012_fetch_throttle.sql
-- Cross-run per-domain fetch throttle for WF-02.
--
-- The WF-02 row in docs/workflows.md lists "Per-domain fetch rate limit" as a
-- guard. Inside one run the HTTP node's own batching spaces requests out; this
-- table is what makes the limit hold *between* runs, where nothing in n8n
-- remembers anything. A research pass every 30 minutes, a retry loop, and a
-- company that keeps failing back to 'new' can otherwise hit the same host
-- dozens of times an hour with nothing noticing.
--
-- Postgres rather than Redis: n8n has a Postgres credential and no Redis one,
-- the claim has to be atomic against concurrent runs, and "when did we last
-- touch this domain" is worth keeping after a restart. Redis would lose it.

CREATE TABLE domain_fetch_log (
    domain         citext      PRIMARY KEY,
    first_fetch_at timestamptz NOT NULL DEFAULT now(),
    last_fetch_at  timestamptz NOT NULL DEFAULT now(),
    fetch_count    integer     NOT NULL DEFAULT 1 CHECK (fetch_count > 0),

    CONSTRAINT domain_fetch_log_last_after_first
        CHECK (last_fetch_at >= first_fetch_at)
);

COMMENT ON TABLE domain_fetch_log IS
    'One row per domain ever fetched. Written only by claim_domain_fetch().';

CREATE INDEX domain_fetch_log_last_fetch_idx ON domain_fetch_log (last_fetch_at);

-- Take the fetch slot for one domain, or refuse.
--
-- True means the caller owns the slot and the row has already been stamped, so
-- a second caller in the same cooldown window gets false even if the first one
-- has not fetched anything yet. The claim and the stamp are one statement on
-- purpose: two statements leave a gap where two concurrent runs both see an
-- expired timestamp and both go fetch.
--
-- False is not an error. The company stays where it is and the next scheduled
-- pass picks it up, which is exactly what a rate limit is supposed to do.
CREATE OR REPLACE FUNCTION claim_domain_fetch(
    p_domain   citext,
    p_cooldown interval DEFAULT interval '1 hour'
)
RETURNS boolean
LANGUAGE plpgsql
AS $fn$
DECLARE
    claimed boolean;
BEGIN
    IF p_domain IS NULL OR btrim(p_domain::text) = '' THEN
        RETURN false;
    END IF;

    INSERT INTO domain_fetch_log AS d (domain, first_fetch_at, last_fetch_at, fetch_count)
    VALUES (p_domain, now(), now(), 1)
    ON CONFLICT (domain) DO UPDATE
        SET last_fetch_at = now(),
            fetch_count   = d.fetch_count + 1
        WHERE d.last_fetch_at <= now() - p_cooldown
    RETURNING true INTO claimed;

    -- No row returned means the ON CONFLICT WHERE refused the update: the
    -- domain is still inside its cooldown.
    RETURN COALESCE(claimed, false);
END;
$fn$;

COMMENT ON FUNCTION claim_domain_fetch IS
    'Atomically take the per-domain fetch slot. False = still cooling down.';
