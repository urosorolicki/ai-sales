-- 0006_agent_runs.sql
-- One row per agent invocation. This is the audit trail and the debugging
-- surface: every LLM call the system makes must leave a row here.

CREATE TABLE agent_runs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name  text NOT NULL CHECK (agent_name IN (
        'research', 'scoring', 'outreach', 'classifier', 'conversation', 'radar'
    )),
    company_id  uuid REFERENCES companies (id) ON DELETE SET NULL,

    input  jsonb NOT NULL DEFAULT '{}'::jsonb,
    output jsonb,

    status text NOT NULL DEFAULT 'running' CHECK (status IN (
        'running', 'success', 'error', 'skipped', 'timeout'
    )),
    error text,

    model         text,
    prompt_tokens integer CHECK (prompt_tokens     IS NULL OR prompt_tokens     >= 0),
    output_tokens integer CHECK (output_tokens     IS NULL OR output_tokens     >= 0),

    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,

    duration_ms integer GENERATED ALWAYS AS (
        CASE
            WHEN finished_at IS NULL THEN NULL
            ELSE (EXTRACT(EPOCH FROM (finished_at - started_at)) * 1000)::integer
        END
    ) STORED,

    CONSTRAINT agent_runs_finished_after_started
        CHECK (finished_at IS NULL OR finished_at >= started_at),
    CONSTRAINT agent_runs_error_requires_message
        CHECK (status <> 'error' OR error IS NOT NULL)
);

CREATE INDEX agent_runs_agent_name_idx ON agent_runs (agent_name, started_at DESC);
CREATE INDEX agent_runs_company_id_idx ON agent_runs (company_id);
CREATE INDEX agent_runs_started_at_idx ON agent_runs (started_at DESC);

-- WF-101 Agent Health reads failures and stuck runs off these two.
CREATE INDEX agent_runs_failures_idx ON agent_runs (started_at DESC)
    WHERE status IN ('error', 'timeout');
CREATE INDEX agent_runs_inflight_idx ON agent_runs (started_at)
    WHERE status = 'running';
