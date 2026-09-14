-- 0003_people.sql
-- Decision makers and other contacts attached to a company.

CREATE TABLE people (
    id          uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id  uuid    NOT NULL REFERENCES companies (id) ON DELETE CASCADE,

    first_name  text,
    last_name   text,
    full_name   text    NOT NULL CHECK (length(btrim(full_name)) > 0),
    title       text,
    seniority   text    CHECK (seniority IS NULL OR seniority IN (
        'c_level', 'vp', 'head', 'director', 'manager',
        'lead', 'senior', 'individual_contributor', 'unknown'
    )),

    email        citext,
    email_status text NOT NULL DEFAULT 'unknown' CHECK (email_status IN (
        'unknown', 'guessed', 'valid', 'risky', 'catch_all', 'invalid', 'bounced'
    )),
    linkedin_url text,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER people_set_updated_at
    BEFORE UPDATE ON people
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- One row per address; a person belongs to exactly one company here.
CREATE UNIQUE INDEX people_email_key ON people (email) WHERE email IS NOT NULL;

CREATE INDEX people_company_id_idx ON people (company_id);
CREATE INDEX people_seniority_idx  ON people (seniority);

-- Contacts that are actually usable for outreach.
CREATE INDEX people_contactable_idx ON people (company_id)
    WHERE email IS NOT NULL AND email_status IN ('valid', 'catch_all', 'guessed');
