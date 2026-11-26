.PHONY: help generate generate-local bundle-spec test lint fmt-check check build examples \
	sync-readme sync-readme-check config-reference config-reference-check \
	example-coverage docs-md api-compat repair-release test-repair-release typecheck-windows check-windows

# Repo tooling is D, run as dub single-file programs (no Python needed).
SCRIPT = dub run -q --single

help:
	@echo "Camunda Orchestration Cluster API — D SDK"
	@echo ""
	@echo "  make generate                 Fetch + bundle the spec from camunda/camunda (SPEC_REF, default main), then generate"
	@echo "  make generate-local           Regenerate from the committed bundle (what CI checks)"
	@echo "  make bundle-spec              Fetch + bundle only (npm run bundle:spec)"
	@echo "  make test                     dub test (unit tests, @safe gate)"
	@echo "  make lint                     D-Scanner + check-safe.sh"
	@echo "  make build                    dub build -b release"
	@echo "  make examples                 Type-check every example (readme, topology, generated)"
	@echo "  make sync-readme              Inject examples/readme.d regions into README.md"
	@echo "  make sync-readme-check        CI: fail if README snippets drifted"
	@echo "  make config-reference         Inject CAMUNDA_* table into README.md"
	@echo "  make config-reference-check   CI: fail if the table drifted"
	@echo "  make example-coverage         Every spec operation has a region in examples/"
	@echo "  make api-compat [BASE=ref]    Public-API breaks vs a git ref (default origin/main; e.g. BASE=v11.0.0)"
	@echo "  make docs-md                  Generate docs-md/d-sdk/ for camunda-docs"
	@echo "  make repair-release TAG=vX.Y.Z  Repair a half-finished release (note + GitHub Release)"
	@echo "  make test-repair-release      Run the repair-release.sh bash test harness"
	@echo "  make typecheck-windows        Compile every module for Windows (no link, no run; seconds)"
	@echo "  make check-windows            Run dub test on a real Windows CI runner for the working tree"
	@echo "  make check                    Full local CI gate"

bundle-spec:
	npm run bundle:spec

generate: bundle-spec generate-local

generate-local:
	$(SCRIPT) scripts/generate.d

test:
	dub test
	dub test :runtime
	dub test :openapi
	dub run -q --build=unittest --single scripts/generate.d -- --DRT-testmode=test-only
	dub run -q --build=unittest --single scripts/api-compat.d -- --DRT-testmode=test-only

lint:
	./scripts/check-safe.sh
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source runtime/source openapi/source

# Windows code (winhttp.d, wincrypt.d) is behind version (Windows), so a
# POSIX build never compiles it. LDC cross-compiles to Windows with the
# druntime headers it ships, so this catches Windows compile errors on any OS.
# It can't link or run: `make check-windows` does that on a real runner.
WINDOWS_DFLAGS = -mtriple=x86_64-windows-msvc -o- -unittest -preview=dip1000 -preview=nosharedaccess
typecheck-windows:
	ldc2 $(WINDOWS_DFLAGS) -Isource -Iruntime/source -Iopenapi/source \
		$$(find source runtime/source -name '*.d')
	ldc2 $(WINDOWS_DFLAGS) -Iruntime/source -Iopenapi/source $$(find openapi/source -name '*.d')

check-windows:
	./scripts/check-windows.sh

build:
	dub build -b release
	dub build -b release :runtime
	dub build -b release :openapi

examples:
	@set -e; \
	for f in examples/*.d; do \
		echo "dub build --single $$f"; \
		dub build --single "$$f"; \
	done

sync-readme:
	$(SCRIPT) scripts/sync-readme-snippets.d

sync-readme-check:
	$(SCRIPT) scripts/sync-readme-snippets.d -- --check

config-reference:
	$(SCRIPT) scripts/generate-config-reference.d

config-reference-check:
	$(SCRIPT) scripts/generate-config-reference.d -- --check

example-coverage:
	$(SCRIPT) scripts/check-example-coverage.d

# Public-API compatibility (see README "API compatibility"). Compares the
# working tree with BASE checked out into a temporary git worktree.
# Exit 1 means breaking changes; 2 means the check itself failed.
BASE ?= origin/main
API_COMPAT_BIN = scripts/.dub/bin/api-compat
api-compat:
	dub build -q --single scripts/api-compat.d
	@set -e; tmp=$$(mktemp -d); \
	trap 'git worktree remove --force "$$tmp/base" >/dev/null 2>&1; rm -rf "$$tmp"' EXIT; \
	git worktree add -q --detach "$$tmp/base" "$(BASE)"; \
	$(API_COMPAT_BIN) --baseline-dir "$$tmp/base" --baseline-tag "$(BASE)"

docs-md:
	$(SCRIPT) scripts/generate-docusaurus-md.d -- --validate-links

# Repair a half-finished release by hand: make repair-release TAG=vX.Y.Z
# (the publish workflow runs the same script automatically on failure, and via
# its `repair-tag` dispatch input).
repair-release:
	@test -n "$(TAG)" || (echo "usage: make repair-release TAG=vX.Y.Z" >&2; exit 2)
	bash scripts/repair-release.sh "$(TAG)"

test-repair-release:
	bash scripts/test-repair-release.sh

check: test lint typecheck-windows examples sync-readme-check config-reference-check example-coverage test-repair-release
	$(SCRIPT) scripts/generate.d
	@git diff --exit-code -- source/camunda/generated docs examples ':(exclude)examples/readme.d' ':(exclude)examples/topology.d' || \
		(echo "generated sources/docs/examples drifted; commit the output of make generate-local" && exit 1)
	$(SCRIPT) scripts/generate-docusaurus-md.d -- --validate-links
