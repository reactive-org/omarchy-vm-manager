SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)
export SWIFT_MODULECACHE_PATH := $(CURDIR)/.build/module-cache/swift
export CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/module-cache/clang
export MACOSX_DEPLOYMENT_TARGET := 15.0

.PHONY: prepare-source help build icon test test-ssh app app-preview verify-app verify-preview run fetch-kit patched-kit test-upstream layout-preview verify-layout-preview
help:
	@echo 'make prepare-source | test | test-factories | test-ssh | build | icon | fetch-kit | patched-kit | app | verify-app | app-preview | layout-preview | verify-layout-preview | run | test-upstream'

prepare-source:
	python3 Scripts/prepare_runtime_source.py

build: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift build --disable-sandbox

test: prepare-source
	@mkdir -p "$(SWIFT_MODULECACHE_PATH)" "$(CLANG_MODULE_CACHE_PATH)"
	swift test --disable-sandbox
	python3 -m unittest discover -s Tests/ScriptTests -v

fetch-kit:
	Scripts/fetch-try-omarchy-kit.sh

patched-kit:
	Scripts/build-patched-try-omarchy-kit.sh

test-upstream:
	Scripts/upstream-make.sh test

app: build icon
	Scripts/build-app.sh

verify-app:
	Scripts/verify-app.sh

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
