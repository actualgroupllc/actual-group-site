# Actual Group LLC — landing page.
#
# Publishing is owned by .github/workflows/deploy.yml; this file is local
# tooling that CI reuses (`make check`, `make dist`) so the validation that
# runs on your machine is the same validation that gates a deploy.

SHELL := /bin/bash

REPO     ?= Rezwanul-Haque/actual-group-site
BRANCH   ?= main
PORT     ?= 8000
SITE_URL ?= https://rezwanul-haque.github.io/actual-group-site/
MSG      ?= Update site

ASSET_DIR  := assets
# Icons and the social card live under assets/; index.html and .nojekyll have
# to sit at the site root, so the two groups are staged differently. favicon.ico
# stays at the root too — clients that don't parse <link rel="icon"> (bookmark
# managers, feed readers) request /favicon.ico blind.
ASSETS     := $(ASSET_DIR)/favicon.svg $(ASSET_DIR)/apple-touch-icon.png \
              $(ASSET_DIR)/og-image.png
ROOT_FILES := index.html favicon.ico .nojekyll

.DEFAULT_GOAL := help
.PHONY: help serve check dist deploy verify status setup open cname clean

# index.html carries the whole site inside JSON <script> islands, so a stray
# hand-edit can silently break the page. Re-parse them before every deploy.
define CHECK_PY
import json, re, struct, sys
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
# Unfurlers lay out the card from the declared dimensions; if the image is
# regenerated at another size the tags have to move with it.
w, h = struct.unpack(">II", open("assets/og-image.png", "rb").read(24)[16:24])
for prop, actual in (("width", w), ("height", h)):
    declared = re.search(r'og:image:%s" content="(\d+)"' % prop, s)
    if not declared:
        sys.exit("index.html: og:image:%s is missing" % prop)
    if int(declared.group(1)) != actual:
        sys.exit("og-image.png is %dx%d but og:image:%s says %s"
                 % (w, h, prop, declared.group(1)))
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

deploy: check ## Commit, push, and follow the CI deployment
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
