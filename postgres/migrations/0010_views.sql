-- 0010_views.sql
-- Read models for the Telegram control plane, the daily report and health
-- checks. Workflows should query these instead of hand-rolling joins.

-- Everything a human needs to approve or reject one draft.
CREATE OR REPLACE VIEW v_approval_queue AS
SELECT
    o.id            AS outreach_id,
    o.sequence_step,
    o.channel,
    o.subject,
    o.body,
    o.created_at,
    l.id            AS lead_id,
    l.score,
    l.reason,
    l.recommended_offer,
    p.full_name,
    p.title,
    p.email,
    c.id            AS company_id,
    c.name          AS company_name,
    c.domain,
    c.score_band
FROM outreach o
JOIN leads     l ON l.id = o.lead_id
JOIN people    p ON p.id = l.person_id
JOIN companies c ON c.id = l.company_id
WHERE o.status = 'pending_approval'
ORDER BY l.score DESC NULLS LAST, o.created_at;

-- Companies worth acting on, highest first. Backs /hot and /leads.
CREATE OR REPLACE VIEW v_hot_companies AS
SELECT
    c.id,
    c.name,
    c.domain,
    c.total_score,
    c.score_band,
    c.status,
    c.updated_at,
    (SELECT count(*) FROM signals s WHERE s.company_id = c.id) AS signal_count,
    (SELECT count(*) FROM people  p WHERE p.company_id = c.id) AS people_count
FROM companies c
WHERE c.score_band IN ('OUTREACH', 'HIGH_PRIORITY', 'HOT')
  AND c.status NOT IN ('ignored', 'suppressed', 'lost', 'won')
ORDER BY c.total_score DESC, c.updated_at DESC;

-- Threads that stopped being safe for the agent to handle alone.
CREATE OR REPLACE VIEW v_open_opportunities AS
SELECT
    conv.id AS conversation_id,
    conv.status,
    conv.escalation_reason,
    conv.last_message_at,
    l.id    AS lead_id,
    l.score,
    l.recommended_offer,
    p.full_name,
    p.email,
    c.name  AS company_name,
    c.domain
FROM conversations conv
JOIN leads     l ON l.id = conv.lead_id
JOIN people    p ON p.id = l.person_id
JOIN companies c ON c.id = l.company_id
WHERE conv.status IN ('awaiting_human', 'escalated')
ORDER BY conv.last_message_at DESC NULLS LAST;

-- Counters for WF-100 Daily Report.
CREATE OR REPLACE VIEW v_daily_stats AS
SELECT
    (SELECT count(*) FROM companies WHERE created_at >= now() - interval '24 hours')       AS companies_discovered,
    (SELECT count(*) FROM signals   WHERE created_at >= now() - interval '24 hours')       AS signals_captured,
    (SELECT count(*) FROM leads     WHERE created_at >= now() - interval '24 hours')       AS leads_created,
    (SELECT count(*) FROM outreach  WHERE status = 'pending_approval')                     AS awaiting_approval,
    (SELECT count(*) FROM outreach  WHERE sent_at  >= now() - interval '24 hours')         AS messages_sent,
    (SELECT count(*) FROM messages  WHERE direction = 'inbound'
                                      AND created_at >= now() - interval '24 hours')       AS replies_received,
    (SELECT count(*) FROM conversations WHERE status IN ('awaiting_human', 'escalated'))   AS open_opportunities,
    (SELECT count(*) FROM agent_runs WHERE status IN ('error', 'timeout')
                                       AND started_at >= now() - interval '24 hours')      AS agent_failures;

-- Backs WF-101 Agent Health.
CREATE OR REPLACE VIEW v_agent_health AS
SELECT
    agent_name,
    count(*)                                                   AS runs_24h,
    count(*) FILTER (WHERE status = 'success')                  AS succeeded,
    count(*) FILTER (WHERE status IN ('error', 'timeout'))      AS failed,
    count(*) FILTER (WHERE status = 'running')                  AS in_flight,
    round(avg(duration_ms) FILTER (WHERE status = 'success'))   AS avg_duration_ms,
    max(started_at)                                             AS last_run_at
FROM agent_runs
WHERE started_at >= now() - interval '24 hours'
GROUP BY agent_name
ORDER BY agent_name;
