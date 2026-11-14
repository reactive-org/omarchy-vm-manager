@AGENTS.md

<!-- claude-code-stack-profile -->
## Running this stack with Claude Code

- Swift tests use Swift Testing (`import Testing`). Run one suite inline with the Makefile's flags, after `make build`: `SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache/swift" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache/clang" MACOSX_DEPLOYMENT_TARGET=15.0 swift test --disable-sandbox --skip-update --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-configuration" --security-path "$PWD/.build/swiftpm-security" --no-parallel --filter GuestReclaimTests`. Add `--skip-build` to re-run without recompiling; `--list-tests` prints suite ids.
- Keep `--no-parallel`: synchronous gate fixtures can exhaust small cooperative pools.
- `make test`, `make test-dev`, `make test-build-policies` and `make test-upstream TEST_JOBS=1` are slow (cold builds take many minutes; CI allows 50). Run them with `run_in_background: true`, log, and read back only the result: `make test > .build/test.log 2>&1`, then `grep -nE 'error:|✘|FAILED|failed|Test run with' .build/test.log | tail -40`.
- Script tests are fast; run the one that covers a change inline: `python3 -m unittest discover -s Tests/ScriptTests -p 'test_<x>.py' -v`.
- A fresh worktree needs `git submodule update --init Vendor/try-omarchy` before `make prepare-source`; cold `make build` / `make build-dev` there take minutes, so background them and wait.
- Never run `make app-dev`, `make app` or anything else that rebuilds a `dist/` bundle while that app has a guest running: it replaces the bundle under the running app and can kill a guest mid-setup. Never run `make test-ssh` (builds a Docker image) or `make test-home-disks` (real guest) without explicit approval.
- A PR that changes what a user sees carries screenshots. Prefer the offscreen renders (`make test-provisioning-screens`, `make test-factory-screens`), which need no installed app or VM. For a capture of the real window, build and open only the Dev candidate (`make app-dev verify-dev`, then `make run-dev`, once no Dev guest is running) and capture the manager window; use the `refresh-screenshots` skill for `docs/media`. Never touch the Stable app.
<!-- /claude-code-stack-profile -->

<!-- doc-catalogue-upkeep -->
## Keeping the doc catalogue current

`docs/README.md` holds a `doc-catalogue` block: one line per document that grounds the
ctrl-freaq's work, as ``- `<path>` — <role> — <binding | informative> — <summary>``. When a
change adds, moves, removes, or materially rewrites one of those documents, or adds a document that
should ground the work, update the block in the same change:

- Add, remove, or fix entries, and reword a summary that no longer describes its document, without
  asking.
- Ask before adding an entry as `binding`, changing any entry's authority, or removing or
  repointing a `binding` entry. A conflict with a `binding` document blocks the work, so these
  change what the pipeline enforces.
- Keep every line in that format, between the markers. A line that does not parse is skipped, and
  its document silently stops grounding anything.
<!-- /doc-catalogue-upkeep -->
