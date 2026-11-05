SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)
export SWIFT_MODULECACHE_PATH := $(CURDIR)/.build/module-cache/swift
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/module-cache/clang
export MACOSX_DEPLOYMENT_TARGET := 15.0
export RELEASE_TAG

.PHONY: prepare-source help build build-dev build-signed build-dev-signed release-plan release-build release-publish icon test test-dev test-channel-bundles test-build-policies test-ssh app app-dev app-preview verify-app verify-bundle verify-dev verify-preview run run-dev fetch-kit fetch-runtime-kit patched-kit test-upstream layout-preview verify-layout-preview prerelease signed-prerelease
help:
	@echo 'make prepare-source | test | test-dev | test-build-policies | test-factories | test-ssh | build | build-dev | build-signed | icon | fetch-kit | fetch-runtime-kit | patched-kit | app | app-dev | verify-app | verify-bundle | verify-dev | prerelease | signed-prerelease RELEASE_TAG=vVERSION-dev.N | layout-preview | verify-layout-preview | run | run-dev | test-upstream'

prepare-source:
	python3 Scripts/prepare_runtime_source.py

build: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build --disable-sandbox

build-signed: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build --disable-sandbox -c release -Xswiftc -DSIGNED_PRERELEASE

build-dev-signed: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build --disable-sandbox -c release --scratch-path .build/dev -Xswiftc -DSIGNED_PRERELEASE -Xswiftc -DDEVELOPMENT_CHANNEL

build-dev: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build --disable-sandbox --scratch-path .build/dev -Xswiftc -DDEVELOPMENT_CHANNEL

test-dev: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test --disable-sandbox --scratch-path .build/dev -Xswiftc -DDEVELOPMENT_CHANNEL --no-parallel

test: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	# Run cases serially: synchronous gate fixtures can exhaust small cooperative pools.
	# Each lifecycle test still exercises its own concurrent tasks and sessions.
	swift test --disable-sandbox --no-parallel
	python3 -m unittest discover -s Tests/ScriptTests -v

test-build-policies: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test --disable-sandbox -c release --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy'
	swift test --disable-sandbox -c release -Xswiftc -DSIGNED_PRERELEASE --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy'
	swift test --disable-sandbox -c release --scratch-path .build/dev -Xswiftc -DSIGNED_PRERELEASE -Xswiftc -DDEVELOPMENT_CHANNEL --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy'

fetch-kit:
	Scripts/fetch-try-omarchy-kit.sh

fetch-runtime-kit:
	python3 Scripts/fetch_runtime_kit.py

patched-kit:
	Scripts/build-patched-try-omarchy-kit.sh $(if $(REUSE_GUEST_PACKAGE_KIT),--reuse-guest-package-from "$(REUSE_GUEST_PACKAGE_KIT)") $(if $(REVIEWED_GUEST_PACKAGE),--reviewed-guest-package "$(REVIEWED_GUEST_PACKAGE)") $(if $(REVIEWED_LEAN_GUEST_PACKAGE),--reviewed-lean-guest-package "$(REVIEWED_LEAN_GUEST_PACKAGE)")

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

release-plan:
	python3 Scripts/branch_release.py plan

release-build: fetch-runtime-kit prepare-source icon
	python3 Scripts/branch_release.py build

release-publish:
	python3 Scripts/branch_release.py publish

run: verify-app
	open "dist/Omarchy VM Manager.app"

test-ssh:
	python3 Scripts/test_managed_ssh.py

# Explicit opt-in only: the approval file identifies a private disposable run.
test-home-disks: prepare-source
	@test -n "$$OMARCHY_HOME_DISK_ACCEPTANCE" || { echo 'Set OMARCHY_HOME_DISK_ACCEPTANCE to an explicitly approved disposable-run approval.json'; exit 1; }
	bash Scripts/test_home_mount_propagation.sh
	swift test --disable-sandbox --no-parallel --filter approvedSeparateHomeAcceptance

icon:
	python3 Scripts/build_icon.py

app-dev: build-dev icon
	Scripts/build-app.sh --dev

app-preview: app-dev

verify-dev:
	Scripts/verify-app.sh --bundle-only "$(CURDIR)/dist/Omarchy VM Manager Dev.app"

verify-preview: verify-dev

test-channel-bundles:
	python3 Scripts/test_channel_bundles.py "$(CURDIR)/dist/Omarchy VM Manager.app" "$(CURDIR)/dist/Omarchy VM Manager Dev.app"

run-dev: verify-dev
	open "dist/Omarchy VM Manager Dev.app"

layout-preview: build icon
	Scripts/build-app.sh --layout-preview

verify-layout-preview:
	Scripts/verify-app.sh "$(CURDIR)/dist/Omarchy VM Manager Layout Preview.app"

.PHONY: test-factories
test-factories: prepare-source
	Scripts/upstream-make.sh test-shell-run-mode
