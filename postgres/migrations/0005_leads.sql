-- 0005_leads.sql
-- A lead is one (company, person) pair that scoring decided is worth pursuing.

CREATE TABLE leads (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id  uuid NOT NULL REFERENCES companies (id) ON DELETE CASCADE,
    person_id   uuid NOT NULL REFERENCES people (id)    ON DELETE CASCADE,

    score  smallint CHECK (score BETWEEN 0 AND 100),
    reason text,

    recommended_offer text CHECK (recommended_offer IS NULL OR recommended_offer IN (
        'infrastructure_audit',
        'devops_improvement_sprint',
        'fractional_devops_sre',
        'none'
    )),

    status text NOT NULL DEFAULT 'new' CHECK (status IN (
        'new',
        'pending_approval',
        'approved',
        'rejected',
        'queued',
        'contacted',
        'replied',
        'opportunity',
        'nurture',
        'closed_won',
        'closed_lost',
        'suppressed'
    )),

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT leads_company_person_key UNIQUE (company_id, person_id)
);

CREATE TRIGGER leads_set_updated_at
    BEFORE UPDATE ON leads
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX leads_company_id_idx ON leads (company_id);
CREATE INDEX leads_person_id_idx  ON leads (person_id);
CREATE INDEX leads_status_idx     ON leads (status);
CREATE INDEX leads_score_idx      ON leads (score DESC);

-- The human approval queue that Telegram /leads reads.
CREATE INDEX leads_approval_queue_idx ON leads (score DESC, created_at)
    WHERE status = 'pending_approval';
