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

## How it is set

Two typefaces, both subset to Latin + Latin Extended-A and served from this
origin. Nothing is fetched from a CDN.

| | | |
|---|---|---|
| Newsreader | variable, wght 300-700 | 68 KB | every word read as prose |
| JetBrains Mono | variable, wght 400-700 | 32 KB | every fact scanned for |

The split is the argument. What this business sells is a bounded piece of work
that ends in a written report, so the page is set like one, and the durations
and deliverables - two weeks, a written report, a fixed end date, a set number
of days a month - sit in the typeface the eye searches rather than mid-paragraph
where the old page buried them. Latin Extended-A is not optional: the footer
says Uroš.

Sources for the subsetting are not in the repo; the fonts were pinned to one
optical size, narrowed to the weight range actually used, and subset with
fonttools. Both licences ship next to them in `site/fonts/`, as OFL requires.

The four offers are not four equal boxes. `prompts/outreach.md` makes
`infrastructure_audit` the default offer because it is the smallest thing a
stranger can say yes to, so it gets a surface and a size the other three do not.
If that ordering changes there, it changes here.

The section labels hang on a rail that is a flex primitive with an absolute
measure floor rather than a media query, so the page reflows on the container it
is in. Checked at every width from 320 to 1600: no horizontal overflow, and no
width where the rail appears before the reading column can afford it.

Weakest text contrast is 6.35:1 against a 4.5 requirement, in both themes.

There is deliberately no scroll-driven reveal. A `view()` timeline is inactive
when nothing can scroll - a tall monitor, a zoomed-out window, a print pass - and
an animation filling from `opacity: 0` then leaves everything below the first
screen blank. Measured before it was removed: three of four sections at opacity
0 in a viewport tall enough not to scroll.

## Response headers

`site/_headers` is read at deploy time and is not served - a request for
`/_headers` returns 404.

The Content-Security-Policy denies every fetch and then names the three the page
makes: its own inline `<style>`, the favicon as a `data:` URI, and the two woff2
files from this origin. It has already earned its place - see the first known
gap below.

## Known gaps

- **Cloudflare injects a third-party analytics script.** The edge adds
  `static.cloudflareinsights.com/beacon.min.js` to the HTML, but only when the
  request carries a browser User-Agent - `curl` gets a response byte-identical to
  the file in this repo, which is why it went unnoticed. The CSP blocks it from
  executing, so nothing is reported, but a page that promises no third parties
  should not be relying on a header to keep one out. Turn it off at the source:
  Cloudflare dashboard > foldnine.dev > Web Analytics, and disable the automatic
  setup. It cannot be done from here; the deploy token has `zone (read)` only.
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
