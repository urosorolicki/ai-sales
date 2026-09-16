-- 0013_enrichment.sql
-- What WF-03 needs to record a contact honestly.
--
-- There is no paid data provider and no email verification service in this
-- system, and there will not be one until the first client pays for it. So a
-- contact is only ever as good as the evidence behind it, and the evidence has
-- to be stored next to it or the distinction is lost the moment the row is
-- written.

-- WF-03 calls a model to read a team page, so it writes agent_runs rows like
-- every other agent. The list was fixed when only five agents existed.
ALTER TABLE agent_runs DROP CONSTRAINT agent_runs_agent_name_check;
ALTER TABLE agent_runs ADD CONSTRAINT agent_runs_agent_name_check CHECK (agent_name IN (
    'research', 'scoring', 'outreach', 'classifier', 'conversation', 'radar', 'enrichment'
));

ALTER TABLE people
    ADD COLUMN source_url        text,
    ADD COLUMN discovery_method  text CHECK (discovery_method IS NULL OR discovery_method IN (
        'published_page',    -- the address is literally on a page the company publishes
        'pattern_inferred',  -- derived from another address observed on the same domain
        'provider',          -- a paid lookup. Nothing does this yet.
        'manual'
    ));

COMMENT ON COLUMN people.source_url IS
    'The page the contact was read from. Required in practice for published_page.';
COMMENT ON COLUMN people.discovery_method IS
    'How the address was obtained. See docs/contact-enrichment.md.';

-- email_status has no deliverability check behind it anywhere in this system,
-- so its values mean something narrower than the names suggest. Written down
-- here because a column whose meaning lives only in a workflow is a column that
-- will be misread.
--
--   valid       published by the company on its own domain, with a source_url.
--               The strongest evidence available without paying for anything.
--               NOT SMTP-verified - nothing here verifies deliverability.
--   guessed     derived from a pattern observed in a real address on the same
--               domain. Never a blind guess from a list of templates.
--   unknown     a person exists but no address is known.
--   the rest    reserved for a verification provider and for bounce handling.
COMMENT ON COLUMN people.email_status IS
    'Confidence in the address, not deliverability. See 0013_enrichment.sql.';

-- Finding the same person twice must update rather than duplicate. people
-- already has a unique index on email; this covers the ones without an address,
-- which is most of them at the point they are first written.
CREATE UNIQUE INDEX people_company_name_key
    ON people (company_id, lower(btrim(full_name)));

CREATE INDEX people_discovery_method_idx ON people (discovery_method);
