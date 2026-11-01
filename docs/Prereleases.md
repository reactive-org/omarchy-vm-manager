# Development prereleases

GitHub Actions publishes versioned development-fork builds of Omarchy VM Manager for Apple Silicon and macOS 15+. New tagged jobs use the user's explicitly authorized Developer ID and notarization credentials. Publication requires accepted Apple notarization, stapled tickets, exact runtime provenance, code/entitlement verification, Gatekeeper acceptance and verification of the extracted ZIP. Earlier `v0.9.3-dev.3` remains an ad-hoc build. Signing does not establish real-guest behavior or turn this private runtime fork into an official upstream release.

## Publish a build

1. Confirm `App/Info.plist` has the intended app version.
2. Create and push a tag `vVERSION-dev.N`, where VERSION matches `CFBundleShortVersionString` and N is a positive integer. For example, `v0.9.3-dev.1`.
3. CI runs the macOS manager/build/icon/upstream checks and the isolated Ubuntu SSH checks.
4. Only after both jobs pass, the package job prepares or reuses the pinned signed runtime, builds the optimized app with `SIGNED_PRERELEASE`, signs it, submits it to Apple, staples the accepted ticket, and verifies the final ZIP before publishing. It never marks the build as the latest stable release.

The ZIP contains `Omarchy VM Manager.app`, including the CLI, storage helper, runtime, licenses and third-party notices. The release notes record the manager commit and runtime source/archive pins. Only the tagged package job has repository write permission; pull-request jobs remain read-only and cannot publish releases. Existing release assets are not overwritten automatically.

Local packaging uses separate build output and does not open or install an app:

```sh
make fetch-runtime-kit
make prerelease RELEASE_TAG=v0.9.3-dev.1
```

The staged app is under `dist/prerelease-staging/`; the ZIP, checksum and release notes are under `dist/prerelease/`. A pre-existing archive is preserved and must be inspected before packaging the same tag again.

