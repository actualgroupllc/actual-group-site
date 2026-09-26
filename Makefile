# Actual Group LLC — landing page.
#
# Publishing is owned by .github/workflows/deploy.yml; this file is local
# tooling that CI reuses (`make check`, `make dist`) so the validation that
# runs on your machine is the same validation that gates a deploy.

SHELL := /bin/bash

REPO     ?= actualgroupllc/actual-group-site
BRANCH   ?= main
PORT     ?= 8000
SITE_URL ?= https://actualgroupllc.github.io/actual-group-site/
MSG      ?= Update site

ASSET_DIR  := assets
# The social card is content-addressed: assets/og-image.<sha8>.png. Facebook,
# LinkedIn, and X cache an unfurl against the image URL and re-scrape on their
# own schedule, so a new card at the old filename keeps showing the old picture
# for everyone who has already shared the link. Renaming on every content change
# sidesteps the cache entirely — `make og` recomputes the hash, renames, and
# rewrites the <meta> tags, and `check` fails if the three ever drift apart.
# Deferred (=, not :=) on purpose: `make og` renames the card mid-run, and the
# recipes that follow it in the same invocation have to see the new name.
OG_CARDS    = $(wildcard $(ASSET_DIR)/og-image.*.png)
OG_CARD     = $(firstword $(OG_CARDS))
# Icons and the social card live under assets/; index.html and .nojekyll have
# to sit at the site root, so the two groups are staged differently. favicon.ico
# stays at the root too — clients that don't parse <link rel="icon"> (bookmark
# managers, feed readers) request /favicon.ico blind.
ASSETS      = $(ASSET_DIR)/favicon.svg $(ASSET_DIR)/apple-touch-icon.png \
              $(OG_CARD)
ROOT_FILES := index.html favicon.ico .nojekyll

.DEFAULT_GOAL := help
.PHONY: help serve og check dist deploy verify status setup open cname clean
# `deploy` runs og before check; left-to-right prerequisite order is only
# guaranteed outside parallel mode.
.NOTPARALLEL:

# Renames assets/og-image*.png to match its own content hash and points the
# social <meta> tags at the new name. Idempotent: re-running it on an
# already-stamped card is a no-op, so it is safe to wire into `deploy`.
define OG_PY
import hashlib, pathlib, re, subprocess, sys
CARDS = sorted(pathlib.Path("assets").glob("og-image*.png"))
if not CARDS:
    sys.exit("no assets/og-image*.png to stamp")
html = pathlib.Path("index.html")
s = html.read_text(encoding="utf-8")
REF = re.compile(r'assets/(og-image[^"]*\.png)')
refs = REF.findall(s)
# og:image and twitter:image, both absolute. Any other count means the tags
# were hand-edited into a shape this rewrite would mangle.
if len(refs) != 2:
    sys.exit("index.html: expected 2 og-image references, found %d" % len(refs))
if len(CARDS) > 1:
    # Leftovers from an interrupted stamp: the card index.html points at is
    # the real one, and the rest get dropped.
    live = [c for c in CARDS if c.name in set(refs)]
    if len(live) != 1:
        sys.exit("ambiguous: %s on disk, index.html references %s"
                 % ([c.name for c in CARDS], sorted(set(refs))))
    CARDS = live + [c for c in CARDS if c not in live]
src, stale = CARDS[0], CARDS[1:]
digest = hashlib.sha256(src.read_bytes()).hexdigest()[:8]
dst = src.with_name("og-image.%s.png" % digest)

