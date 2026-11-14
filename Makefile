.PHONY: help generate generate-local bundle-spec test lint fmt-check check build examples \
	sync-readme sync-readme-check config-reference config-reference-check \
	example-coverage docs-md

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
	@echo "  make docs-md                  Generate docs-md/d-sdk/ for camunda-docs"
	@echo "  make check                    Full local CI gate"

bundle-spec:
	npm run bundle:spec

generate: bundle-spec generate-local

generate-local:
	$(SCRIPT) scripts/generate.d

test:
	dub test
	dub test :runtime

lint:
	./scripts/check-safe.sh
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source runtime/source

build:
	dub build -b release
	dub build -b release :runtime

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

docs-md:
	$(SCRIPT) scripts/generate-docusaurus-md.d -- --validate-links

check: test lint examples sync-readme-check config-reference-check example-coverage
	$(SCRIPT) scripts/generate.d
	@git diff --exit-code -- source/camunda/generated docs examples || \
		(echo "generated sources/docs/examples drifted; commit the output of make generate-local" && exit 1)
	$(SCRIPT) scripts/generate-docusaurus-md.d -- --validate-links
