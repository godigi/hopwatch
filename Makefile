# Makefile — top-level entry point for tests, GUI builds, and DMG packaging.
#
# Usage:
#   make test          run both CLI (bats) and GUI test suites
#   make test-cli      run bats tests/
#   make test-gui      run Swift package tests in gui/
#   make gui           build, bundle, and sign the macOS GUI app
#   make dmg           package the signed GUI into a distributable .dmg
#   make clean         clean build artifacts

.PHONY: all test test-cli test-gui gui dmg install-gui clean bump bump-patch bump-minor bump-major hooks ship ship-all

all: test

test: test-cli test-gui

test-cli:
	bats tests/

test-gui:
	$(MAKE) -C gui test

gui:
	$(MAKE) -C gui

dmg:
	$(MAKE) -C gui dmg

install-gui:
	$(MAKE) -C gui install

clean:
	$(MAKE) -C gui clean

hooks:
	git config core.hooksPath .githooks

bump:
	python3 scripts/bump.py

bump-patch:
	python3 scripts/bump.py --type patch

bump-minor:
	python3 scripts/bump.py --type minor

bump-major:
	python3 scripts/bump.py --type major

ship: test-gui
	python3 scripts/bump.py
	$(MAKE) -C gui dmg
	git push origin main --tags
	@version=$$(sed -n 's/^HOPWATCH_VERSION="\([^"]*\)".*/\1/p' bin/hopwatch | head -1); \
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
	  echo "Ensuring GitHub Release v$$version has compiled assets..."; \
	  cp "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch.dmg" 2>/dev/null || true; \
	  cp "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.zip" 2>/dev/null || true; \
	  if ! gh release view "v$$version" >/dev/null 2>&1; then \
	    gh release create "v$$version" "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.dmg" "gui/build/Hopwatch.zip" --title "Release v$$version" --generate-notes || true; \
	  else \
	    gh release upload "v$$version" "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.dmg" "gui/build/Hopwatch.zip" --clobber || true; \
	  fi; \
	fi
	$(MAKE) install-gui
	open /Applications/Hopwatch.app

ship-all: test
	python3 scripts/bump.py
	$(MAKE) -C gui dmg
	git push origin main --tags
	@version=$$(sed -n 's/^HOPWATCH_VERSION="\([^"]*\)".*/\1/p' bin/hopwatch | head -1); \
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then \
	  echo "Ensuring GitHub Release v$$version has compiled assets..."; \
	  cp "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch.dmg" 2>/dev/null || true; \
	  cp "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.zip" 2>/dev/null || true; \
	  if ! gh release view "v$$version" >/dev/null 2>&1; then \
	    gh release create "v$$version" "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.dmg" "gui/build/Hopwatch.zip" --title "Release v$$version" --generate-notes || true; \
	  else \
	    gh release upload "v$$version" "gui/build/Hopwatch-$${version}.dmg" "gui/build/Hopwatch-$${version}.zip" "gui/build/Hopwatch.dmg" "gui/build/Hopwatch.zip" --clobber || true; \
	  fi; \
	fi
	$(MAKE) install-gui
	open /Applications/Hopwatch.app
