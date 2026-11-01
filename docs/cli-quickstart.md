# CLI quick start

[User guide](README.md) · [Full command reference](CLI.md)

Run commands from the repository root using `./bin/omarchy-vm`. The app bundle also contains `Contents/MacOS/omarchy-vm`. The CLI opens the manager in the background when needed and returns one concise JSON response per command.

## Create without launching

Enable and save automatic setup in **Guest Defaults** first. Its saved password must be available in the build's selected Keychain storage; see [Touch ID setup and build requirements](TouchID.md). The examples below are commands for future use: executing `create` saves a profile. Without `--start`, it creates no guest disk and launches no VM.

```sh
./bin/omarchy-vm create Development --memory 4GiB --cpus 4 --disk 64GiB
```

New guests inherit saved owner defaults and enable SSH by default. For manual first-boot setup, use `--owner-defaults off` instead and complete the wizard after launching.

## Override owner settings for one VM

Use these creation-only flags to change one VM's setup without editing Guest Defaults:

```sh
./bin/omarchy-vm create Work --memory 4GiB --cpus 4 --disk 64GiB \
  --username developer --hostname-prefix work \
  --full-name "Dev User" --email "dev@example.com" \
  --timezone Australia/Melbourne --keyboard "English (US)" \
  --inherit-default-public-key off
```

This also creates only a stopped profile. Omitted owner fields and the saved password are inherited. `--inherit-default-public-key off` suppresses the saved personal SSH key; managed SSH remains enabled with its separate per-VM key. Omit `--public-key` as well to enroll only that manager key. The JSON equivalent is top-level `"inheritDefaultPublicKey": false`. The hostname retains its unique UUID suffix. To omit the inherited full name or email, pass `--full-name ""` or `--email ""`. Owner-field overrides require enabled, saved Guest Defaults, cannot be combined with `--owner-defaults off`, and cannot be applied to an existing VM with `update`. The key-inheritance setting is also creation-only; unlike owner-field overrides, it can be used with manual setup. Passwords are never accepted as CLI arguments or JSON fields.

You can also put owner fields under `ownerOverrides` in a configuration file. Explicit flags replace individual fields while retaining other file values; see the [flag/JSON mapping and examples](CLI.md#per-vm-owner-overrides).

**Build availability:** the local ad-hoc 0.9.4 (17) app and CLI were installed on 2 November 2026; bundle verification and CLI help/version checks pass. Creation and real first boot with overrides remain untested. Use a matching updated manager and CLI; an older running manager rejects `ownerOverrides`. Development compatibility mode reuses saved login-Keychain passwords; protected Touch ID storage requires a provisioned build. See [Touch ID](TouchID.md) for provisioned-build requirements.

## Launch and wait for SSH

When ready to launch the profile created above:

```sh
./bin/omarchy-vm start Development --wait ssh --timeout 1800
```

This command launches the guest and waits for authenticated SSH, including first-boot setup. Use `Work` instead of `Development` for the override example. First setup may require the saved-password authorization described in [Touch ID](TouchID.md). The official factory download is shared through the Downloads cache; a selected custom factory uses its imported bundle. To combine creation and launch, add `--start --wait ssh --timeout 1800` to a `create` command.

The response's `guest` object includes these connection fields; values shown here are illustrative:

```json
{
  "state": "running",
  "ssh": {"status": "ready", "host": "127.0.0.1", "port": 2224},
  "network": {"guestIPs": ["10.0.2.15"], "addressesVerified": true}
}
```

Use the full response's `guest.ssh.command` to connect with the managed key and pinned host identity. The localhost port is the usable Mac endpoint; private NAT guest IPs can repeat between guests.

## Inspect, stop and change resources

```sh
./bin/omarchy-vm list
./bin/omarchy-vm get Development
./bin/omarchy-vm stop Development --wait
./bin/omarchy-vm update Development --memory 5GiB --cpus 6
./bin/omarchy-vm start Development --wait ssh
```

Use a full guest UUID instead of its exact name for scripts. Configuration edits are refused while running and take effect on the next start. Choose CPU and RAM values that fit your Mac.

## Restart or remove

```sh
./bin/omarchy-vm restart Development --wait ssh
./bin/omarchy-vm stop Development --wait
./bin/omarchy-vm delete Development
```

`delete` moves a stopped guest's folder to recoverable Trash. It does not delete the shared image cache. Stopped retained POC guests can be deleted through the same flow.

Successful commands return exit code `0`; failures return `1`. A bounded wait timeout returns `124` and leaves the guest under the manager's control. You can wait again without starting a second session:

```sh
./bin/omarchy-vm wait Development --for ssh --timeout 600
```

See the [full CLI reference](CLI.md) for JSON configuration files, manual owner setup, optional public keys and all flags.
