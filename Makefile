SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)
export SWIFT_MODULECACHE_PATH := $(CURDIR)/.build/module-cache/swift
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/module-cache/clang
export MACOSX_DEPLOYMENT_TARGET := 15.0
export RELEASE_TAG
SWIFT_FLAGS := --disable-sandbox --skip-update --cache-path "$(CURDIR)/.build/swiftpm-cache" --config-path "$(CURDIR)/.build/swiftpm-configuration" --security-path "$(CURDIR)/.build/swiftpm-security"

.PHONY: prepare-source help build build-dev build-signed build-dev-signed release-plan release-build release-publish icon test test-dev test-channel-bundles test-build-policies test-ssh app app-dev app-preview verify-app verify-bundle verify-dev verify-preview run run-dev fetch-kit fetch-runtime-kit patched-kit test-upstream layout-preview verify-layout-preview prerelease signed-prerelease
help:
	@echo 'make prepare-source | test | test-dev | test-provisioning-tools | test-provisioning-terminal | test-provisioning-ui-cli | test-provisioning-review | test-provisioning-actions | test-provisioning-selection | test-provisioning-appearance | test-provisioning-identity | test-provisioning-admission | provisioning-preflight | test-provisioning-preflight | test-private-provisioning-package | test-private-provisioning-signer | test-private-provisioning-inputs | test-private-provisioning-materials | test-private-provisioning-offline | test-private-provisioning-native | test-receipt-bound-signing | private-provisioning-handoff | test-provisioning-screens | test-provisioning-package | test-build-policies | test-factories | test-ssh | build | build-dev | build-signed | build-dev-signed | icon | fetch-kit | fetch-runtime-kit | patched-kit | app | app-dev | verify-dev | verify-app | verify-bundle | prerelease | signed-prerelease RELEASE_TAG=vVERSION-dev.N | app-preview | layout-preview | verify-layout-preview | run | run-dev | test-upstream'

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

build-dev-signed: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build $(SWIFT_FLAGS) -c release --scratch-path .build/dev -Xswiftc -DSIGNED_PRERELEASE -Xswiftc -DDEVELOPMENT_CHANNEL
	swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" -c release --product dev-vm-process-host

build-dev: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build $(SWIFT_FLAGS) --scratch-path .build/dev -Xswiftc -DDEVELOPMENT_CHANNEL
	swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" --product dev-vm-process-host

test-dev: build-dev
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test $(SWIFT_FLAGS) --scratch-path .build/dev -Xswiftc -DDEVELOPMENT_CHANNEL --no-parallel

test: build
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	# Run cases serially: synchronous gate fixtures can exhaust small cooperative pools.
	# Each lifecycle test still exercises its own concurrent tasks and sessions.
	swift test $(SWIFT_FLAGS) --no-parallel
	python3 -m unittest discover -s Tests/ScriptTests -v
	$(MAKE) test-provisioning-bundle
	$(MAKE) test-provisioning-screens

# Deliberately no build, assembly, signing, installed-tool or guest prerequisites.
# Run `make build` separately if the selected build artifacts do not exist.
PROVISIONING_PREFLIGHT_BINARIES ?= $(CURDIR)/.build/debug
PROVISIONING_PREFLIGHT_LAUNCHER_BINARIES ?= $(CURDIR)/.build/provisioning-launcher/debug
.PHONY: provisioning-preflight test-provisioning-preflight
provisioning-preflight:
	@python3 Scripts/provisioning_preflight.py --binaries "$(PROVISIONING_PREFLIGHT_BINARIES)" --launcher-binaries "$(PROVISIONING_PREFLIGHT_LAUNCHER_BINARIES)"

test-provisioning-preflight:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_provisioning_preflight.py' -v
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_provisioning_package.py' -v

# No build, signing, workflow, tool probing or guest prerequisites. All input
# identity values stay in an explicit private file; none are printed by make.
.PHONY: private-provisioning-handoff test-private-provisioning-package
private-provisioning-handoff:
	@python3 Scripts/private_provisioning_package.py prepare --candidate "$(PRIVATE_CANDIDATE)" --output "$(PRIVATE_OUTPUT)" --reviewed-identity "$(PRIVATE_IDENTITY)"

test-private-provisioning-package:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_private_provisioning_package.py' -v

# Source admission and adapter logic use injected fake command runners, without
# build/signing/installed-tool prerequisites or a signing CLI/credential entrypoint.
.PHONY: test-private-provisioning-signer
test-private-provisioning-signer:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_private_provisioning_signer.py' -v

