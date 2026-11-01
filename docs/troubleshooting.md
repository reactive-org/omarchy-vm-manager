# Troubleshooting

[User guide](README.md) · [Manage your guests](managing-guests.md)

## Command+Space opens Mac Spotlight

The Mac Command key acts as Omarchy's Super key inside a focused guest. Capturing shortcuts such as Command+Space requires the manager's Accessibility grant.

1. Shut down the guests.
2. Open **Permissions** in the manager sidebar.
3. Click **Enable Super shortcuts…**.
4. In macOS Accessibility settings, enable **Omarchy VM Manager** yourself.
5. Return to the manager, launch a guest, click its desktop and try Command+Space.

![The Permissions page with the Enable Super shortcuts button and optional bridges shown off](media/permissions.webp)

The manager should show **Allowed** after the grant. Ad-hoc development rebuilds can need a refreshed entry through the same flow. This grant is separate from the installed Try Omarchy app's permission. Command+Return working by itself does not prove system-wide shortcuts are captured.

## Copy and paste do not work

Check that **Clipboard integration** is enabled in the stopped guest's configuration. Changes require another launch. Click the intended guest before copying or pasting; only the focused guest exchanges clipboard text with the Mac.

In Foot, paste uses **Ctrl+Shift+V**. Test with fresh throwaway text in both directions. If one guest fails, save work, shut down and relaunch that guest before retesting.

## A guest opens with a black or incomplete desktop

Intermittent graphics startup failure remains under investigation. Save work if possible, shut down the affected guest through the manager, then relaunch it. A successful restart has restored the desktop in earlier tests, but this is not a confirmed fix. Use **Force Stop…** only when graceful shutdown is insufficient and you accept losing unsaved guest work.

If managed SSH is ready, it can remain usable even when the graphical desktop is unhealthy. Do not reset or delete the disk to troubleshoot this symptom.

The **Runtime** page shows host preflight and the known graphics issue. **Check Again** refreshes the runtime checks; **Build provenance** identifies the pinned helper source.

![The Runtime page with a passed host preflight and the known graphics startup issue](media/runtime.webp)

## SSH is not ready yet

**Running** and SSH readiness are separate. First boot can still be installing integrations or creating the owner account. With manual owner setup selected, finish the normal wizard in the guest. With saved defaults, allow automatic setup to finish.

Inspect the guest's **SSH** tab, or use `./bin/omarchy-vm get "Guest Name"`. For a stopped guest, **Available on next launch** is expected. Use **Copy SSH Command** after verification; the generated connection checks the guest's host identity on every connection.

A CLI wait timeout leaves the guest running. Use `wait` to continue observing it. See the [CLI quick start](cli-quickstart.md).

## Launch, Configure or Delete is unavailable

Configuration and deletion require a stopped guest without an unresolved saved session. Retained POC profiles keep their original configuration but can use the normal confirmed Trash flow. Launch also requires compatible verified runtime files, host resources, free disk space and a free managed SSH port.

Read the guest's error and **Session activity** before retrying. If files or settings changed outside the manager, preserve them and resolve the reported conflict; replacing or deleting the guest is not an automatic recovery step.

## CLI owner overrides are rejected

Use a matching updated manager and CLI. A newer CLI connected to an older running manager gets an unsupported configuration error; rebuilding the CLI alone does not update that manager. The local 0.9.4 (17) app and CLI include the flags and pass installation checks; real creation/boot with overrides remains untested.

For `invalid-owner-defaults`, check that Guest Defaults is enabled and saved, the username is not reserved, and the timezone and keyboard use supported values. Overrides require saved defaults even when all six owner fields are supplied: the password still comes from the saved credential. `--owner-defaults off` cannot be combined with overrides. Use `""` only to clear optional full name/email; JSON `null` is rejected.

For `creation-only`, supply overrides to `create`, not `update`. Owner setup is fixed when the profile is created. For `invalid-config`, check the [flag/JSON mapping](CLI.md#per-vm-owner-overrides); `--keyboard` maps to `keyboardID` inside `ownerOverrides`. Unknown keys and password/credential fields are refused.

To omit the personal SSH key saved in Guest Defaults, use `--inherit-default-public-key off` during creation. Its JSON key, `inheritDefaultPublicKey`, belongs at the top level and takes a boolean. Managed SSH stays enabled. Remove any explicit `--public-key` or JSON `publicKey` as well if only the manager's key should be enrolled. Suppression never removes an existing guest's keys; see [key inheritance](CLI.md#personal-ssh-public-key-inheritance).

For `owner-keychain-upgrade-required`, explicitly upgrade or save the password through Guest Defaults in a compatible provisioned build. `owner-keychain-provisioning-required` indicates the build cannot access protected password storage. The CLI cannot upgrade credentials or bypass authentication; see [Touch ID setup](TouchID.md). Override or credential validation failures save no profile.

## The image cache uses space in Downloads

The current compressed factory image is about 3.17 GB and is reused by new guests. Obsolete image downloads are cleaned up after at least seven days without use. Existing guests keep their own independent disks.

You can remove `~/Downloads/Omarchy VM Manager/Factory Images/` manually while no guest is being prepared. Existing guests can still boot; the next new guest downloads the image again. See [factory cache details](FactoryCache.md).
