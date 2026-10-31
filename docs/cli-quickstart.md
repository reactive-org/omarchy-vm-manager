# CLI quick start

[User guide](README.md) · [Full command reference](CLI.md)

Run commands from the repository root using `./bin/omarchy-vm`. The app bundle also contains `Contents/MacOS/omarchy-vm`. The CLI opens the manager in the background when needed and returns one concise JSON response per command.

## Create and wait for SSH

Save automatic setup in **Guest Defaults** first, or complete the normal setup wizard after launching. Then create a guest with custom resources:

```sh
./bin/omarchy-vm create Development --memory 4GiB --cpus 4 --start --wait ssh --timeout 1800
```

The command waits for authenticated SSH, including first-boot setup. New guests use saved owner defaults and enable SSH by default. The factory download is shared through the Downloads cache.

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

`delete` moves a stopped guest's folder to recoverable Trash. It does not delete the shared image cache. Retained POC guests are protected.

Successful commands return exit code `0`; failures return `1`. A bounded wait timeout returns `124` and leaves the guest under the manager's control. You can wait again without starting a second session:

```sh
./bin/omarchy-vm wait Development --for ssh --timeout 600
```

See the [full CLI reference](CLI.md) for JSON configuration files, manual owner setup, optional public keys and all flags.
