SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)
export SWIFT_MODULECACHE_PATH := $(CURDIR)/.build/module-cache/swift
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/module-cache/clang
export MACOSX_DEPLOYMENT_TARGET := 15.0
export RELEASE_TAG
SWIFT_FLAGS := --disable-sandbox --skip-update --cache-path "$(CURDIR)/.build/swiftpm-cache" --config-path "$(CURDIR)/.build/swiftpm-configuration" --security-path "$(CURDIR)/.build/swiftpm-security"

.PHONY: prepare-source help build build-signed icon test test-build-policies test-ssh app app-preview verify-app verify-bundle verify-preview run fetch-kit fetch-runtime-kit patched-kit test-upstream layout-preview verify-layout-preview prerelease signed-prerelease
help:
	@echo 'make prepare-source | test | test-provisioning-tools | test-provisioning-terminal | test-provisioning-ui-cli | test-provisioning-review | test-provisioning-package | test-build-policies | test-factories | test-ssh | build | build-signed | icon | fetch-kit | fetch-runtime-kit | patched-kit | app | verify-app | verify-bundle | prerelease | signed-prerelease RELEASE_TAG=vVERSION-dev.N | app-preview | layout-preview | verify-layout-preview | run | test-upstream'

prepare-source:
	python3 Scripts/prepare_runtime_source.py

build: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build $(SWIFT_FLAGS)
	swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" --product dev-vm-process-host

build-signed: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build $(SWIFT_FLAGS) -c release -Xswiftc -DSIGNED_PRERELEASE
	swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" -c release --product dev-vm-process-host

test: build
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	# Run cases serially: synchronous gate fixtures can exhaust small cooperative pools.
	# Each lifecycle test still exercises its own concurrent tasks and sessions.
	swift test $(SWIFT_FLAGS) --no-parallel
	python3 -m unittest discover -s Tests/ScriptTests -v
	$(MAKE) test-provisioning-bundle

.PHONY: test-provisioning-package test-provisioning-bundle
test-provisioning-package: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter ProvisioningPackage
	python3 -m unittest discover -s Tests/ScriptTests -p test_provisioning_package.py -v
	$(MAKE) test-provisioning-bundle

test-provisioning-bundle:
	python3 Scripts/test_provisioning_bundle.py --binaries "$$(swift build $(SWIFT_FLAGS) --show-bin-path)" --launcher-binaries "$$(swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" --show-bin-path)"

test-build-policies: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test $(SWIFT_FLAGS) -c release --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy'
	swift test $(SWIFT_FLAGS) -c release -Xswiftc -DSIGNED_PRERELEASE --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy'

fetch-kit:
	Scripts/fetch-try-omarchy-kit.sh

fetch-runtime-kit:
	python3 Scripts/fetch_runtime_kit.py

patched-kit:
	Scripts/build-patched-try-omarchy-kit.sh

test-upstream:
	Scripts/upstream-make.sh test

app: build icon
	Scripts/build-app.sh

verify-app:
	Scripts/verify-app.sh

verify-bundle:
	Scripts/verify-app.sh --bundle-only

prerelease: build icon
	Scripts/build-app.sh --output-directory "$(CURDIR)/dist/prerelease-staging" --preserve-runtime-signatures
	Scripts/verify-app.sh --bundle-only "$(CURDIR)/dist/prerelease-staging/Omarchy VM Manager.app"
	python3 Scripts/package_prerelease.py

signed-prerelease: fetch-runtime-kit prepare-source icon
	python3 Scripts/signed_prerelease.py

run: verify-app
	open "dist/Omarchy VM Manager.app"

test-ssh:
	python3 Scripts/test_managed_ssh.py

icon:
	python3 Scripts/build_icon.py

app-preview: build icon
	Scripts/build-app.sh --preview

verify-preview:
	Scripts/verify-app.sh "$(CURDIR)/dist/Omarchy VM Manager Preview.app"

layout-preview: build icon
	Scripts/build-app.sh --layout-preview

verify-layout-preview:
	Scripts/verify-app.sh "$(CURDIR)/dist/Omarchy VM Manager Layout Preview.app"

.PHONY: test-factories
test-factories: prepare-source
	Scripts/upstream-make.sh test-shell-run-mode

.PHONY: test-provisioning-tools
test-provisioning-tools: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test $(SWIFT_FLAGS) --no-parallel --filter Provisioning

.PHONY: test-provisioning-terminal
test-provisioning-terminal: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter ProvisioningTerminal

.PHONY: test-provisioning-ui-cli
test-provisioning-ui-cli: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter 'ProvisioningSurface|bundledPresetsPlanOffline'
	python3 -m unittest discover -s Tests/ScriptTests -p test_terminal_vendor.py -v

.PHONY: test-provisioning-review
test-provisioning-review: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter '$(PROVISIONING_REVIEW_FILTER)'
PROVISIONING_REVIEW_FILTER ?= ProvisioningReview|ProvisioningService
