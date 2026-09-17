# gui/Makefile — build, bundle, sign, run.
#
# There is no Xcode on this machine, so nothing here is automatic: SwiftPM
# produces a bare Mach-O executable and the .app around it is assembled by
# hand. `make run` is the dev loop that stands in for previews.
#
#   make            build + bundle + sign
#   make run        …and launch the bundle
#   make identity   create the stable signing identity (once, interactive)
#   make install    copy the bundle to /Applications
#   make clean

APP           := Hopwatch
BUNDLE_ID     := me.brianfreeman.hopwatch
BUILD_DIR     := build
APP_DIR       := $(BUILD_DIR)/$(APP).app
CONFIG        := release
BIN           := .build/$(CONFIG)/HopwatchGUI
CLI_DIR       := $(APP_DIR)/Contents/Resources/cli

# The single source of truth for the shipped version is the CLI's own
# HOPWATCH_VERSION (../bin/hopwatch)
VERSION       := $(shell sed -n 's/^HOPWATCH_VERSION="\([^"]*\)".*/\1/p' ../bin/hopwatch 2>/dev/null | head -1)
ifeq ($(strip $(VERSION)),)
VERSION       := $(shell sed -n 's/^NETDIAG_VERSION="\([^"]*\)".*/\1/p' ../bin/hopwatch 2>/dev/null | head -1)
endif

# ── Signing ─────────────────────────────────────────────────────────────
# TCC keys its grants on bundle id *and* code signature. `codesign -s -`
# produces an ad-hoc signature whose cdhash changes on every rebuild, so
# every rebuild would re-prompt — not only for Location, which is optional,
# but for Notifications, which the entire alert engine depends on.
#
# Prefer 'hopwatch-dev' identity, but seamlessly fall back to 'netdiag-dev'
# if present, before falling back to ad-hoc.
IDENTITY_NAME := hopwatch-dev
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
                   | grep -F '"$(IDENTITY_NAME)"' | head -1 | awk '{print $$2}')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
                   | grep -F '"netdiag-dev"' | head -1 | awk '{print $$2}')
endif

.PHONY: all build bundle sign run install clean identity check test dmg

all: sign

build:
	swift build -c $(CONFIG)

CLT_TESTING_FRAMEWORK := /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
CLT_DEVELOPER_USR_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

test:
	@if [ -d "$(CLT_TESTING_FRAMEWORK)" ]; then \
	  swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
	             -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
	             -Xlinker -rpath -Xlinker $(CLT_DEVELOPER_USR_LIB); \
	else \
	  swift test; \
	fi

bundle: build
	@if [ -z "$(VERSION)" ]; then \
	  echo "error: could not read HOPWATCH_VERSION from ../bin/hopwatch" >&2; exit 1; \
	fi
	@pkill -x HopwatchGUI 2>/dev/null || true
	@pkill -x NetdiagGUI 2>/dev/null || true
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@cp "$(BIN)" "$(APP_DIR)/Contents/MacOS/HopwatchGUI"
	@cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(APP_DIR)/Contents/Resources/AppIcon.icns"; fi
	@printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	@mkdir -p "$(CLI_DIR)"
	@cp -R ../bin "$(CLI_DIR)/bin"
	@cp -R ../lib "$(CLI_DIR)/lib"
	@cp -R ../helpers "$(CLI_DIR)/helpers"
	@find "$(CLI_DIR)" \( -name '.DS_Store' -o -name '*.pyc' \) -delete
	@find "$(CLI_DIR)" -type d -name '__pycache__' -exec rm -rf {} +
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"
	@echo "bundled: $(APP_DIR) (hopwatch $(VERSION))"

sign: bundle
ifeq ($(strip $(SIGN_IDENTITY)),)
	@echo "──────────────────────────────────────────────────────────────"
	@echo "  No '$(IDENTITY_NAME)' or 'netdiag-dev' signing identity found — signing ad-hoc."
	@echo "  Every rebuild will change the code signature, which makes"
	@echo "  macOS forget the Notification and Location grants. Run"
	@echo "  'make identity' once to fix that permanently."
	@echo "──────────────────────────────────────────────────────────────"
	@codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"
