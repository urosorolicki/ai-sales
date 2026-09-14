-- 0007_suppression.sql
-- Hard opt-out list. This table is the last word: nothing in the system may
-- send to an address or domain listed here. Enforced again by a trigger on
-- outreach (0008) so a buggy workflow cannot bypass it.

CREATE TABLE suppression_list (
    id     uuid   PRIMARY KEY DEFAULT gen_random_uuid(),
    email  citext,
    domain citext,

    reason text NOT NULL CHECK (reason IN (
        'unsubscribe_request',
        'explicit_negative',
        'hard_bounce',
        'spam_complaint',
        'competitor',
        'existing_client',
        'manual',
        'do_not_contact_policy'
    )),
    note   text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT suppression_target_required
        CHECK (email IS NOT NULL OR domain IS NOT NULL)
);

CREATE UNIQUE INDEX suppression_email_key  ON suppression_list (email)  WHERE email  IS NOT NULL;
CREATE UNIQUE INDEX suppression_domain_key ON suppression_list (domain) WHERE domain IS NOT NULL;

-- True if the address itself, or the domain it belongs to, is suppressed.
CREATE OR REPLACE FUNCTION is_suppressed(check_email citext)
RETURNS boolean
LANGUAGE sql
STABLE
AS $fn$
    SELECT EXISTS (
        SELECT 1
        FROM suppression_list s
        WHERE (s.email IS NOT NULL AND s.email = check_email)
           OR (s.domain IS NOT NULL AND check_email IS NOT NULL
               AND split_part(check_email::text, '@', 2)::citext = s.domain)
    );
$fn$;
