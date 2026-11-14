<!-- ctrl-freaq-config -->
Pipeline configuration for the `ctrl-freaq` skills (resolver / evaluator / planner), read at use-time. You can edit these blocks by hand — just keep each block's `<!-- … -->` marker pair intact so the skills can find it. Re-run `/ctrl-freaq:setup` to reconcile them (idempotent).
<!-- /ctrl-freaq-config -->

<!-- issue-resolver-fast-checks -->
- `make prepare-source` — Verify the pinned upstream source and regenerate the review and package pins (seconds)
- `make build` — Compile the app, CLI, helpers and provisioning launcher (Swift 6 type check; incremental, minutes when cold)
- `make build-dev` — Compile the isolated Dev channel (`DEVELOPMENT_CHANNEL`) build (incremental, minutes when cold)
<!-- /issue-resolver-fast-checks -->

<!-- issue-resolver-test-target -->
- wrapper: `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache/swift" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache/clang" MACOSX_DEPLOYMENT_TARGET=15.0 swift test --disable-sandbox --skip-update --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-configuration" --security-path "$PWD/.build/swiftpm-security" --no-parallel`
- targets:
  - `OmarchyVMManagerCoreTests` (unit)
    - naming: Swift Testing suites. Source `Sources/<Module>/<X>.swift` ↔ `Tests/OmarchyVMManagerCoreTests/<X>Tests.swift` declaring `struct <X>Tests`; suite id `<X>Tests`, run as the wrapper plus `--filter <X>Tests` (several suites: `--filter '<A>Tests|<B>Tests'`). App views in `Sources/OmarchyVMManagerApp/` have no unit suites: map them by the Core types they call. Run `make build` first.
    - helpers-fallback: `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache/swift" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache/clang" MACOSX_DEPLOYMENT_TARGET=15.0 swift test --disable-sandbox --skip-update --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-configuration" --security-path "$PWD/.build/swiftpm-security" --no-parallel`
    - broad-change-fallback: `make test`
  - `ScriptTests` (unit)
    - naming: `Scripts/<x>.py` ↔ `Tests/ScriptTests/test_<x>.py`; run `python3 -m unittest discover -s Tests/ScriptTests -p 'test_<x>.py' -v`.
    - helpers-fallback: `python3 -m unittest discover -s Tests/ScriptTests -v`
    - broad-change-fallback: `python3 -m unittest discover -s Tests/ScriptTests -v`
  - `Screen acceptance` (UI)
    - naming: offscreen SwiftUI renders with fake controllers, no installed app or VM. Setup, selection and provisioning views (`Setup*`, `Provisioning*View`) ↔ `make test-provisioning-screens` (`Scripts/test_setup_screens.py`); factory views (`Factory*`) ↔ `make test-factory-screens` (`Scripts/test_factory_screens.py`, Dev build).
    - helpers-fallback: `make test-provisioning-screens test-factory-screens`
    - broad-change-fallback: none
<!-- /issue-resolver-test-target -->

<!-- issue-resolver-canonical-suite -->
- full-suite: `make test && make test-dev test-provisioning-bundle-dev test-factory-screens && make test-build-policies && make build && make icon && make test-upstream TEST_JOBS=1`
- build-once: `make build build-dev`
- retry-without-rebuild: `make test && make test-dev test-provisioning-bundle-dev test-factory-screens && make test-build-policies && make build && make icon && make test-upstream TEST_JOBS=1`
<!-- /issue-resolver-canonical-suite -->

<!-- pr-evaluator-static-checks -->
- `make prepare-source` — Verify the pinned upstream source and regenerate the review and package pins (seconds)
- `make build` — Compile the app, CLI, helpers and provisioning launcher (Swift 6 type check; incremental, minutes when cold)
- `make build-dev` — Compile the isolated Dev channel (`DEVELOPMENT_CHANNEL`) build (incremental, minutes when cold)
<!-- /pr-evaluator-static-checks -->

