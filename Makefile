.DEFAULT_GOAL := help
# SwiftPM products are shared by these targets, even with make -j.
.NOTPARALLEL:
.PHONY: help release debug archive test

PYTHON ?= python3
RELEASE_OUTPUT ?= build/release/LCMP.app
DEBUG_OUTPUT ?= build/debug/LCMP.app
ARCHIVE ?= build/dist/LCMP.zip

help:
	@printf '%s\n' 'make release  Release app: $(RELEASE_OUTPUT)' \
	  'make debug    Debug app: $(DEBUG_OUTPUT)' \
	  'make archive  Build Release and ZIP: $(ARCHIVE)' \
	  'make test     Tests without audio output' \
	  'Overrides: PYTHON, RELEASE_OUTPUT, DEBUG_OUTPUT, ARCHIVE'

release:
	$(PYTHON) scripts/build-app.py --configuration release --output "$(RELEASE_OUTPUT)"

debug:
	$(PYTHON) scripts/build-app.py --configuration debug --output "$(DEBUG_OUTPUT)"

archive: release
	@set -eu; \
	  mkdir -p "$$(dirname "$(ARCHIVE)")"; \
	  temporary=$$(mktemp "$(ARCHIVE).XXXXXX"); \
	  trap 'rm -f "$$temporary"' EXIT HUP INT TERM; \
	  ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_OUTPUT)" "$$temporary"; \
	  mv -f "$$temporary" "$(ARCHIVE)"; \
	  printf '%s\n' "$(ARCHIVE)"

test:
	LCMP_TEST_AUDIO_OUTPUT=0 ./scripts/swift.sh test --no-parallel
