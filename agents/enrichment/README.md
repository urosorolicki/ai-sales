# enrichment

**Workflow:** WF-03 Contact Enrichment
**Prompt:** `prompts/enrichment.md`
**Model:** local (`OLLAMA_ENRICHMENT_MODEL`)

## Input

```json
{ "company_id": "uuid", "name": "", "domain": "" }
```

Plus the text of the company's own contact, team, about and careers pages.
Fetching is the workflow's job, not the agent's.

## Output

`schema.json`. Named people separately from role addresses (`jobs@`, `hello@`),
because a role address has no person behind it and must never be written into
`people` as though it did.

## What the workflow does not trust

Everything checkable is checked in `Validate And Verify`, not requested in the
prompt:

- **Every email must appear verbatim in the fetched text.** An address the model
  produced but the page does not contain is dropped, whatever it looks like.
- **Every email's domain must be the company's own.** A vendor's address in a
  footer is not a contact at this company.
- **Every name must appear verbatim in the fetched text**, so an invented person
  cannot survive.
- `seniority` is re-derived from the title in code; the model's value is ignored
  when it is not in the enum.

The schema constrains keys and types. Ollama does not enforce `enum` or
`format`, so neither is relied on. See `docs/ollama.md`.
