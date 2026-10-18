.DEFAULT_GOAL := help
# SwiftPM products are shared by these targets, even with make -j.
.NOTPARALLEL:
.PHONY: help release debug archive distribution dmg test

PYTHON ?= python3
RELEASE_OUTPUT ?= build/release/LCMP.app
DEBUG_OUTPUT ?= build/debug/LCMP.app
ARCHIVE ?= build/dist/LCMP.zip
DISTRIBUTION_OUTPUT ?= build/distribution
DMG_OUTPUT ?=
DMG_APP ?=
AUDIO_SOURCE ?=

help:
	@printf '%s\n' 'make release  Release app: $(RELEASE_OUTPUT)' \
	  'make debug    Debug app: $(DEBUG_OUTPUT)' \
	  'make archive  Build Release and ZIP: $(ARCHIVE)' \
	  'make distribution  Source-built app, corresponding source and relink kit: $(DISTRIBUTION_OUTPUT)' \
	  'make dmg      Installer DMG of the source distribution: build/dmg/LCMP-<version>.dmg' \
	  'make test     Tests without audio output' \
	  'Overrides: PYTHON, RELEASE_OUTPUT, DEBUG_OUTPUT, ARCHIVE, DISTRIBUTION_OUTPUT, AUDIO_SOURCE, DMG_OUTPUT, DMG_APP'

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

distribution:
	$(PYTHON) scripts/distribution.py --output "$(DISTRIBUTION_OUTPUT)" $(if $(AUDIO_SOURCE),--audio-source "$(AUDIO_SOURCE)",)

dmg:
	$(PYTHON) scripts/build-dmg.py $(if $(DMG_OUTPUT),--output "$(DMG_OUTPUT)",) $(if $(DMG_APP),--app "$(DMG_APP)",) $(if $(AUDIO_SOURCE),--audio-source "$(AUDIO_SOURCE)",)

test:
	$(PYTHON) scripts/test_acknowledgements.py
	$(PYTHON) scripts/test_distribution.py
	$(PYTHON) scripts/test_app_version.py
	$(PYTHON) scripts/test_app_icon.py
	$(PYTHON) scripts/test_build_dmg.py
	@# Tests must not leave UserDefaults suite plists behind.
	@set -eu; \
	  count() { find "$$HOME/Library/Preferences" -maxdepth 1 -name 'lcmp-*.plist' 2>/dev/null | wc -l | tr -d ' '; }; \
	  before=$$(count); \
	  LCMP_TEST_AUDIO_OUTPUT=0 ./scripts/swift.sh test --no-parallel; \
	  after=$$(count); \
	  if [ "$$after" -gt "$$before" ]; then \
	    printf 'Tests left %s new lcmp-*.plist file(s) in ~/Library/Preferences.\n' "$$((after - before))" >&2; exit 1; \
	  fi
