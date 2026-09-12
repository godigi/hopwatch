# Makefile — top-level entry point for tests, GUI builds, and DMG packaging.
#
# Usage:
#   make test          run both CLI (bats) and GUI test suites
#   make test-cli      run bats tests/
#   make test-gui      run Swift package tests in gui/
#   make gui           build, bundle, and sign the macOS GUI app
#   make dmg           package the signed GUI into a distributable .dmg
#   make clean         clean build artifacts

.PHONY: all test test-cli test-gui gui dmg install-gui clean

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