else
	@codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" \
	          --options runtime --timestamp=none "$(APP_DIR)"
	@echo "signed with stable identity $(SIGN_IDENTITY)"
endif
	@codesign --verify --verbose=1 "$(APP_DIR)" 2>&1 | sed 's/^/  /'

run: sign
	@pkill -x HopwatchGUI 2>/dev/null || true
	@pkill -x NetdiagGUI 2>/dev/null || true
	open "$(APP_DIR)"
	@echo "launched. logs: log stream --predicate 'subsystem == \"$(BUNDLE_ID)\"'"

install: sign
	@pkill -x HopwatchGUI 2>/dev/null || true
	@pkill -x NetdiagGUI 2>/dev/null || true
	@rm -rf "/Applications/$(APP).app"
	@rm -rf "/Applications/Netdiag.app"
	@cp -R "$(APP_DIR)" /Applications/
	@echo "installed: /Applications/$(APP).app"

identity:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -qF '"$(IDENTITY_NAME)"'; then \
	  echo "identity '$(IDENTITY_NAME)' already exists — nothing to do."; \
	else \
	  set -e; \
	  tmp="$$(mktemp -d)"; \
	  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	    -keyout "$$tmp/key.pem" -out "$$tmp/cert.pem" \
	    -subj "/CN=$(IDENTITY_NAME)" \
	    -addext "basicConstraints=critical,CA:false" \
	    -addext "keyUsage=critical,digitalSignature" \
	    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	  openssl pkcs12 -export -legacy -out "$$tmp/id.p12" \
	    -inkey "$$tmp/key.pem" -in "$$tmp/cert.pem" -passout pass: 2>/dev/null; \
	  security import "$$tmp/id.p12" -k "$$HOME/Library/Keychains/login.keychain-db" \
	    -P "" -T /usr/bin/codesign -A; \
	  echo; \
	  echo "Imported. macOS will now ask you to authorise trusting it for"; \
	  echo "code signing — this is the step that keeps your Notification"; \
	  echo "and Location grants alive across rebuilds."; \
	  security add-trusted-cert -r trustRoot -p codeSign \
	    -k "$$HOME/Library/Keychains/login.keychain-db" "$$tmp/cert.pem"; \
	  rm -rf "$$tmp"; \
	  echo "done — re-run 'make' and the bundle will be signed stably."; \
	fi

check:
	@echo "swift:     $$(swift --version 2>&1 | head -1)"
	@echo "identity:  $(if $(SIGN_IDENTITY),$(SIGN_IDENTITY),<none — will sign ad-hoc>)"
	@echo "cli source: ../bin/hopwatch ($(VERSION))"
	@printf 'bundled:   '; \
	  cli="$(CLI_DIR)/bin/hopwatch"; \
	  if [ -x "$$cli" ]; then \
	    echo "$$cli ($$("$$cli" --version 2>/dev/null))"; \
	  else \
	    echo "<not bundled yet — run 'make bundle'>"; \
	  fi

DMG_NAME := Hopwatch-$(VERSION).dmg
DMG_PATH := $(BUILD_DIR)/$(DMG_NAME)
ZIP_NAME := Hopwatch-$(VERSION).zip
ZIP_PATH := $(BUILD_DIR)/$(ZIP_NAME)

dmg: sign
	@if [ -z "$(VERSION)" ]; then \
	  echo "error: could not read HOPWATCH_VERSION from ../bin/hopwatch" >&2; exit 1; \
	fi
	@echo "building DMG: $(DMG_PATH)"
	@rm -f "$(DMG_PATH)"
	@mkdir -p "$(BUILD_DIR)/dmg"
	@rm -rf "$(BUILD_DIR)/dmg/"*
	@cp -R "$(APP_DIR)" "$(BUILD_DIR)/dmg/"
	@ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	@hdiutil create -volname "$(APP)" -srcfolder "$(BUILD_DIR)/dmg" \
	  -ov -format UDZO "$(DMG_PATH)"
	@rm -rf "$(BUILD_DIR)/dmg"
	@echo "built: $(DMG_PATH)"
	@echo "packaging ZIP: $(ZIP_PATH)"
	@ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP_PATH)"
	@echo "built: $(ZIP_PATH)"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"

