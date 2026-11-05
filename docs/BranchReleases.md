# Stable and Dev releases from branches

**DESIGN DECISION — 5 November 2026:** a push to `main` publishes the stable app; a push to `next` publishes the isolated Dev app. Both wait for the macOS build/tests/upstream contracts and isolated SSH job on that exact commit. Pull requests and other branches run checks without release credentials or publication permission. Manual tag pushes no longer publish apps.

| Branch | App | Tag | GitHub release |
| --- | --- | --- | --- |
| `main` | Omarchy VM Manager, `dev.omarchy.vm-manager` | `v0.11.1`, `v0.11.2`, … | Stable; highest stable version becomes Latest |
| `next` | Omarchy VM Manager Dev, `dev.omarchy.vm-manager.dev` | `v0.11.1-dev.1`, `v0.11.1-dev.2`, … | Prerelease; never Latest |

The Dev app also has its own CLI, purple icon, VM roots, registry, settings, credentials and factories, as described in [Development channels](DevelopmentChannels.md). Release publication never installs an app, opens a manager, requests permissions or starts/stops a guest on a user's Mac. Installation remains manual.

## Versions and exact source

`Scripts/branch_release.py` reserves an annotated tag against `GITHUB_SHA`, after checking the checkout matches the tested push. A single repository-wide publication queue covers both channels and runtime dependencies, with cancellation disabled and pending jobs queued. An older push that reaches the queue after a newer descendant has reserved a version is skipped. GitHub queue order can differ from push order; this check prevents allocating a higher version to older code.

Stable increments the highest regular `vMAJOR.MINOR.PATCH` tag's patch number, using `App/Info.plist` as a minimum baseline. With the current baseline `0.11.0` and no regular stable tags, the first stable release is `v0.11.1`. Reserved tags count even if a release failed; gaps are possible. To deliberately begin a higher major/minor line, update the plist baseline in a reviewed change. No version-bump commits or force pushes are generated.

Dev uses the upcoming stable base and increments its `dev.N` sequence. After stable `v0.11.1` is reserved, new Dev commits begin `v0.11.2-dev.1`. Retrying the same channel/commit reuses its reserved tag, version and original build number; it never consumes another version. `CFBundleShortVersionString`, `CFBundleVersion` (the reserved workflow run number) and `OmarchyReleaseTag` are set in the staged app before signing. The committed plist is unchanged.

## Signing, runtime continuity and publication

Both channels use the existing optimized `SIGNED_PRERELEASE` admission mode for the private runtime; Dev additionally compiles `DEVELOPMENT_CHANNEL`. Calling the everyday app stable does not make its runtime an official upstream kit. Ordinary unapproved release builds still reject that kit.

The complete source runtime is fetched only from its digest-pinned dependency release. A source-compatible active signed lock may be reused. Otherwise the branch pipeline looks for `signed-runtime-<source-lock SHA-256>` and validates its source, team, capabilities, payload inventory and notarization. If absent, it signs/notarizes through the existing upstream pipeline and publishes that verified runtime dependency. Historical signed locks remain unchanged. Later app-only commits and both channels reuse those exact signed runtime bytes, preserving factory compatibility across app releases on the same runtime. Changing runtime provenance still requires separately compatible factories; packaging does not migrate or rewrite existing data.

The app must pass profile/certificate/team/entitlement checks, exact runtime provenance, Apple acceptance bound to its submitted archive, stapling, Gatekeeper and extracted-ZIP verification. Publication independently checks the restored source receipt, tag reservation, channel/version/build, runtime lock/archive and app again. Assets upload to a draft and their server SHA-256 digests must match before it becomes public. Existing assets are never clobbered. Stable's archive prefix is `Omarchy-VM-Manager-`; Dev's is `Omarchy-VM-Manager-Dev-`.

Manual update checks offer only notarized downloads for the app's own channel. The historical everyday app with a `-dev.N` tag can move to a newer regular stable release. Runtime-only releases, drafts, incomplete assets and the other app's releases are ignored. Checks never install anything automatically.

## One-time setup before enabling publication

