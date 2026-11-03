# Setup and New VM screen acceptance

Status: **VERIFIED — isolated fake-service view/action acceptance**, 3 November
2026. Real-guest and physical desktop interaction remain TO PROVE.

This extends the earlier component rendering fixture to the actual `VMEditor`,
`NewVMSetupSelectionView`, `ManagerView` sidebar/guest settings and
`DeveloperSetupView`. It does not replace these screens with a mock layout.

## Reproduce without a guest

```sh
make test-provisioning-screens
```

The target builds the debug app and runs `Scripts/test_setup_screens.py`. It creates
one disposable output directory under `/private/tmp`, invokes the debug-only
`--accept-setup-screens` entry point and validates its report and eight PNGs. The
printed directory is retained for inspection. The same check is part of `make test`.
No installed app is updated or opened. Do not run a release app with this debug
flag; release compilation omits the fixture entry point.

The entry point runs before normal AppModel, instance-lock, registry or service
construction. It injects an in-memory fake service and a model with a `FakeRuntime`
that is never started. The nominal support directory must remain absent. All
identities, proposals, tasks, guests and terminal bytes are synthetic. A separate
fake-enabled service exercises Apply consent controls without an operational
backend; the real product execution gate is not changed.

A local object in the fixture view environment drives the real bindings and shared
action handlers. It is not a global notification, socket, CLI execution override,
environment-variable bypass, event injector or a production singleton. Native
sheet/confirmation presentation is suppressed in this fixture; task assembly and
confirmation decisions are exercised without opening a dialog. It uses no system
AXUIElement API or accessibility permission grant. Physical pointer/keyboard,
VoiceOver/focus/tab order and actual file-picker/dialog interaction are not claimed.

## Acceptance matrix

The machine-readable report contains 56 unique successful checks:

| Area | Observed with isolated fake services |
| --- | --- |
| None / empty name | None is ready, cannot capture a setup, empty-name Save is inert; named None creation returns stopped metadata with no setup receipt |
| Reviewed creation | Selected setup requires a review plus independent save acknowledgment; review alone cannot create |
| Edits / races / failures | Feature/source edits clear review/acknowledgment; late capture replies are discarded; failed capture cannot confer consent; a new selection gets a new review |
| Manager precedence | Explicit 8-GiB / 4-core / 128-GiB / official factory choices survive a source proposal declaring different resources; receipt is handed to the matching stopped profile |
| Lost-reply replay | Duplicate same-selection Save returns the same UUID through the fake creation service |
| Setup handoff | The full guest Setup screen opens the exact saved preview; current product-surface execution remains disabled and cannot delegate preparation |
| Advanced source / tasks | Explicit local-source selection, complete multi-chunk UTF-8 task inspection, inspection invalidation and cross-guest/unavailable preview refusal |
| Independent consent | Missing grant, Docker consent, inspected source or task trust cannot submit; a valid fake submission occurs once and is not repeated |
| Terminal / cancellation | Literal Unicode search, expand/collapse, no input authority from synthetic bytes, explicit cancel confirmation; disappearance detaches without a second cancellation |
| Isolation | Zero runtime starts, no support-directory creation, no on-display fixture window or app activation; windows are closed after capture |

The fakes deliberately supply typed UI data, not real manager admission receipts or
execution capabilities. Existing core tests separately cover strict parsing,
frozen archives/hashes, package/provenance admission, IPC/session/transport fencing,
process ownership and cleanup. A fake UI reply cannot establish their real-world
truth. Successful view-state assertions are not evidence that OS input events,
real SSH, Ansible, authorization or a guest behaved correctly.

## Captures and rendering limits

Each image is labelled as isolated acceptance with synthetic data. Captures cover
New VM review and its scrolled resource controls in light/dark modes, the full
manager Setup handoff in light/dark, the fake-enabled consent state and a terminal
state. Scrolled captures intentionally show the current viewport rather than an
invented stitched page; the separate views cover content above/below the fold.

AppKit backing windows cannot become key/main, ignore mouse input, and activation
is prohibited. Any backing surface used for capture is placed outside every
attached display and checked before drawing; none is ordered onto a user display.
The report records zero on-display windows and zero visible windows at completion.
Rendering uses the actual own-process hierarchy and terminal Core Graphics view,
with ancestor clipping retained. Inactive/offscreen control tint is not proof of
active-window appearance. No user window, desktop pixels or personal state is read.

The inspected [check report](media/setup-acceptance/report.json) and
[evidence/hashes](media/setup-acceptance/evidence.json) accompany these captures:

| Screen / viewport | Dark | Light |
| --- | --- | --- |
| New VM reviewed selection | [Image](media/setup-acceptance/new-vm-review-dark.png) | [Image](media/setup-acceptance/new-vm-review-light.png) |
| New VM resource controls | [Image](media/setup-acceptance/new-vm-resources-dark.png) | [Image](media/setup-acceptance/new-vm-resources-light.png) |
| Manager Setup frozen handoff | [Image](media/setup-acceptance/setup-handoff-dark.png) | [Image](media/setup-acceptance/setup-handoff-light.png) |
| Fake-enabled independent consent | [Image](media/setup-acceptance/setup-fake-consent-dark.png) | — |
| Synthetic terminal/search | [Image](media/setup-acceptance/setup-terminal-dark.png) | — |

All eight images were inspected for readable labels, header/footer, scrolling and
terminal orientation/clipping. The offscreen SwiftUI renderer could omit unchanged
text from a cached display list; the fixture cycles appearance and restores the
requested scheme before capture without replacing view identity or state. The
report assertions continue after captures. Automated checks validate PNG structure
and dimensions, not visual quality; inspect new artifacts after renderer changes.

The source picker now explains that a loaded frozen handoff remains available
when the picker is None: choosing a source starts a new preview. Save and Apply
share their enablement guards with the action handlers, including task inspection,
so the handler cannot bypass the corresponding consent state.

`make test` passed 428 Swift test functions in 56 suites, 52 script tests,
relocated/read-only/ad-hoc-signed helper fixtures and the 56 screen checks.
The final focused screen target also passed after capture adjustments.
`make build-signed` passed as a release **compile**, with no real signing identity
or signing/notarization operation. Read-only binary inspection confirmed that the
debug screen entry point, driver/service names and synthetic acceptance banner
are absent from the release manager. Package/export verification passed; shared
package sources/resources and immutable export/engine pins are unchanged.

## What remains

Visible-window interaction, focus, keyboard navigation, accessibility/VoiceOver,
native file importers, confirmation/task sheets and real authorization echo need
separate acceptance. Follow the [milestone-6 runbook](DevVMMilestone6Runbook.md)
for the concrete disposable-guest scope, approval worksheet, operational-build
prerequisites, evidence matrix and cleanup. That runbook is prepared, not executed.
Host installs, real SSH/Ansible and VM launches were not performed for these checks.
