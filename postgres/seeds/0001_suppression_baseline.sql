-- Seed: suppression baseline.
-- Add your own domains, current clients and anyone who must never be
-- contacted BEFORE the first outreach run. Idempotent - safe to re-apply.
--
-- Nothing real is committed here. Fill in and keep local, or apply through
-- Telegram/n8n once the control plane exists.

INSERT INTO suppression_list (domain, reason, note) VALUES
    ('example.com', 'do_not_contact_policy', 'Replace with your own domain')
ON CONFLICT DO NOTHING;

-- Template for real entries:
-- INSERT INTO suppression_list (domain, reason, note) VALUES
--     ('your-own-company.com', 'do_not_contact_policy', 'Own domain'),
--     ('current-client.com',   'existing_client',       'Active engagement')
-- ON CONFLICT DO NOTHING;
--
-- INSERT INTO suppression_list (email, reason, note) VALUES
--     ('someone@company.com', 'unsubscribe_request', 'Opted out YYYY-MM-DD')
-- ON CONFLICT DO NOTHING;