<!-- pr-evaluator-test-target -->
- wrapper: `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache/swift" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache/clang" MACOSX_DEPLOYMENT_TARGET=15.0 swift test --disable-sandbox --skip-update --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-configuration" --security-path "$PWD/.build/swiftpm-security" --no-parallel`
- full-suite-command: `make test && make test-dev test-provisioning-bundle-dev test-factory-screens && make test-build-policies && make build && make icon && make test-upstream TEST_JOBS=1`
- targets:
  - `OmarchyVMManagerCoreTests` (unit)
    - naming: Swift Testing suites. Source `Sources/<Module>/<X>.swift` ↔ `Tests/OmarchyVMManagerCoreTests/<X>Tests.swift` declaring `struct <X>Tests`; suite id `<X>Tests`, run as the wrapper plus `--filter <X>Tests` (several suites: `--filter '<A>Tests|<B>Tests'`). App views in `Sources/OmarchyVMManagerApp/` have no unit suites: map them by the Core types they call. Run `make build` first.
    - helpers-fallback: `env SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache/swift" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache/clang" MACOSX_DEPLOYMENT_TARGET=15.0 swift test --disable-sandbox --skip-update --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-configuration" --security-path "$PWD/.build/swiftpm-security" --no-parallel`
    - broad-change-fallback: `make test`
  - `ScriptTests` (unit)
    - naming: `Scripts/<x>.py` ↔ `Tests/ScriptTests/test_<x>.py`; run `python3 -m unittest discover -s Tests/ScriptTests -p 'test_<x>.py' -v`.
    - helpers-fallback: `python3 -m unittest discover -s Tests/ScriptTests -v`
    - broad-change-fallback: `python3 -m unittest discover -s Tests/ScriptTests -v`
  - `Screen acceptance` (UI)
    - naming: offscreen SwiftUI renders with fake controllers, no installed app or VM. Setup, selection and provisioning views (`Setup*`, `Provisioning*View`) ↔ `make test-provisioning-screens` (`Scripts/test_setup_screens.py`); factory views (`Factory*`) ↔ `make test-factory-screens` (`Scripts/test_factory_screens.py`, Dev build).
    - helpers-fallback: `make test-provisioning-screens test-factory-screens`
    - broad-change-fallback: none
<!-- /pr-evaluator-test-target -->

<!-- pr-evaluator-escalation-labels -->
- `full-suite-required` — bypass targeted selection and run the CI test job chain
<!-- /pr-evaluator-escalation-labels -->

<!-- pr-evaluator-merge-policy -->
- standard: ask
- story: ask
<!-- /pr-evaluator-merge-policy -->

<!-- pr-evaluator-sensitive-paths -->
- `.github/workflows/` — build, test and release-publishing CI (a merge to next or main publishes a release)
<!-- /pr-evaluator-sensitive-paths -->

<!-- ctrl-freaq-rigor -->
- default: full
- floor: medium
<!-- /ctrl-freaq-rigor -->

<!-- worktree-setup -->
- `git submodule update --init Vendor/try-omarchy` — Check out the pinned try-omarchy submodule that `make prepare-source` verifies (idempotent)
<!-- /worktree-setup -->

<!-- worktree-teardown -->
- `git submodule deinit --force --all` — Release submodule checkouts so a plain `git worktree remove` succeeds (idempotent)
<!-- /worktree-teardown -->

<!-- issue-resolver-review-guidance -->
## Review guidance

**What failure looks like here:** (from `AGENTS.md` and `intent.md`) launching, resetting, deleting or modifying a personal or existing user VM, or starting a real guest, without explicit consent — tests must use manager-owned disposable UUID roots only; recursively erasing VM storage instead of moving one verified stopped UUID root to Trash under the runtime-compatible lock; releasing client handles or port and resource reservations before the matching `.exited` (`.error` is diagnostic, not a lifecycle boundary); Dev work touching Stable data, locks, bundle ID or CLI, or a development environment override reaching the production client; accepting unknown, damaged, incompatible or unproven kit provenance, or inferring focus-aware clipboard from protocol 1; logging clipboard contents, credentials, guest secrets or personal machine identifiers; duplicating the upstream VM implementation instead of orchestrating it; enabling production launch; and docs or records that mark something VERIFIED that is still TO PROVE.
**Skip:** `Vendor/` (vendored dev-vm and SwiftTerm sources), `Patches/experiments/`, and build output under `.build/` and `dist/`.
**Nits:** _(for the code owners to fill)_
**Evidence:** _(for the code owners to fill)_

**Recurring findings:**
<!-- /issue-resolver-review-guidance -->
