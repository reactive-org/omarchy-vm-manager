# Phase 1 two-VM POC

Run date: 31 October 2026 (Australia/Melbourne). This file records observations; pending checks are not acceptance claims.

## Scope and provenance

The user approved factory-image downloads and two disposable manager-owned VMs. They separately approved controlling only those guest windows and using synthetic clipboard contents. They will initiate whole-Mac sleep/wake when prompted. Their existing Try Omarchy VM and storage are excluded from all operations.

The kit and clipboard patch are unchanged from Docs/Validation.md: patch commit `a135f003c2ffd2ce820900b5896b7ad9e2b84a96`, kit SHA-256 `24d569ea2ee06e4f8fd435ea215483db4b968720e509f194ad8d2913a8f44d6e`, manifest `development`, protocol 1. Each profile uses 4096 MiB, two CPUs, NAT and explicit clipboard/battery/timezone bridges. No forwards, shared folders, USB, authentication or camera.

- A: `C7C2B381-E43C-4A5A-8246-4314596B4C0A`, Omarchy POC A.
- B: `89F88CC2-BD11-44B5-9C1B-31EDB2DE6B0B`, Omarchy POC B.
- Roots are derived beneath `~/Library/Application Support/Omarchy VM Manager/VMs/`.
- Private live evidence: `~/Library/Application Support/Omarchy VM Manager/Logs/POC-status.json`.

## Implementation checks

`make test` passes 34 Swift tests (including the new storage/admission suite) and 9 Python artifact tests. `make app` and `make verify-app` pass, including exact kit inventory, nested signatures, 24 Mach-O compatibility checks and host preflight. The app remains disabled by default; `--poc-approved` enables the fixed disposable profiles.

## Observations

| Check | Observed result |
| --- | --- |
| Initial host/storage | 128 GB Apple M5 Max, 18 cores, macOS 27.0.1, approximately 1.1 TiB free; both manager UUID roots absent |
| Existing Try Omarchy | Its application process was present in the baseline; no QEMU guest process was present. It was not controlled or modified. |
| A initial start | Started at approximately 11:42:31 AEDT; factory download proceeded in A's private cache |
| Storage permissions | A root 0700; both ownership markers and settings 0600 |
| Overlapping cold start | Clicking B Start during A's download was refused with the explicit wait-for-ready message; B remained stopped and its root remained absent |
| A desktop | Pending |
| B desktop while A usable | Pending |
| Independent disks/settings/window identities | Pending |
| Same-root lock/duplicate refusal | Unit guard passes; real live-lock check pending |
| Host/guest clipboard and background suppression | Pending |
| Independent graceful shutdown/restart/persistence | Pending |
| Confirmed force stop | Pending |
| Cancelled/normal app quit | Pending |
| Manager force quit / no orphan guest | Pending |
| User-initiated sleep/wake | Pending |
| Final shutdown and process cleanup | Pending |

No clipboard contents, guest passwords or personal host identifiers belong in this report. Preserve a minimal reproduction and stop further feature work if the real gate exposes a runtime singleton or lifecycle/focus failure.
