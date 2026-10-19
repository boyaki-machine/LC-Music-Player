.DEFAULT_GOAL := help
# SwiftPM products are shared by these targets, even with make -j.
.NOTPARALLEL:
.PHONY: help release debug archive dmg test ios-build ios-test ios-uitest ios-sim ios-device

PYTHON ?= python3
RELEASE_OUTPUT ?= build/release/LCMP.app
DEBUG_OUTPUT ?= build/debug/LCMP.app
ARCHIVE ?= build/dist/LCMP.zip
DMG_OUTPUT ?=
DMG_APP ?=
# iPhone app (iOS/LCMPiOS.xcodeproj). Signing values come from iOS/Local.xcconfig.
IOS_CONFIGURATION ?= Debug
IOS_SIMULATOR ?= iPhone 18 Pro Max
IOS_DEVICE ?=
IOS_XCODEBUILD = xcodebuild -project iOS/LCMPiOS.xcodeproj -scheme LCMPiOS -configuration $(IOS_CONFIGURATION)
IOS_SIM_APP = build/ios/app/Build/Products/$(IOS_CONFIGURATION)-iphonesimulator/LCMP.app
IOS_DEVICE_APP = build/ios/device/Build/Products/$(IOS_CONFIGURATION)-iphoneos/LCMP.app

help:
	@printf '%s\n' 'make release  Release app: $(RELEASE_OUTPUT)' \
	  'make debug    Debug app: $(DEBUG_OUTPUT)' \
	  'make archive  Build Release and ZIP: $(ARCHIVE)' \
	  'make dmg      Installer DMG of a release app built for distribution: build/dmg/LCMP-<version>.dmg' \
	  'make test     Tests without audio output' \
	  'make ios-build   iPhone app for the simulator (unsigned): $(IOS_SIM_APP)' \
	  'make ios-test    Shared-module tests on the iOS simulator' \
	  'make ios-uitest  Touch tests of the iPhone app on the simulator' \
	  'make ios-sim     Build, install and launch on the simulator' \
	  'make ios-device  Build, sign, install and launch on a connected iPhone' \
	  'Overrides: PYTHON, RELEASE_OUTPUT, DEBUG_OUTPUT, ARCHIVE, DMG_OUTPUT, DMG_APP,' \
	  '           IOS_CONFIGURATION, IOS_SIMULATOR, IOS_DEVICE'

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

dmg:
	$(PYTHON) scripts/build-dmg.py $(if $(DMG_OUTPUT),--output "$(DMG_OUTPUT)",) $(if $(DMG_APP),--app "$(DMG_APP)",)

test:
	$(PYTHON) scripts/test_acknowledgements.py
	$(PYTHON) scripts/test_app_version.py
	$(PYTHON) scripts/test_app_icon.py
	$(PYTHON) scripts/test_build_dmg.py
	$(PYTHON) scripts/test_ios_resources.py
	@# Tests must not leave UserDefaults suite plists behind.
	@set -eu; \
	  count() { find "$$HOME/Library/Preferences" -maxdepth 1 -name 'lcmp-*.plist' 2>/dev/null | wc -l | tr -d ' '; }; \
	  before=$$(count); \
	  LCMP_TEST_AUDIO_OUTPUT=0 ./scripts/swift.sh test --no-parallel; \
	  after=$$(count); \
	  if [ "$$after" -gt "$$before" ]; then \
	    printf 'Tests left %s new lcmp-*.plist file(s) in ~/Library/Preferences.\n' "$$((after - before))" >&2; exit 1; \
	  fi

ios-build:
	$(IOS_XCODEBUILD) -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios/app build

ios-test:
	xcodebuild test -scheme LCMP-Package -destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' -derivedDataPath build/ios/package

ios-uitest:
	$(IOS_XCODEBUILD) -destination 'platform=iOS Simulator,name=$(IOS_SIMULATOR)' -derivedDataPath build/ios/uitest test

ios-sim: ios-build
	xcrun simctl boot "$(IOS_SIMULATOR)" 2>/dev/null || true
	@# Xcode 27 shows simulators in Device Hub; earlier Xcode versions have Simulator.app.
	open -a Simulator 2>/dev/null || open -b com.apple.dt.Devices 2>/dev/null || true
	xcrun simctl install "$(IOS_SIMULATOR)" "$(IOS_SIM_APP)"
	xcrun simctl launch "$(IOS_SIMULATOR)" "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(IOS_SIM_APP)/Info.plist")"

ios-device:
	@test -f iOS/Local.xcconfig || { printf '%s\n' 'Create iOS/Local.xcconfig with DEVELOPMENT_TEAM and LCMP_BUNDLE_PREFIX (see IPHONE_DEVELOPMENT.md).' >&2; exit 1; }
	@grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*$$' iOS/Local.xcconfig || { printf '%s\n' 'DEVELOPMENT_TEAM in iOS/Local.xcconfig must be the 10-character team ID, not an e-mail address or a name.' >&2; exit 1; }
	@# Building for the connected iPhone lets Xcode register it with the team for the provisioning profile.
	udid=$$($(PYTHON) scripts/ios_install.py udid "$(IOS_DEVICE)") && \
	  $(IOS_XCODEBUILD) -destination "platform=iOS,id=$$udid" -derivedDataPath build/ios/device \
	    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
	$(PYTHON) scripts/ios_install.py install "$(IOS_DEVICE_APP)" "$(IOS_DEVICE)"
