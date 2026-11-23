PROJECT := macos/AgentLounge.xcodeproj
SCHEME  := AgentLounge
DERIVED := build/DerivedData
APP     := $(DERIVED)/Build/Products/Debug/Agent Lounge.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Agent Lounge.app
INSTALL_DIR ?= /Applications

# Optional, git-ignored. Stable signing keeps Accessibility / Automation permissions across builds:
#   SIGN_IDENTITY := <SHA-1 from `security find-identity -v -p codesigning`>
#   SIGN_TEAM     := <team id (OU) of that certificate>
-include local.mk
SIGNING := $(if $(SIGN_IDENTITY),CODE_SIGN_IDENTITY=$(SIGN_IDENTITY) DEVELOPMENT_TEAM=$(SIGN_TEAM) CODE_SIGN_STYLE=Manual,)

# Optional version override, e.g. `make dmg VERSION=1.2.0` (CI sets it from the git tag).
VERSION ?=
BUILD_NUMBER ?=
VERSIONING := $(if $(VERSION),MARKETING_VERSION=$(VERSION),) $(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION=$(BUILD_NUMBER),)

XCODEBUILD_BASE := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' -quiet $(SIGNING) $(VERSIONING)
XCODEBUILD := $(XCODEBUILD_BASE) -configuration Debug

.PHONY: check-tools project build test run release dmg install dev-hooks icon clean

# Xcode and XcodeGen are there. Prints what to install if not.
check-tools:
	@sh scripts/check-tools.sh

project: check-tools
	@xcodegen generate --quiet --spec macos/project.yml --project macos

build: project
	@$(XCODEBUILD) build

# Prints only the summary and failures.
test: project
	@set -o pipefail; $(subst -quiet,,$(XCODEBUILD)) test 2>&1 | grep -E "Test run with|✘|\.swift:[0-9]+:[0-9]+: error:|xcodebuild: error:"

run: build
	@sh scripts/quit-app.sh
	@sh scripts/open-app.sh "$(APP)"

# Optimized build in build/DerivedData/Build/Products/Release.
release: project
	@$(XCODEBUILD_BASE) -configuration Release build

# Release app packed in build/Agent-Lounge[-$(VERSION)].dmg.
dmg: release
	@scripts/make-dmg.sh "$(RELEASE_APP)" "build/Agent-Lounge$(if $(VERSION),-$(VERSION),).dmg"

# Copies the Release app to $(INSTALL_DIR) (default /Applications) and starts it.
# Then open Settings > Hooks and click Update: the hooks must point at the installed copy.
install: release
	@sh scripts/quit-app.sh
	@rm -rf "$(INSTALL_DIR)/Agent Lounge.app"
	@ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/Agent Lounge.app"
	@echo "Installed $(INSTALL_DIR)/Agent Lounge.app"
	@sh scripts/open-app.sh "$(INSTALL_DIR)/Agent Lounge.app"

# Renders the app icon PNGs from AppIconView (needs a Debug build).
icon: build
	@scripts/make-icon.sh

# Claude Code settings file with Agent Lounge hooks, for manual tests:
#   claude --settings build/dev/claude-hooks.json
dev-hooks: build
	@scripts/dev-hooks.sh

clean:
	rm -rf build $(PROJECT)
