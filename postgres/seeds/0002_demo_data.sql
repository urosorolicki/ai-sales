-- Seed: demo data for smoke testing the schema and the n8n workflows.
-- Uses reserved example domains only. Never load this into a real database.
--   make seed-demo

INSERT INTO companies (name, domain, website, country, industry, employee_count,
                       description, tech_stack, source, status,
                       fit_score, research_score, decision_maker_score)
VALUES (
    'Example Scaleup',
    'example.org',
    'https://example.org',
    'Netherlands',
    'B2B SaaS',
    85,
    'Demo row. Series A SaaS moving from a single VM to containers.',
    '["aws", "docker", "github-actions", "postgresql"]'::jsonb,
    'manual',
    'scored',
    42, 34, 10
)
ON CONFLICT (domain) DO NOTHING;

INSERT INTO signals (company_id, signal_type, signal, source_url, confidence)
SELECT c.id, 'hiring_devops',
       'Open role: Senior DevOps Engineer, Kubernetes and Terraform listed as required.',
       'https://example.org/careers/devops',
       0.90
FROM companies c WHERE c.domain = 'example.org'
ON CONFLICT DO NOTHING;

INSERT INTO signals (company_id, signal_type, signal, source_url, confidence)
SELECT c.id, 'kubernetes_adoption',
       'Engineering blog post describes an in-progress migration to EKS.',
       'https://example.org/blog/eks-migration',
       0.75
FROM companies c WHERE c.domain = 'example.org'
ON CONFLICT DO NOTHING;

INSERT INTO people (company_id, first_name, last_name, full_name, title,
                    seniority, email, email_status)
SELECT c.id, 'Demo', 'Person', 'Demo Person', 'VP Engineering',
       'vp', 'demo.person@example.org', 'guessed'
FROM companies c WHERE c.domain = 'example.org'
ON CONFLICT DO NOTHING;

INSERT INTO leads (company_id, person_id, score, reason, recommended_offer, status)
SELECT c.id, p.id, c.total_score,
       'Active DevOps hiring plus a public Kubernetes migration, no platform team yet.',
       'infrastructure_audit',
       'pending_approval'
FROM companies c
JOIN people p ON p.company_id = c.id
WHERE c.domain = 'example.org'
ON CONFLICT DO NOTHING;
