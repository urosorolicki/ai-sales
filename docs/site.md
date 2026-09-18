# Site

`https://foldnine.dev` — the one page the signature in every outreach mail links
to. Source is `site/index.html`, a single file with no build step and no
dependency on anything it does not ship: no fonts, no scripts, no analytics.

Whoever clicks the link from a cold mail has to find the same voice and the same
four offers the mail made. The rules that keep it that way live in
`prompts/outreach.md`; changing what the page offers means changing that file in
the same commit, or the mail and the page stop agreeing.

## Where it runs

A Cloudflare Worker serving static assets, configured in `wrangler.jsonc` at the
repository root. Not Cloudflare Pages: wrangler 4.x delegates `pages` commands to
Workers and `pages project create` fails outright, Pages surviving only behind a
`--force` flag.

| | |
|---|---|
| Worker | `foldnine` |
| Account | `42192c31226ccc091d47a2a7df145dc0` |
| Served from | `site/` |
| Public address | `foldnine.dev`, and nothing else |

`workers_dev` and `preview_urls` are off. Both would publish a second and third
copy of the page at addresses search engines can find, which is how a marketing
site ends up competing with itself.

## Deploying

```bash
npx wrangler login     # once, OAuth in a browser
npx wrangler deploy    # reads wrangler.jsonc, uploads site/
```

The first deploy created the apex DNS record and the certificate. Later deploys
reuse both. The record is owned by the Worker custom domain, not by
`infra/dns/foldnine.dev.zone` — mail records and the site coexist at the apex
because Cloudflare proxies and flattens, so nothing in the zone file needs to
change when the site is redeployed.

Verify a deploy actually landed rather than trusting the success line:

```bash
curl -sS -D - -o /dev/null https://foldnine.dev/
```

## Response headers

`site/_headers` is read at deploy time and is not served — a request for
`/_headers` returns 404.

The Content-Security-Policy denies every fetch and then names the two the page
makes: its own inline `<style>`, and the favicon, which is a `data:` URI in the
markup. This is cheap to hold today because the page loads nothing external, and
the moment someone adds a font or a script it fails visibly in the browser
instead of quietly putting a third party on a page that promises not to have one.

## Known gaps

- **`http://foldnine.dev` answers 200 rather than redirecting.** No browser ever
  sees it — `.dev` is on the HSTS preload list, so browsers rewrite the scheme
  before sending anything — but curl and link checkers reach it in the clear.
  Fix is a zone setting, not a deploy: SSL/TLS > Edge Certificates > Always Use
  HTTPS.
- **`www.foldnine.dev` does not resolve.** Nothing links to it. Serving it means
  a second `custom_domain` route, or a redirect rule to the apex.
- **The footer has no legal identity.** A placeholder comment marks where the
  registered name, address and tax number go. Commercial mail into the EU has to
  identify its sender and `docs/security.md` rests the legitimate-interest basis
  on that identification being true, so this is an obligation rather than
  polish. It cannot be filled in by guessing.
