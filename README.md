# Actual Group LLC — site

Single-page marketing site for Actual Group LLC (Aurora, CO) — Colorado Medicaid
transition coordination: Targeted Case Management, Life Skills Training, and
Household Setup.

**Live:** https://actualgroupllc.github.io/actual-group-site/

Static site, no build step, no dependencies to install. GitHub Pages serves the
files as they sit in the repo; `make` is local tooling that CI reuses.

## Layout

```
index.html    the entire site — markup, styles, fonts, and images, in one file
favicon.ico   root-level on purpose: some clients request /favicon.ico blind
.nojekyll     tells Pages to serve the files verbatim
assets/
  favicon.svg
  apple-touch-icon.png
  og-image.<sha8>.png   social card, content-addressed (see below)
Makefile                serve / check / dist / deploy / verify
.github/workflows/deploy.yml   validates, stages, publishes, smoke-tests
```

`_site/` is the staging directory `make dist` writes — generated, gitignored.

## How index.html works

The page is a self-contained bundle. Four JSON `<script>` islands near the
bottom of the file hold everything:

| island | contents |
| --- | --- |
| `__bundler/manifest` | 21 base64 assets (web fonts, React UMD, the logo SVG, the hero photo), some gzipped |
| `__bundler/template` | the real document — markup and inline styles, referencing assets by uuid |
| `__bundler/ext_resources` | maps friendly ids (`heroPhoto`, `logoMark`, CDN URLs) to uuids |
| `__bundler/page_order` | nested page bundles; empty here (single page) |

On load, the shell you see at the top of the file paints a logo placeholder,
decodes the manifest into blob (or `data:`) URLs, substitutes each uuid in the
template, and swaps the live document in. That is why the file is ~1.4 MB and
why nothing is fetched from a CDN at runtime.

### Editing content

Copy for the page lives in the `__bundler/template` island, which is a single
very long line — search for the text you want to change (`Three services`,
`tel:7205793518`, section ids `top` / `how` / `services` / `contact`) and edit
in place. Keep the JSON string valid: quotes and backslashes inside it are
escaped, and a broken island means a blank page. `make check` re-parses all four
islands, so run it before pushing.

## Tasks

```
make          # list targets
make serve    # preview at http://localhost:8000 (PORT=8000)
make check    # islands parse, required files exist, social tags consistent
make dist     # stage the deployable site into _site/
make og       # re-stamp the social card's content hash
make deploy   # commit, push, and follow the CI run
make verify   # curl the live site for the OG card and icons
make status   # recent deploy runs
make clean    # remove _site/
```

`serve`, `check`, and `og` need only `python3`. `deploy`, `status`, `setup`, and
`cname` use the [`gh`](https://cli.github.com) CLI and need to be authenticated.

## The social card

Facebook, LinkedIn, and X cache an unfurl against the image URL, so a redesigned
card at the old filename keeps showing the old picture. The card is therefore
named after a hash of its own bytes — `assets/og-image.<sha8>.png` — and a new
picture unfurls at a URL the caches have never seen.

Three things have to agree: the bytes, the filename, and the `og:image` /
`twitter:image` meta tags (plus the declared width and height). Only `make og`
moves them together; `make check` fails on any drift. So after replacing the
card: drop the new PNG in as `assets/og-image.png`, run `make og`, and if the
dimensions changed, update `og:image:width` / `og:image:height` in `index.html`.

## Deploying

Pushing to `main` runs `.github/workflows/deploy.yml`, which runs `make check`,
stages with `make dist`, publishes to Pages, then polls the live URL and asserts
the card and icons return 200. `make deploy` does the push and tails that run.
Changes to `README.md` and `.gitignore` alone don't trigger a deploy.

One-time setup, needing repo admin rights that `GITHUB_TOKEN` can't be granted:
`make setup`, or Settings → Pages with Source set to "GitHub Actions".

## Custom domain

```
make cname DOMAIN=example.com
```

Writes `CNAME` (which `make dist` picks up) and points Pages at the domain. Then
update `SITE_URL` in the Makefile and the absolute `og:image`, `og:url`, and
`canonical` URLs in `index.html` — those are absolute by requirement and won't
follow the domain on their own.