The local commands above remain ad-hoc. `make signed-prerelease` refuses real credentials outside GitHub Actions. The configured secrets are `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and `MACOS_KEYCHAIN_PROFILE_BASE64`. They are injected only into the tagged signing step; temporary keychain/password/key/profile files are removed on exit and never uploaded separately. Tests and pull requests receive none of these credentials. Apple submission status/rejection JSON and the exact candidate archives are retained for seven days on failure, without private credential files. The public provisioning profile is embedded in the signed app, as required by macOS. These diagnostic candidates may still be awaiting notarization and are not published releases.

Signed releases require the validated Touch ID profile pinned in `Config/TouchIDProfile.lock.json`. CI validates its exact digest, App ID, team, macOS Developer ID scope and expiry before importing signing credentials. Assembly/final ZIP checks require manager-only Keychain entitlements, a profile-authorized signing certificate and successful process-level protected-storage entitlement diagnostics. The profile is staged only inside the private runner directory and removed on success/failure. Missing or changed profiles stop the release; ad-hoc builds retain no restricted entitlement. Native Touch ID/password fallback and guest behavior remain separate checks. See [Touch ID](TouchID.md).

Before importing into the older macOS runner, OpenSSL 3 verifies/decrypts the configured PKCS#12 and rewraps the same certificate/private key into a compatible temporary container with a random transfer password. The intermediate PEM is inside the private credential directory and immediately removed. This handles modern Keychain Access export formats without changing the signing identity or bypassing password/integrity checks. A real password/decryption failure stops the job and asks for both certificate and password secrets to be updated.

## Exact runtime dependency

The reviewed runtime archive is hosted as a separate clearly labelled CI dependency prerelease, under tag `runtime-kit-<full kit SHA-256>`. This tag is derived from the committed `Config/TryOmarchyRuntime.lock.json`; it does not mean the stock upstream kit or an arbitrary newly built kit is acceptable.

`make fetch-runtime-kit` checks the compiled lock pin, patch digest, downloaded archive digest, archive paths/types/size, exact per-file inventory, manifest and extracted code signatures. Existing artifacts must also verify; incompatible or damaged artifacts are preserved and refused. No runtime lock or pin is rewritten. A future runtime change requires deliberately publishing its exact reviewed archive under its new digest tag.

Prerelease assembly preserves the kit's existing upstream-pipeline ad-hoc signatures, checks its exact inventory before and after embedding, and runs upstream signature/entitlement verification. Different macOS `codesign` versions can produce different bytes when re-signing the same kit; preserving the verified signatures avoids changing the runtime pin. The manager executables and outer app are signed normally. This applies to ad-hoc development packaging; future Developer ID distribution still needs a deliberately re-signed, reviewed and notarized runtime.

The runtime dependency contains no VM disk, factory image, user registry, credential or guest data. It is fetched only for packaging. No Docker or guest-package rebuild is needed in CI.

## Signed runtime continuity

The first authorized signed job derives a new signed kit from the verified development artifact using upstream `build-kit.sh`: sign the networking payloads, rebuild their pinning daemon from the exact prepared upstream source, then sign all remaining code with the required entitlements, hardened runtime and timestamps. Guest integration, firmware, launch scripts, factory metadata and all other unsigned payloads must remain byte-for-byte identical. Apple must accept the kit before its ticket is stapled and the new archive/inventory recorded.

The job compiles the app against that signed lock and explicit source/team pins in its disposable workspace, restoring the development source pin afterward. Ordinary debug and production release policies remain fail-closed; only the explicit signed-prerelease mode admits the reviewed signed fork. The release includes `TryOmarchySignedKit.zip`, its checksum, `TryOmarchySignedRuntime.lock.json`, the original `SourceRuntime.lock.json`, and Apple acceptance metadata alongside the app ZIP/checksum.

After first-run review, the signed lock is committed separately as `Config/TryOmarchySignedRuntime.lock.json`. Later releases fetch its exact archive from the recorded prerelease and verify source-lock/source-kit continuity, signing team, full inventory and notarization rather than creating fresh signatures each time. The original development lock, compiled development pin and published ad-hoc kit are untouched.

Each Apple submission is polled for up to 45 minutes; status changes and submission IDs appear as CI notices. A pending or rejected submission prevents publication and retains diagnostic JSON. Local preflight passed 160 Swift tests, 30 Python tests, optimized signed-mode compilation without credentials, an ad-hoc package ZIP round trip, and an upstream ad-hoc signing rehearsal that confirmed all unsigned runtime payloads remain unchanged. Actual Developer ID/Apple/Gatekeeper results must be observed on the tagged run.

The initial signed attempts stopped before signing or notarization because the configured certificate/password pair failed both macOS PKCS#12 import and OpenSSL MAC verification. [The `v0.9.3-dev.5` run](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41272350870) passed all 160 manager Swift tests, 31 Python tests and 550 upstream tests. After the user corrected the password, its signing-only retry imported the Developer ID identity, validated the API credentials, signed the runtime and submitted it to Apple (`9600b6bb-4040-473f-868b-b36ec0a55c52`). Apple still reported `In Progress` when the run was deliberately cancelled before publication to correct a remaining debug-only launch guard. No signed release was published by that run.

`make test-build-policies` now runs launch-admission checks in both optimized configurations: ordinary release still refuses the private runtime, while `SIGNED_PRERELEASE` reaches the exact provenance checks and refuses an unpinned runtime before touching storage. Legacy fixed-root POC admission remains debug-only. These checks start no VM and use no signing credentials.

[The corrected `v0.9.3-dev.6` run](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41274695838), from commit `88bb8679934fdb286461f5a9a08198f54d7f159e`, passed 161 manager Swift tests, 31 Python tests, both optimized admission checks, all 550 upstream tests, the app/icon builds and the isolated SSH job. Signing, Apple acceptance and final package verification are separate gates after those checks.

Runtime signing and API authentication succeeded. Apple received submission `78d5ad92-c756-4e67-a0f1-87dec516c5d4` at `2026-11-01T04:57:16.237Z` and still reported `In Progress` at the 45-minute limit (`05:42:38Z`). CI cleaned up credentials, retained artifact `13072336103` (`notarization-diagnostics-v0.9.3-dev.6`) and skipped publication. No `v0.9.3-dev.6` release exists. The retained runtime ZIP has SHA-256 `b6dbfb08c213458b9d57486f30b699ecf9e2fccfb430276ad2fd9d7cbaccad4b`.

Read-only verification of that downloaded candidate, with macOS trust-service access, passed all 22 Mach-O Developer ID/team, hardened-runtime, timestamp, entitlement, deep-signature and networking-pin checks. Every unsigned runtime payload matches the original locked kit. Apple acceptance, fresh stapling, the signed app/ZIP and Gatekeeper remain unverified; no accepted signed-runtime lock has been committed. Preserve the candidate and submission ID when diagnosing the pending submission rather than assuming another upload fixes an Apple processing delay. The user chose to keep the release in CI; no local credential use was authorized or performed.

To check this existing submission, dispatch `notarization-status.yml` on `main` with `gh workflow run notarization-status.yml --repo reactive-org/omarchy-vm-manager --ref main`. This release-specific CI job verifies the immutable `v0.9.3-dev.6` source commit, then queries the recorded submission ID using only the three API secrets. It imports no signing identity and creates no new Apple upload. The current status and any rejection log are retained as a seven-day artifact; the temporary API key file is removed on success or failure.

[Status check `41278438740`](https://github.com/reactive-org/omarchy-vm-manager/actions/runs/41278438740) completed successfully and Apple still returned `In Progress` for the same submission. No new upload or signing occurred, so the prerelease remains unpublished. The status-check changes passed 161 manager tests and 34 script tests locally, including CI-only credential refusal, key cleanup on API failure and rejection of a mismatched submission reply.

Signing changes runtime bytes. Existing custom factory receipts/manifests tied to the ad-hoc kit are preserved and refused by the signed build; they need a newly prepared compatible bundle. Existing profiles, writable disks and official factory identity are not migrated or rewritten by packaging. Real guest acceptance of the signed build remains TO PROVE.

## Verification boundary

`make verify-bundle` and `--verify-bundle-json` verify the package without testing host hypervisor readiness. Their JSON explicitly reports `hostPreflightPerformed: false` and `vmLaunchEnabled: false`. They exit before constructing the app model or opening a manager session. Normal diagnostics and VM launch still perform host preflight.

CI checks nested code signatures, macOS compatibility, exact resource/runtime contents and the absence of factory disks. Build/test jobs receive no signing credentials; the tagged signing step uses the authorized release credentials. No job launches a VM, requests macOS permissions or verifies real guest behavior. Downloading and installing a development build is a separate user action.

Local validation on 1 November 2026 passed `make build test` (159 Swift tests and 22 Python tests), exact locked-runtime verification, package assembly, and ZIP extraction followed by signature/provenance/layout verification. No app was opened, existing installed app replaced, factory image downloaded or VM launched. The runtime lock and compiled pin were unchanged.

The CI packaging runs additionally exposed a SwiftPM toolchain difference: resource bundles can be flat or use `Contents/Resources`. Both layouts are now verified explicitly, with ambiguous layouts rejected. Packaged resource lookup resolves the embedded app bundle before SwiftPM's build-path fallback, and bundle diagnostics load the owner contract. Follow-up local checks passed 159 Swift tests and 23 Python tests, normal package round-trip verification, and verification of a disposable flat-layout app copy.