.PHONY: test-private-provisioning-inputs test-private-provisioning-materials test-private-provisioning-offline
test-private-provisioning-inputs:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_private_provisioning_inputs.py' -v

# Synthetic materials and injected inspectors only; no credentials or SDK calls.
test-private-provisioning-materials:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_private_provisioning_materials.py' -v

# Fake Security/CMS APIs, virtual workers and clocks only; no native activation.
test-private-provisioning-offline:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_private_provisioning_offline.py' -v

.PHONY: test-private-provisioning-native
test-private-provisioning-native:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_offline_*bindings.py' -v
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_offline_native_process.py' -v

.PHONY: test-receipt-bound-signing
# Fake process/FFI primitives only; never builds, signs or inspects host materials.
test-receipt-bound-signing:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_receipt_bound_signing.py' -v

.PHONY: test-private-signing-cli
# Disposable public inputs and injected fake workers only; never real signing.
test-private-signing-cli:
	python3 -m unittest discover -s Tests/ScriptTests -p test_private_signing_cli.py -v

.PHONY: test-frozen-provisioning-helper
# Only disposable package fixtures with installed Python/local Git; no SDK/signing.
test-frozen-provisioning-helper:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_frozen_provisioning_helper.py' -v

.PHONY: test-resource-signatures
# Synthetic resource records and disposable files; no SDK/native/signing work.
test-resource-signatures:
	python3 -m unittest discover -s Tests/ScriptTests -p 'test_resource_signatures.py' -v

.PHONY: test-provisioning-package test-provisioning-bundle
test-provisioning-package: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter ProvisioningPackage
	python3 -m unittest discover -s Tests/ScriptTests -p test_provisioning_package.py -v
	$(MAKE) test-provisioning-bundle

test-provisioning-bundle:
	python3 Scripts/test_provisioning_bundle.py --binaries "$$(swift build $(SWIFT_FLAGS) --show-bin-path)" --launcher-binaries "$$(swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" --show-bin-path)"

.PHONY: test-provisioning-bundle-dev
test-provisioning-bundle-dev: build-dev
	python3 Scripts/test_provisioning_bundle.py --binaries "$$(swift build $(SWIFT_FLAGS) --scratch-path .build/dev -Xswiftc -DDEVELOPMENT_CHANNEL --show-bin-path)" --launcher-binaries "$$(swift build $(SWIFT_FLAGS) --package-path .build/provisioning-launcher-source --scratch-path "$(CURDIR)/.build/provisioning-launcher" --show-bin-path)"

test-build-policies: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test $(SWIFT_FLAGS) -c release --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy|compiledProvisioningExecutionPolicy|compiledProvisioningHelperSigningPolicy'
	swift test $(SWIFT_FLAGS) -c release -Xswiftc -DSIGNED_PRERELEASE --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy|compiledProvisioningExecutionPolicy|compiledProvisioningHelperSigningPolicy'
	swift test $(SWIFT_FLAGS) -c release --scratch-path .build/dev -Xswiftc -DSIGNED_PRERELEASE -Xswiftc -DDEVELOPMENT_CHANNEL --filter 'compiledLaunchAdmission|compiledCredentialStoragePolicy|compiledProvisioningExecutionPolicy|compiledProvisioningHelperSigningPolicy'

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

.PHONY: test-provisioning-actions
test-provisioning-actions: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter 'ProvisioningWorkflowAction'

.PHONY: test-provisioning-selection
test-provisioning-selection: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter 'ProvisioningSelection|ProvisioningProfileSelection'

.PHONY: test-provisioning-identity
test-provisioning-identity: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter 'ProvisioningIdentity|ProvisioningPackage|ProvisioningWorkflowAction|ManagedSSH'

.PHONY: test-provisioning-screens
test-provisioning-screens: build
	python3 Scripts/test_setup_screens.py --binary "$$(swift build $(SWIFT_FLAGS) --show-bin-path)/OmarchyVMManager"

.PHONY: test-provisioning-admission
test-provisioning-admission: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter ProvisioningDisposableAdmission

.PHONY: test-provisioning-appearance
test-provisioning-appearance: build
	swift test $(SWIFT_FLAGS) --no-parallel --filter 'ProvisioningSelectionAppearance|ProvisioningThemeNetwork'
