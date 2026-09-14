-- 0004_signals.sql
-- Evidence rows. Every signal carries a source; scoring reads only from here.

CREATE TABLE signals (
    id          uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id  uuid    NOT NULL REFERENCES companies (id) ON DELETE CASCADE,

    signal_type text NOT NULL CHECK (signal_type IN (
        'hiring_devops',
        'hiring_engineering_growth',
        'kubernetes_adoption',
        'cloud_migration',
        'infrastructure_scaling',
        'reliability_problem',
        'cloud_cost_problem',
        'leadership_change',
        'funding',
        'technology_announcement',
        'other'
    )),
    signal     text         NOT NULL CHECK (length(btrim(signal)) > 0),
    source_url text,
    confidence numeric(3,2) NOT NULL DEFAULT 0.50
                            CHECK (confidence BETWEEN 0 AND 1),

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX signals_company_id_idx ON signals (company_id);
CREATE INDEX signals_type_idx       ON signals (signal_type);
CREATE INDEX signals_created_at_idx ON signals (created_at DESC);

-- Radar workflows re-run on a schedule; do not accumulate the same evidence.
CREATE UNIQUE INDEX signals_dedupe_key
    ON signals (company_id, signal_type, md5(signal));
