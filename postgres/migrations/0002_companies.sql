-- 0002_companies.sql
-- Companies are the root entity. `domain` is the deduplication key.

CREATE TABLE companies (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            text        NOT NULL CHECK (length(btrim(name)) > 0),
    domain          citext      NOT NULL UNIQUE,
    website         text,
    country         text,
    industry        text,
    employee_count  integer     CHECK (employee_count IS NULL OR employee_count >= 0),
    description     text,
    linkedin_url    text,

    tech_stack      jsonb       NOT NULL DEFAULT '[]'::jsonb
                                CHECK (jsonb_typeof(tech_stack) = 'array'),
    hiring_signals  jsonb       NOT NULL DEFAULT '[]'::jsonb
                                CHECK (jsonb_typeof(hiring_signals) = 'array'),
    pain_signals    jsonb       NOT NULL DEFAULT '[]'::jsonb
                                CHECK (jsonb_typeof(pain_signals) = 'array'),

    -- Scoring components, see docs/scoring.md for the rubric.
    -- fit_score            = company fit (20) + technology fit (20) + commercial (10)
    -- research_score       = hiring signal (20) + pain evidence (20)
    -- decision_maker_score = reachable decision maker (10)
    fit_score               smallint CHECK (fit_score            BETWEEN 0 AND 50),
    research_score          smallint CHECK (research_score       BETWEEN 0 AND 40),
    decision_maker_score    smallint CHECK (decision_maker_score BETWEEN 0 AND 10),

    total_score smallint GENERATED ALWAYS AS (
        coalesce(fit_score, 0) + coalesce(research_score, 0) + coalesce(decision_maker_score, 0)
    ) STORED,

    score_band text GENERATED ALWAYS AS (
        CASE
            WHEN fit_score IS NULL AND research_score IS NULL AND decision_maker_score IS NULL
                THEN 'UNSCORED'
            WHEN coalesce(fit_score,0) + coalesce(research_score,0) + coalesce(decision_maker_score,0) >= 90
                THEN 'HOT'
            WHEN coalesce(fit_score,0) + coalesce(research_score,0) + coalesce(decision_maker_score,0) >= 75
                THEN 'HIGH_PRIORITY'
            WHEN coalesce(fit_score,0) + coalesce(research_score,0) + coalesce(decision_maker_score,0) >= 60
                THEN 'OUTREACH'
            WHEN coalesce(fit_score,0) + coalesce(research_score,0) + coalesce(decision_maker_score,0) >= 40
                THEN 'NURTURE'
            ELSE 'IGNORE'
        END
    ) STORED,

    status text NOT NULL DEFAULT 'new' CHECK (status IN (
        'new', 'researching', 'researched', 'scored', 'enriching',
        'ready', 'contacted', 'replied', 'opportunity',
        'won', 'lost', 'ignored', 'suppressed'
    )),
    source text NOT NULL DEFAULT 'manual' CHECK (source IN (
        'manual', 'apollo', 'radar_github', 'radar_jobs', 'radar_blog',
        'radar_funding', 'referral', 'import'
    )),

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER companies_set_updated_at
    BEFORE UPDATE ON companies
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX companies_status_idx       ON companies (status);
CREATE INDEX companies_score_band_idx   ON companies (score_band);
CREATE INDEX companies_total_score_idx  ON companies (total_score DESC);
CREATE INDEX companies_country_idx      ON companies (country);
CREATE INDEX companies_created_at_idx   ON companies (created_at DESC);
CREATE INDEX companies_name_trgm_idx    ON companies USING gin (name gin_trgm_ops);
CREATE INDEX companies_tech_stack_idx   ON companies USING gin (tech_stack jsonb_path_ops);

-- The discovery queue: everything still waiting on research.
CREATE INDEX companies_pending_idx ON companies (created_at)
    WHERE status IN ('new', 'researching');