def git(*args):
    return subprocess.run(("git",) + args, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0

if src != dst:
    # git mv keeps the rename in the index; it no-ops on an untracked file,
    # which the plain rename below then handles.
    git("mv", "-f", str(src), str(dst))
    if src.exists():
        src.replace(dst)
    print("  renamed  %s -> %s" % (src.name, dst.name))
for c in stale:
    if not git("rm", "-qf", str(c)):
        c.unlink()
    print("  dropped  %s" % c.name)
new = REF.sub("assets/" + dst.name, s)
if new != s:
    html.write_text(new, encoding="utf-8")
    print("  rewrote  og:image and twitter:image")
print("✓ social card stamped: %s" % dst.name)
endef
export OG_PY

# index.html carries the whole site inside JSON <script> islands, so a stray
# hand-edit can silently break the page. Re-parse them before every deploy.
define CHECK_PY
import hashlib, json, pathlib, re, struct, sys
s = open("index.html", encoding="utf-8").read()
for tag in ("manifest", "template", "page_order", "ext_resources"):
    m = re.search(r'<script type="__bundler/%s">\n(.*?)\n  </script>' % tag, s, re.S)
    if not m:
        sys.exit("index.html: __bundler/%s island is missing" % tag)
    try:
        json.loads(m.group(1))
    except json.JSONDecodeError as e:
        sys.exit("index.html: __bundler/%s is not valid JSON (%s)" % (tag, e))
for tag in ("og:image", "og:title", "og:url", "twitter:card"):
    if tag not in s:
        sys.exit("index.html: <meta> for %s is missing" % tag)
# The card's filename carries a hash of its own bytes so that a redesigned card
# unfurls at a URL the social caches have never seen. Three things have to agree
# — the bytes, the name, and the <meta> tags — and only `make og` moves them
# together, so any drift is a stale stamp rather than a deliberate edit.
cards = sorted(pathlib.Path("assets").glob("og-image*.png"))
if len(cards) != 1:
    sys.exit("expected one assets/og-image*.png, found %d (%s) — run `make og`"
             % (len(cards), ", ".join(c.name for c in cards) or "none"))
card = cards[0]
digest = hashlib.sha256(card.read_bytes()).hexdigest()[:8]
if card.name != "og-image.%s.png" % digest:
    sys.exit("%s no longer matches its own bytes (expected og-image.%s.png)"
             " — run `make og`" % (card.name, digest))
refs = set(re.findall(r'assets/(og-image[^"]*\.png)', s))
if refs != {card.name}:
    sys.exit("index.html points at %s but the card on disk is %s — run `make og`"
             % (", ".join(sorted(refs)) or "no card", card.name))
# Unfurlers lay out the card from the declared dimensions; if the image is
# regenerated at another size the tags have to move with it.
w, h = struct.unpack(">II", card.read_bytes()[16:24])
for prop, actual in (("width", w), ("height", h)):
    declared = re.search(r'og:image:%s" content="(\d+)"' % prop, s)
    if not declared:
        sys.exit("index.html: og:image:%s is missing" % prop)
    if int(declared.group(1)) != actual:
        sys.exit("%s is %dx%d but og:image:%s says %s"
                 % (card.name, w, h, prop, declared.group(1)))
endef
export CHECK_PY

help: ## Show this help
	@echo "Actual Group LLC — site tasks"
	@echo
	@grep -hE '^[a-z][a-zA-Z_-]*:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Live: $(SITE_URL)"

serve: ## Preview locally (PORT=8000 by default)
	@echo "→ http://localhost:$(PORT)  (ctrl-c to stop)"
	@python3 -m http.server $(PORT) --bind 127.0.0.1

og: ## Re-stamp the social card's content hash into its filename and meta tags
	@python3 -c "$$OG_PY"

check: ## Verify assets exist and index.html's bundle is uncorrupted
	@for f in $(ROOT_FILES) $(ASSETS); do \
		test -f "$$f" || { echo "missing: $$f"; exit 1; }; \
	done
	@python3 -c "$$CHECK_PY"
	@echo "✓ assets present, bundle intact, social tags consistent"

dist: check ## Stage the deployable site into _site/
	@rm -rf _site && mkdir -p _site
	@cp $(ROOT_FILES) _site/
	@cp -R $(ASSET_DIR) _site/$(ASSET_DIR)
	@test -f CNAME && cp CNAME _site/ || true
	@echo "✓ staged $$(find _site -type f | wc -l | tr -d ' ') files into _site/"

deploy: og check ## Commit, push, and follow the CI deployment
	@git add -A
	@if git diff --cached --quiet; then \
		echo "nothing to commit"; \
	else \
		git commit -q -m "$(MSG)"; echo "✓ committed"; \
	fi
	@git push -q -u origin $(BRANCH)
	@echo "✓ pushed to $(REPO)@$(BRANCH) — CI is publishing"
	@sleep 4
	@gh run watch --exit-status \
		$$(gh run list --workflow=deploy.yml --branch=$(BRANCH) --limit=1 \
			--json databaseId --jq '.[0].databaseId')

verify: ## Check the live site serves the OG card and icons
	@echo "checking $(SITE_URL)"
	@curl -sfL "$(SITE_URL)" | grep -o 'og:image" content="[^"]*"' \
		|| { echo "og:image not live yet"; exit 1; }
	@for f in favicon.ico $(ASSETS); do \
		printf "  %-30s %s\n" "$$f" "$$(curl -sLo /dev/null -w '%{http_code}' "$(SITE_URL)$$f")"; \
	done

status: ## Show recent deployment runs
	@gh run list --workflow=deploy.yml --limit=5

setup: ## Create the Pages site — run once before the first deploy
	@gh api -X POST "repos/$(REPO)/pages" -f 'build_type=workflow' --silent 2>/dev/null \
	|| gh api -X PUT "repos/$(REPO)/pages" -f 'build_type=workflow' --silent
	@echo "✓ Pages source set to GitHub Actions"

open: ## Open the live site in a browser
	@open "$(SITE_URL)"

cname: ## Point Pages at a custom domain: make cname DOMAIN=example.com
	@test -n "$(DOMAIN)" || { echo "usage: make cname DOMAIN=example.com"; exit 1; }
	@echo "$(DOMAIN)" > CNAME
	@gh api -X PUT "repos/$(REPO)/pages" -f 'cname=$(DOMAIN)' -F 'https_enforced=true' --silent
	@echo "✓ CNAME written and Pages updated — now update SITE_URL in this Makefile"
	@echo "  and the absolute og:image/og:url/canonical URLs in index.html"

clean: ## Remove the staging directory
	@rm -rf _site && echo "✓ removed _site/"
