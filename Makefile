.PHONY: help generate test lint fmt-check check build examples \
	sync-readme sync-readme-check config-reference config-reference-check \
	example-coverage docs-md

help:
	@echo "Camunda Orchestration Cluster API — D SDK"
	@echo ""
	@echo "  make generate                 Regenerate client, docs/, examples/<tag>.d, operation-map"
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

generate:
	python3 scripts/generate.py

test:
	dub test

lint:
	./scripts/check-safe.sh
	dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source

build:
	dub build -b release

examples:
	@set -e; \
	for f in examples/*.d; do \
		echo "dub build --single $$f"; \
		dub build --single "$$f"; \
	done

sync-readme:
	python3 scripts/sync-readme-snippets.py

sync-readme-check:
	python3 scripts/sync-readme-snippets.py --check

config-reference:
	python3 scripts/generate-config-reference.py

config-reference-check:
	python3 scripts/generate-config-reference.py --check

example-coverage:
	python3 scripts/check-example-coverage.py

docs-md:
	python3 scripts/generate-docusaurus-md.py --validate-links

check: test lint examples sync-readme-check config-reference-check example-coverage
	python3 scripts/generate.py
	@git diff --exit-code -- source/camunda/generated docs examples || \
		(echo "generated sources/docs/examples drifted; commit the output of make generate" && exit 1)
	python3 scripts/generate-docusaurus-md.py --validate-links
