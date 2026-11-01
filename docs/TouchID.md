# Touch ID for guest setup

Status: the supplied profile has passed read-only validation and the user has authorized CI integration and a signed release. Native authentication checks remain pending. No installed app or saved password has been changed.

**DESIGN DECISION:** an automatically configured new VM authorizes its setup-password retrieval once on first launch. macOS offers Touch ID with the Mac login password as fallback. Creating a profile without starting it reads only protected-item metadata. Manual setup and completed guests do not read a password. Retrying interrupted setup requires another approval; there is no shared unlock session across guests.

## Native protection

The manager uses `kSecUseDataProtectionKeychain: true`, the service `dev.omarchy.vm-manager.unattended.biometric.v1`, and a generic password indexed by its existing credential UUID. `SecAccessControlCreateWithFlags` specifies `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `.userPresence`. The item is not synchronized to iCloud.

Each read creates one interactive `LAContext`, with no recent-device-unlock reuse, and passes it directly to one `SecItemCopyMatching` call. The context is invalidated afterward. There is no separate `evaluatePolicy` prompt, automatic authentication retry, shared context or legacy lookup on failure. Authorization completes before storage preparation or helper launch. Cancellation and missing entitlements have distinct, non-secret error messages.

Apple documents [biometric Keychain access](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id), [authentication-context reuse](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext) and the [macOS Keychain/signing requirements](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains). The data protection Keychain requires provisioned entitlements; adding a Touch ID dialog in front of the old file-based Keychain would not supply biometric protection for the stored item.

## Existing saved passwords

In a provisioned build, **Guest Defaults → Upgrade Saved Password to Touch ID…** explicitly copies only the currently saved credential from the old login-Keychain service. The old authorization may prompt during this one-time transition. It does not perform an additional protected read as part of the upgrade. Future first-launch retrievals use the biometric item.

The UUID remains unchanged, so pending snapshots referencing that credential can use the upgraded item. The original entry is retained, including its original Keychain ACL; older copies have not acquired biometric protection. Repeated upgrade actions check metadata and return without reading either password. If migration fails, the original and Guest Defaults file remain untouched. Saving a freshly entered password also writes to the protected service, under a new UUID as before.

New profiles using unattended defaults are refused until the saved credential is protected. Older pending guests whose snapshots reference a different historical credential also fail closed; upgrading the current defaults does not silently replace their original passwords. Completed guests continue to bypass password retrieval.

## Provisioning profile

The user initially chose to supply the profile later, then downloaded it and authorized finding/validating it. No new signing secret or CI secret is assumed, and existing CI credential authorization remains limited to the release job.

**VERIFIED — supplied profile, 1 November 2026:** `~/Documents/Apple Code Signing/Omarchy_VM_Manager_Developer_ID.provisionprofile`, SHA-256 `f5ddd1c8f3d572881bd85522ac086a4e271d351e4e0225442094987f706d2aed`, passes the project's exact App ID/team/macOS/distribution/expiry/entitlement policy. It expires at `2044-10-27T10:03:25Z`. Its one authorized certificate is current and exactly matches the public signing certificate extracted from the digest-verified `v0.9.3-dev.6` CI candidate; their teams also match. OpenSSL verifies the profile's CMS signature, its signer identifies Apple, and macOS local basic certificate trust evaluation passes. This is not a fresh online revocation check or a signed-app launch test. The original profile remains untouched in Documents; no profile/certificate was imported or private key used. The non-secret validation receipt is `.build/touch-id-profile-validation.json`.

The profile must be a nonexpired macOS Developer ID distribution profile for the exact App ID `<TEAM_ID>.dev.omarchy.vm-manager`, matching the authorized signing identity/team. `Scripts/assemble_app.py --signed-prerelease --keychain-profile /path/to/profile.provisionprofile` embeds it and derives only `com.apple.application-identifier` and `com.apple.developer.team-identifier`. The App ID itself supplies the default Keychain access group. No shared Keychain group is granted, and child executables receive no added entitlement.

The user authorized storing this validated profile as `MACOS_KEYCHAIN_PROFILE_BASE64` in the repository's Actions secrets and running a signed release. Only the tagged signing step receives it, alongside the existing signing/notarization secrets. `Config/TouchIDProfile.lock.json` pins its exact SHA-256 and Bundle ID. The CI-only `make signed-prerelease` path requires the profile, decodes it to a mode-0600 file in a private runner directory, verifies its digest/scope before signing, passes it explicitly to the assembler, and removes the temporary copy on all exits. There is no arbitrary profile-path environment override or profile-less signed-release fallback. Do not invoke signing locally under the current authorization.

The assembler and final extracted-ZIP verification require the pinned embedded profile, exact manager-only entitlements and an app signing certificate authorized by that profile. Final signed verification runs only bundle diagnostics and checks the actual process reports its protected-storage entitlement, with host preflight and VM launch disabled. The CLI/storage helper must have no Keychain application/access-group entitlement. macOS remains responsible for Apple profile/certificate validity at launch; diagnostics do not read a password or exercise a biometric prompt.

Ad-hoc builds retain empty entitlements. They can be assembled and verified, and the form explains that protected storage is unavailable. They cannot save/read/upgrade protected passwords or create new unattended snapshots. They can still prepare manual profiles and launch completed guests through the existing admission policy; no such launch was performed here.

## Validation

**VERIFIED — synthetic:** the credential-policy tests inject a fake Security adapter and synthetic secrets. They cover the actual user-presence access-control object, device-only storage, no synchronization, one read per attempt, fresh contexts, no recent-unlock reuse, cancellation and entitlement failures without retry, noninteractive metadata admission, explicit/idempotent upgrade, original preservation and completed/manual guest bypass. Disposable UUID-root seed fixtures start no guest. Profile tests cover scope/expiry/platform/team mismatches, development/wildcard profile refusal, no shared entitlement grants and final-bundle entitlement checks.

**TO PROVE:** native authentication prompts and fallback, cancellation/prompt count, upgrade UI and changed-binary login-Keychain authorization, final profile/certificate admission, background focus and real guest behavior. No real credential, authentication UI, permission grant, installed app, existing guest or factory was used for these checks. Exact build/test/package commands and counts are recorded in [Validation](Validation.md#touch-id-feature-preparation--1-november-2026).