1. **VERIFIED — published 5 November 2026:** the exact reviewed `TryOmarchyKit.zip`, SHA-256 `5b30b9b3a82a80eac5c32e96302a8abe5d8a50c9a05853b876f0603a63839839`, is available at the [digest-named source-kit dependency](https://github.com/reactive-org/omarchy-vm-manager/releases/tag/runtime-kit-5b30b9b3a82a80eac5c32e96302a8abe5d8a50c9a05853b876f0603a63839839). Server digests/sizes and anonymous downloaded bytes match all four originals (ZIP, checksum, manifest and source lock); the downloaded archive inventory/manifest pass. No rebuild or re-pin occurred. Future source-kit changes require publication of their exact reviewed archive. Dependencies contain no factory image or VM data and never become Latest.
2. Retain the existing stable signing/notarization secrets and `MACOS_KEYCHAIN_PROFILE_BASE64`. Create a separate macOS Developer ID profile for `dev.omarchy.vm-manager.dev` authorizing the same signing certificate. Review its App ID/team/scope/expiry, set its SHA-256 in `Config/TouchIDDevProfile.lock.json`, and supply its base64 bytes as `MACOS_DEV_KEYCHAIN_PROFILE_BASE64`. The current null digest deliberately refuses Dev publication before tag reservation; there is no stable-profile fallback. The user chose to supply this profile later.
3. Merge the workflow PR into `main`. Once the source dependency is available, its successful push checks can publish stable. Create `next` from a commit containing this workflow when ready to start Dev publication. Changes reach stable by merging reviewed work into `main`; merging `main` into `next` keeps Dev current. Protect both branches with the checks required by your repository policy. Repository token permission/rules must allow the release job to create tags/releases.

Secrets are injected only into the conditional signing step of the trusted branch-push job. The temporary CI keychain/profile/API files are cleaned up. PR checks have read-only permissions and no signing secrets. No real credential or provisioning operation is needed to test the release scripts locally.

## Failures and retained artifacts

Drafts are resolved through the authenticated paginated release listing when GitHub's by-tag endpoint returns 404. Ambiguous matches fail closed; the publisher does not create a duplicate draft or bypass asset verification. This behavior was confirmed during the first source-kit upload and covered by create/upload/verify/finalize regression fixtures.

The run retains the plan, source receipts, original Apple-submitted archives, Apple JSON and final artifacts for seven days, including on failure. Download evidence before expiry when investigating a failed notarization or publication.

A fully published commit is skipped on retry. A draft with partial assets is preserved; the build refuses to generate replacement signed bytes. Restore the **exact verified** retained `dist/prerelease/` and matching `.build/branch-release.json` in an authorized push-run continuation of that exact commit, then use `make release-publish`. Publication verifies the reservation and all app/source/runtime gates again, compares existing assets and uploads only missing bytes. There is no generic one-click recovery workflow in this PR. Apple timeouts may require the existing accepted-submission/retained-candidate procedures; a normal fresh rerun is not a promise of automatic notarization continuation. Do not delete reservations or overwrite drafts to bypass these checks.

**TO PROVE:** first real `main`/`next` publication, Dev's new provisioned signature, live queued/retried publication, Apple timing and native behavior of newly distributed apps. No-VM script/build tests cannot establish those outcomes. No installed app, running work VM, personal configuration, permission or local signing credential is changed by this implementation.

## No-VM verification — 5 November 2026

**VERIFIED:** `make test test-dev build build-dev test-build-policies build-dev-signed` passes 256 Swift tests in each channel, both debug builds, all three optimized launch/credential policy configurations (ordinary stable, signed stable, signed Dev), and the complete optimized signed Dev executable build. The final script suite passes 99 tests, including 13 branch-publication fixtures for trusted push context, patch/Dev numbering, immutable reservations, out-of-order pushes, missing provisioning, exact-byte upload/retry, draft finalization and refusal after extracted-app verification failure. Synthetic test keys/certificates do not use the real signing identity or saved credentials.

Isolated ad-hoc assemblies under `.build/branch-release-verification/` verify generated stable `v0.11.1` / build `101` and Dev `v0.11.1-dev.1` / build `102`, both with short version `0.11.1`. These are packaging fixtures, not reserved/published versions. Both pass bundle-only diagnostics, exact runtime/layout inventory, all 22 runtime Mach-O signatures, macOS compatibility, manager/CLI/helper channel agreement and mismatched-channel refusal. Diagnostics report `hostPreflightPerformed: false` and `vmLaunchEnabled: false`. The initial bundle-check invocation used a relative path and was refused by the existing compatibility verifier; rerunning with absolute paths passes. Workflow YAML parses and `git diff --check` passes.

The first script run inside the restricted sandbox could not inspect its disposable compressor process with `ps`; the final suite with fixture execution access passes. One legacy tag fixture was updated to admit the new regular stable tags. No production guard was relaxed to address either test condition. Validation logs are retained locally under `/tmp/omarchy-branch-release-*.log`; no installed app, existing VM, configuration, permission or real signing credential was touched.
