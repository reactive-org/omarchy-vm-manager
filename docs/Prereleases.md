# Development prereleases

GitHub Actions publishes versioned development builds of Omarchy VM Manager for Apple Silicon and macOS 15+. These are experimental development fork builds using the exact reviewed Try Omarchy source and binary provenance recorded in the repository. They use ad-hoc signing; they are not Developer ID signed or notarized, and Gatekeeper may block a downloaded copy. Trusted signed distribution remains a separate milestone requiring authorized signing credentials and release-runtime policy work.

## Publish a build

1. Confirm `App/Info.plist` has the intended app version.
2. Create and push a tag `vVERSION-dev.N`, where VERSION matches `CFBundleShortVersionString` and N is a positive integer. For example, `v0.9.3-dev.1`.
3. CI runs the macOS manager/build/icon/upstream checks and the isolated Ubuntu SSH checks.
4. Only after both jobs pass, the package job fetches the pinned runtime, builds and ad-hoc signs the debug app through the normal assembly pipeline, verifies it, and publishes a GitHub prerelease with its ZIP and SHA-256 checksum. It never marks the build as the latest stable release.

The ZIP contains `Omarchy VM Manager.app`, including the CLI, storage helper, runtime, licenses and third-party notices. The release notes record the manager commit and runtime source/archive pins. Only the tagged package job has repository write permission; pull-request jobs remain read-only and cannot publish releases. Existing release assets are not overwritten automatically.

Local packaging uses separate build output and does not open or install an app:

```sh
make fetch-runtime-kit
make prerelease RELEASE_TAG=v0.9.3-dev.1
```

The staged app is under `dist/prerelease-staging/`; the ZIP, checksum and release notes are under `dist/prerelease/`. A pre-existing archive is preserved and must be inspected before packaging the same tag again.

## Exact runtime dependency

The reviewed runtime archive is hosted as a separate clearly labelled CI dependency prerelease, under tag `runtime-kit-<full kit SHA-256>`. This tag is derived from the committed `Config/TryOmarchyRuntime.lock.json`; it does not mean the stock upstream kit or an arbitrary newly built kit is acceptable.

`make fetch-runtime-kit` checks the compiled lock pin, patch digest, downloaded archive digest, archive paths/types/size, exact per-file inventory, manifest and extracted code signatures. Existing artifacts must also verify; incompatible or damaged artifacts are preserved and refused. No runtime lock or pin is rewritten. A future runtime change requires deliberately publishing its exact reviewed archive under its new digest tag.

Prerelease assembly preserves the kit's existing upstream-pipeline ad-hoc signatures, checks its exact inventory before and after embedding, and runs upstream signature/entitlement verification. Different macOS `codesign` versions can produce different bytes when re-signing the same kit; preserving the verified signatures avoids changing the runtime pin. The manager executables and outer app are signed normally. This applies to ad-hoc development packaging; future Developer ID distribution still needs a deliberately re-signed, reviewed and notarized runtime.

The runtime dependency contains no VM disk, factory image, user registry, credential or guest data. It is fetched only for packaging. No Docker or guest-package rebuild is needed in CI.

## Verification boundary

`make verify-bundle` and `--verify-bundle-json` verify the package without testing host hypervisor readiness. Their JSON explicitly reports `hostPreflightPerformed: false` and `vmLaunchEnabled: false`. They exit before constructing the app model or opening a manager session. Normal diagnostics and VM launch still perform host preflight.

CI checks nested code signatures, macOS compatibility, exact resource/runtime contents and the absence of factory disks. It does not launch a VM, request permissions, access real credentials or verify real guest behavior. Downloading and installing a development build is a separate user action.

Local validation on 1 November 2026 passed `make build test` (159 Swift tests and 22 Python tests), exact locked-runtime verification, package assembly, and ZIP extraction followed by signature/provenance/layout verification. No app was opened, existing installed app replaced, factory image downloaded or VM launched. The runtime lock and compiled pin were unchanged.
