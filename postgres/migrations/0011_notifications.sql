-- 0011_notifications.sql
-- The notification outbox.
--
-- docs/telegram.md says Telegram must "never be the only record": everything a
-- notification reports is a database state change first. This table is that
-- record. Workflows queue rows here; a delivery workflow drains them. Telegram
-- being unconfigured, rate limited or down changes when a message arrives, not
-- whether the event happened.
--
-- It is also where deduplication lives. docs/workflows.md requires it on WF-99
-- ("one broken schedule does not send 96 messages a day") and docs/telegram.md
-- explains why it matters more than it sounds like it does: an unmuted channel
-- is worth more than a complete one. The rule is enforced here rather than in
-- each workflow, for the same reason the suppression list is enforced by a
-- trigger - a workflow bug should produce a refused write, not a wrong outcome.

CREATE TABLE notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    kind text NOT NULL CHECK (kind IN (
        'agent_failure',           -- WF-99
        'agent_health',            -- WF-101
        'company_hot',             -- WF-04
        'draft_ready',             -- WF-05
        'positive_reply',          -- WF-08, not built
        'conversation_escalated',  -- WF-09, not built
        'daily_report',            -- WF-100
        'system'
    )),

    -- docs/telegram.md's notification table, in three buckets.
    priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('immediate', 'normal', 'batched')),

    -- The deduplication identity. Two events with the same key are the same
    -- alert, however far apart they are. Callers build it; the convention is
    -- "<kind>:<stable discriminator>", e.g. 'agent_failure:wf02CompanyResearch:Fetch Page'.
    dedup_key text NOT NULL CHECK (length(btrim(dedup_key)) > 0),

    title text NOT NULL CHECK (length(btrim(title)) > 0),
    body  text NOT NULL CHECK (length(btrim(body))  > 0),

    -- Structured detail for a richer renderer later. The body is what gets sent.
    payload jsonb NOT NULL DEFAULT '{}'::jsonb
                  CHECK (jsonb_typeof(payload) = 'object'),

    company_id uuid REFERENCES companies (id) ON DELETE SET NULL,
    lead_id    uuid REFERENCES leads     (id) ON DELETE SET NULL,

    status text NOT NULL DEFAULT 'pending' CHECK (status IN (
        'pending',     -- waiting for delivery
        'sending',     -- claimed by a delivery run
        'sent',
        'failed',      -- delivery attempted and refused; retried by the next pass
        'suppressed'   -- muted by hand; never re-opens on its own
    )),

    -- How many times this alert has fired in the current episode. docs/telegram.md
    -- wants "what failed, how many times, when it started" in one message.
    occurrences integer NOT NULL DEFAULT 1 CHECK (occurrences > 0),
    attempts    integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    error       text,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    sent_at       timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT notifications_sent_needs_timestamp
        CHECK (status <> 'sent' OR sent_at IS NOT NULL),
    CONSTRAINT notifications_failed_requires_message
        CHECK (status <> 'failed' OR error IS NOT NULL),
    CONSTRAINT notifications_last_seen_after_first
        CHECK (last_seen_at >= first_seen_at)
);

CREATE TRIGGER notifications_set_updated_at
    BEFORE UPDATE ON notifications
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- One row per alert identity. This unique index IS the deduplication: there is
-- no way to write a second row for the same key, in any workflow, by accident.
CREATE UNIQUE INDEX notifications_dedup_key ON notifications (dedup_key);

CREATE INDEX notifications_kind_idx       ON notifications (kind, first_seen_at DESC);
CREATE INDEX notifications_company_id_idx ON notifications (company_id);

-- The delivery queue.
CREATE INDEX notifications_outbox_idx ON notifications (priority, first_seen_at)
    WHERE status IN ('pending', 'failed');

-- Queue one notification, or fold it into the alert it repeats.
--
-- Returns exactly one row so a caller can always read what happened:
--   deduplicated = false  a message should be delivered for this
--   deduplicated = true   the same alert is already open or was just sent
--
-- The four cases, in the order they are decided:
--
--   pending/sending/failed  still undelivered. Count it and refresh the text so
--                           the message that does go out describes the latest
--                           instance, not the first one.
--   sent, inside cooloff    count it and stay quiet. This is the case that stops
--                           96 messages a day.
--   sent, cooloff expired   a new episode. Reset the counter and the start time,
--                           because "how many times" means "since this alert
--                           started", not "since the table was created".
--   suppressed              muted by a human. Count it, never re-open. Only a
--                           manual status change brings it back.
CREATE OR REPLACE FUNCTION queue_notification(
    p_kind       text,
    p_dedup_key  text,
    p_title      text,
    p_body       text,
    p_priority   text     DEFAULT 'normal',
    p_payload    jsonb    DEFAULT '{}'::jsonb,
    p_company_id uuid     DEFAULT NULL,
    p_lead_id    uuid     DEFAULT NULL,
    p_cooloff    interval DEFAULT interval '1 hour'
)
RETURNS TABLE (
    notification_id uuid,
    status          text,
    occurrences     integer,
    deduplicated    boolean
)
LANGUAGE sql
AS $fn$
    INSERT INTO notifications AS n (
        kind, dedup_key, title, body, priority, payload, company_id, lead_id
    )
    VALUES (
        p_kind, p_dedup_key, p_title, p_body,
        COALESCE(p_priority, 'normal'),
        COALESCE(p_payload, '{}'::jsonb),
        p_company_id, p_lead_id
    )
    ON CONFLICT (dedup_key) DO UPDATE
    SET last_seen_at = now(),
        occurrences  = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN 1
            ELSE n.occurrences + 1
        END,
        first_seen_at = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN now()
            ELSE n.first_seen_at
        END,
        status = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN 'pending'
            ELSE n.status
        END,
        sent_at = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN NULL
            ELSE n.sent_at
        END,
        attempts = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN 0
            ELSE n.attempts
        END,
        error = CASE
            WHEN n.status = 'sent' AND n.sent_at <= now() - p_cooloff THEN NULL
            ELSE n.error
        END,
        -- A suppressed alert keeps its old text: nothing will read it, and
        -- rewriting it would hide what was muted.
        title   = CASE WHEN n.status = 'suppressed' THEN n.title   ELSE EXCLUDED.title   END,
        body    = CASE WHEN n.status = 'suppressed' THEN n.body    ELSE EXCLUDED.body    END,
        payload = CASE WHEN n.status = 'suppressed' THEN n.payload ELSE EXCLUDED.payload END
    RETURNING n.id,
              n.status,
              n.occurrences,
              -- A fresh insert and a re-opened episode both have occurrences = 1
              -- and are both worth delivering. Anything else is a repeat.
              (n.occurrences > 1) AS deduplicated;
$fn$;

COMMENT ON FUNCTION queue_notification IS
    'Queue a notification, deduplicated on dedup_key. See 0011_notifications.sql.';

-- What the delivery workflow reads. Immediate before normal before batched,
-- oldest first inside each bucket.
CREATE OR REPLACE VIEW v_pending_notifications AS
SELECT
    n.id,
    n.kind,
    n.priority,
    n.dedup_key,
    n.title,
    n.body,
    n.payload,
    n.occurrences,
    n.attempts,
    n.first_seen_at,
    n.last_seen_at,
    c.name   AS company_name,
    c.domain AS company_domain
FROM notifications n
LEFT JOIN companies c ON c.id = n.company_id
WHERE n.status IN ('pending', 'failed')
ORDER BY
    CASE n.priority WHEN 'immediate' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END,
    n.first_seen_at;
