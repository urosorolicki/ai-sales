# Opportunity Radar

**Status: Phase 13. Not implemented.** This document specifies it.

## The point

Lead databases sell lists of companies that match a filter. Everyone selling to
DevOps teams buys the same list and writes the same email, and the recipient has
learned to delete all of them.

The radar does something different: it watches public signals and surfaces
companies that have **published evidence that they need infrastructure help
right now**. The output is not "a 50-200 person SaaS company in the
Netherlands". It is "this company posted a Senior Platform Engineer role
eleven days ago that describes an EKS migration already in progress."

The second one is worth writing to. The first one is a list.

## Sources

| Source | What it shows | How |
|---|---|---|
| **Job boards** | The strongest signal available. An open senior DevOps/SRE/platform role is an admission of need, with budget attached. | Company careers pages, aggregators, per-company polling |
| **GitHub** | The real stack. New Terraform, a Helm chart appearing, a `.github/workflows` rewrite, a k8s manifest directory landing in a repo that had none. | Public repo activity, org-level events |
| **Engineering blogs** | Stated migrations, incident write-ups, "how we scaled", "why we moved off X". Dated and specific. | RSS/Atom, sitemap polling |
| **Funding announcements** | Money followed by engineering hiring is a reliable precursor to infrastructure strain. | Public funding feeds, press releases |
| **Company websites** | Team page growth, a new status page, a new docs site, a changelog that suddenly ships daily. | Periodic diffing |
| **Public technical docs** | Architecture pages, API docs, status pages. Shows the stack and its complexity. | Fetch and diff |
| **Leadership changes** | A new CTO or VP Engineering re-opens every infrastructure decision within their first quarter. | Public announcements, team pages |

## What counts as a signal

A radar hit needs all four:

1. **Specific.** A named role, a named technology, a dated post. Not "they are a
   tech company".
2. **Current.** Dated within 90 days. A migration announced in 2023 is finished
   and mentioning it now reads as carelessness.
3. **Sourced.** A URL a human can open and verify in ten seconds.
4. **Actionable.** It implies a problem the consultant can actually solve.

Anything failing one of these is noise, and noise in the radar becomes an email
that should not have been sent.

## Examples of real hits

- "Hiring a Senior DevOps Engineer, open 60+ days, job description names
  Kubernetes and Terraform."
- "Engineering blog, three weeks ago: migration from ECS to EKS in progress."
- "Raised a Series A last month, four infrastructure roles opened since."
- "Status page shows five incidents in six weeks, all database-related."
- "Public repo gained its first Terraform directory this month."
- "40 engineers, a Kubernetes cluster, no platform team on the team page."
- "New VP Engineering started in January, engineering headcount up 30% since."

## Scoring integration

Radar findings become `signals` rows with the source URL, and feed the existing
rubric - mostly the hiring (20) and pain (20) components. Nothing about scoring
changes. The radar improves the input, not the judgement.

Companies discovered this way carry `source = 'radar_github'`, `'radar_jobs'`,
`'radar_blog'` or `'radar_funding'`, so their conversion can be compared against
provider-sourced companies. That comparison is the whole justification for the
phase, and it needs the provider baseline to exist first - which is why the
radar is Phase 13 and not Phase 4.

## Constraints

**Politeness is a hard requirement.** Respect robots.txt, rate limit per domain,
identify the crawler honestly, cache aggressively, poll daily at most. A radar
that gets the IP blocked stops working, and it is rude besides.

**Diffing over re-reading.** The signal is usually the change, not the content.
Store a hash per source and only invoke a model when it moves. This is also
what keeps the cost of the radar near zero.

**Deduplicate hard.** The same job advert will appear on the careers page, an
aggregator and a social post. The unique index on
`(company_id, signal_type, md5(signal))` handles the identical case; near
duplicates need normalisation before insert.

**Decay matters.** A signal that was strong in March is weak in September. Score
by recency, and re-score companies whose signals have aged rather than letting a
stale hit keep a company in `HIGH_PRIORITY` forever.

## Build order

1. Job boards first, for the companies already in the database. Highest signal
   per unit of effort, and no discovery problem to solve yet.
2. Engineering blogs, by RSS, for the same set.
3. GitHub org activity for companies with a known public org.
4. Only then, discovery: using the radar to find companies not already known.

Step 4 is where this becomes a lead source rather than an enrichment layer, and
it is worth reaching. The first three make it safe to get there.
