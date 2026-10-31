# Managed host SSH

New profiles offer **Enable SSH from this Mac**, on by default, and an optional **Add my SSH public key…** chooser. Creation stores metadata only. First launch generates distinct per-guest Ed25519 client and server identities. Complete the normal Omarchy owner-account setup; no console bootstrap, guest password capture or clipboard step is required for enrollment. The SSH page reports provisioning separately from VM startup and offers **Copy SSH Command** only after authenticated verification.

Existing profiles stay unchanged. SSH enrollment changes for existing disks need a separately reviewed stopped-VM migration. The retained POC profiles remain protected and have no managed SSH configuration.

## Trust and storage

This is a private version-1 extension of the pinned Try Omarchy helper and guest package, with public run protocol 1 unchanged. New-root settings contain exactly one TCP mapping from a persistent guest-specific `127.0.0.1` port to guest port 22. Ports are allocated uniquely across registered profiles, probed again before launch and reserved until matching `.exited`. QEMU's actual bind remains authoritative. Launch refuses an edited mapping, mismatched metadata or missing capability. General port forwarding and effective-settings support remain separate Phase 3 work.

Keys live in the VM's private `.manager-ssh` directory, protected by 0700 directories and 0600 files. Registry schema 2 contains only the allocated port and optional public-key fingerprint. Older registry schema 1 is accepted without silently enabling SSH; old manager builds reject schema 2. The guest-specific client key remains on the Mac. A separate read-only provisioning share carries only the guest server key, authorized public keys and VM/session metadata. The guest installs these through the `try-omarchy` integration package, not by altering Omarchy-owned files or the factory image.

The manager-generated guest host key is pinned before the first network connection, so trust does not depend on accepting whatever key answers a localhost port. Each VM has its own known-hosts file and SSH configuration. Personal `~/.ssh/config`, `known_hosts`, private keys and agent are untouched. The optional picker reads only an explicitly selected public key, strips its comment, rejects private material/options/malformed key data and shows its fingerprint.

The guest waits until owner provisioning finishes and exactly one eligible non-root account exists, then binds that owner for subsequent boots. It uses the vendor `sshd.service`, a runtime configuration drop-in, key authentication and the existing gateway-only firewall rule. It maintains a separate authorized-key file while preserving the owner's ordinary `.ssh/authorized_keys`. It never creates a bootstrap account. `sshd` is started for the managed boot rather than enabled globally.

The host accepts advisory status only for the matching UUID and session nonce, then authenticates with its exact client key and strict pinned host identity. A packaged identity command must confirm the expected non-root account and VM/session before Ready. Probes are bounded and cancelled on exit. SSH errors never release a live VM handle, memory or port reservation.

The guest validates the exact read-only 9p provisioning mount on each enrollment attempt. Once mounted, its inode ownership comes from the Mac; it is not treated as an ordinary guest-owned directory. The mount's parent remains root-owned in the guest. Wrong tags, writable mounts and links are refused. Repeated timer runs are covered by a regression test and a real-guest run.

Provisioning errors expose only validated stage/code enums and an optional bounded errno or exit status. Exception messages, command output, paths and key data are not sent to the manager. These diagnostics identified and fixed the first real-guest enrollment failure.

## Recovery and limitations

Missing keys, pin mismatches, ambiguous owner accounts, unexpected settings and changed host identities fail closed. Keys are preserved for review; there is no automatic credential regeneration, host-key replacement or destructive reset. **Retry SSH Check** repeats verification after setup or a transient failure. Enrollment/owner/key rotation and existing-disk migration need a future explicit recovery transaction.

Whole-root Trash deletion includes that guest's credentials. A selected public-key staging file is removed when its profile is deleted. Credentials are excluded from reports and source control. No password is stored. The host filesystem remains part of the trust boundary: this private debug app does not encrypt its unattended per-VM client key or use Keychain.

## Validation

The manager suite covers default-on/off creation, persistent distinct ports, legacy registry behavior, isolated protected keys, restart nonce replacement, pin/missing-key refusal, public-key validation, session isolation and strict OpenSSH configuration parsing. Guest tests cover owner waiting, separate key enrollment, vendor service configuration, idempotent restart and identity refusal. Helper tests cover the private share boundary, mapping/session mismatch, permissions and untrusted report owners.

`make test-ssh` uses two disposable containers and synthetic credentials. It verifies normal-owner provisioning, managed and optional public-key authentication, explicit localhost bindings, cross-VM credential rejection and changed host-key rejection. On a Mac, `python3 Scripts/test_managed_ssh.py --swift-probe` additionally exercises the production Swift readiness probe against those servers. Docker must already be available; the test does not manage Docker settings. Containers are removed on completion. No Omarchy factory image or real QEMU VM is used by these tests.

**VERIFIED — disposable A:** normal owner setup followed by package upgrade to `0.1.0-39` becomes authenticated SSH-ready without a pasted command, guest password capture or host-key prompt. The generated Copy SSH Command configuration works, and original host/client key files and pins survive the diagnostic restarts unchanged.

**TO PROVE:** clean first boot of the corrected package in B, two simultaneous authenticated guests, successful SSH recovery across a working guest restart, sleep/wake, independent shutdown and authentication during a graphical failure. Container tests do not establish these real-Mac exit criteria. The earlier intermittent graphics startup failure remains open. Existing POC disks are not used for SSH testing.
