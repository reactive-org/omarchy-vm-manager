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

## Review labels and expanded proposal inspection — 3 November 2026

The New VM and Setup preview buttons now use **Review setup** and **Update
preview**. Review/preview IDs, input fingerprints, task fingerprints and apply/
workflow review hashes are under Details; the CLI preview lookup is there too.
Existing acknowledgment, task inspection, separate consent and execution guards
are unchanged. The isolated screen target continues to pass all 56 checks.

At the user's request the existing proposal contents are retained while a
plain-English replacement is deferred. This [expanded New VM capture](media/setup-review-expanded.png)
shows the original JSON disclosure with synthetic fixture data, alongside the
[complete synthetic proposal](media/setup-review-proposal.json). These artifacts
are for inspecting the presentation, not a real configuration or guest outcome.
That earlier debug capture explicitly expanded the proposal for inspection. The earlier gallery above records its original layout.
No real transport, host installation or VM operation was performed.

The full proposal is now inside the collapsed **Details** disclosure in both New
VM and Setup, alongside the IDs/fingerprints and CLI lookup. Its original JSON
contents are retained; acknowledgment and task/authorization controls remain
outside Details. The [updated New VM capture](media/setup-review-details.png)
shows the simplified default view. All 56 isolated UI checks pass after this move;
no real execution, installations or VM launches occurred.

## Separate Source and multiple Profiles — 3 November 2026

The current New VM and Setup screens separate **Source** (None, Bundled
configuration, Local setup folder) from **Profiles**. Developer, Web, Python and
Project managed are multi-select cards with native icon/monogram badges, selected
borders/checkmarks, selected counts and summaries extracted from the shared
resolver. Summaries include inherited Developer features, additional features,
language tools and database clients; they describe expected configuration, not
observations from a guest. Individual Feature choices controls are hidden for now.

Bundled configuration requires at least one profile. A local folder retains all
profiles/options/tasks declared in its `vm.yml`; selecting cards adds bundled
profiles, deduplicating existing builtin aliases. This avoids replacing a project's
configuration through the native picker. Local custom profiles remain supported
in the manifest; native cards currently describe the four bundled profiles.
Resolved profile names remain visible for a saved preview even when no new Source
is selected. The complete proposal, IDs/hashes and CLI lookup stay under Details.

**Review setup** / **Update preview** freeze the actual combined plan. Profile edits
invalidate preview acknowledgment. Conflicts are refused by the shared planner,
with an explanation to choose a compatible combination or resolve settings in a
local manifest. For example, Web and Python declare different database-client
lists; an explicit `setup.options.databases.clients` resolves that conflict. The UI
never chooses a silent winner. Saving still creates stopped metadata only.

| Current synthetic capture | Link |
| --- | --- |
| New VM cards, dark | [Image](media/setup-profiles/new-vm-review-dark.png) |
| New VM cards, light | [Image](media/setup-profiles/new-vm-review-light.png) |
| Saved Setup handoff, dark | [Image](media/setup-profiles/setup-handoff-dark.png) |
| Saved Setup handoff, light | [Image](media/setup-profiles/setup-handoff-light.png) |
| Fake-enabled consent | [Image](media/setup-profiles/setup-fake-consent-dark.png) |
| Synthetic terminal | [Image](media/setup-profiles/setup-terminal-dark.png) |
| Resource controls | [Dark](media/setup-profiles/new-vm-resources-dark.png), [light](media/setup-profiles/new-vm-resources-light.png) |

The [report](media/setup-profiles/report.json) now records **62** isolated UI checks,
including empty bundled-profile refusal, forwarding multiple selections and local
profile inheritance. [Evidence/hashes](media/setup-profiles/evidence.json) accompany
all eight inspected captures. The earlier galleries are historical layouts.

`make test-provisioning-selection` passed 24 Swift functions across two suites,
including eight new profile/projection/wire tests. `make test` passed 448 Swift
functions in 58 suites, 52 script tests, signed local helper fixtures and the 62
screen checks. Release compilation passed without real signing credentials.
Package/export verification and both diff checks pass. Product approval remains
nil and execution disabled. Shared engine/library/resource pins are unchanged;
there was no real SSH/Ansible, host install, image download or VM launch.

## Clear permission labels — 3 November 2026

The prepared Apply review uses three separate labels: **Allow admin access during
setup**, **Allow Docker without sudo**, and **Allow custom tasks from this
configuration**. Each is shown only when its review requirement is present:
`persistentGrantRequired`, `dockerRootAccessRequired`, or `taskTrustIdentity`.
Current valid Apply reviews require the admin grant; Docker/custom-task prompts
appear only for their corresponding requirements. Captions/tooltips explain
cleanup/revocation, guest root-equivalent Docker access and custom Ansible's ability
to execute on the Mac using available credentials. Custom task consent still
requires complete task inspection. The three bindings, consent tokens, reset
behavior, submit guards and product execution admission are unchanged.

The [current permission capture](media/setup-permissions.png) uses synthetic Web
configuration plus an inspected synthetic custom task so all three requested
permissions can be inspected together. Checked fixture values grant no real
permission. `make test-provisioning-screens` passes all 62 isolated UI checks,
including independent grant/Docker/task consent refusals and single submission.
No real SSH/Ansible, host installation or VM launch was performed.

## Conditional optional-app trim — 3 November 2026

The New VM and Setup forms expose **Trim optional apps** only for the official
Try Omarchy factory, initially off. The tooltip describes removing optional apps
for a more sensible base while retaining development tools and VM components;
it explicitly distinguishes the guest from the reusable factory image. The frozen
review displays the trim intent outside Details; package candidates stay in the
proposal under Details. Custom/unknown provenance cannot authorize trimming.

The offscreen fake-service scenarios additionally check default-off visibility,
frozen trim forwarding, acknowledgment invalidation, reset/hiding for a custom
factory, and no implicit re-enable when returning to official. These are injected
view actions, not physical input, focus, hover-tooltip or VoiceOver acceptance.

Final screen target passes **74 checks with twelve PNGs** and zero runtime starts,
on-display windows or activation. Four new light/dark scrolled captures were
inspected and retained with the report and hashes under [setup-trim](media/setup-trim/evidence.json):
[New VM](media/setup-trim/new-vm-trim-dark.png) and
[Setup](media/setup-trim/setup-trim-dark.png). They show actual native controls and
synthetic reviewed data. Hover tooltips, physical input and real trimming remain
unverified. The companion broad-test Ansible exception and exact checks are
recorded in the [implementation record](DevVMProvisioningPlan.md#optional-app-trim-selection--3-november-2026).

## Collapsed Theme & layout — 3 November 2026

New VM and Setup have an initially collapsed Theme & layout section. It accepts a
GitHub repository URL, `random` or `most-starred`, exposes random's minimum stars
(default ten, zero skips ranking), and offers keep/select/remove for the managed
Lua layout. A chosen file's basename is shown. Tooltips explain preserved source
choices, review-time GET checks and their limits; layout help describes frozen
bytes, trusted guest Lua and next-login behavior. No host installations or sign-in
are initiated by the controls.

Review resolves markers and checks the resulting repository via the shared manager
service, then displays a concrete theme and layout intent. Editing either clears
review/acknowledgments. Fake-service screen scenarios check initial collapse,
selection forwarding, review invalidation and existing-VM forwarding. They do not
claim that a public repository is reachable or that a native theme/layout works.
The implementation record documents separate fake HTTP/GitHub CLI and local-file
checks, including the URLProtocol test that exercises GET without a network socket.

Final offscreen acceptance passes **82 checks with sixteen generated PNGs** and
zero runtime starts, on-display windows or activation. The four new appearance
captures were inspected in light/dark and retained with [report/hashes](media/setup-appearance/evidence.json):
[New VM](media/setup-appearance/new-vm-appearance-dark.png) and
[Setup](media/setup-appearance/setup-appearance-dark.png). Review data and paths are
synthetic. Physical input, hover, native file selection and actual theme/layout
execution remain TO PROVE. Full manager tests and release compilation pass; the
[implementation record](DevVMProvisioningPlan.md#theme-and-layout-selection--3-november-2026)
records exact fake/local checks and limitations.

## Theme/layout visual refinement and adjacent trim help — 3 November 2026

The disclosure now contains separate purple theme and teal layout panels with a
clear title, icon and short description. At widths of 680 points or greater they
sit side by side; narrower New VM sheets stack them. Explicit Keep/GitHub/Random/
Most starred choices replace the combined field label. Only GitHub shows the full
repository field; Random shows the compact star threshold. Layout uses Keep/Lua
file/Remove choices and a selected-file row with Replace/Clear actions. Details of
GET semantics, authentication and Lua trust remain in contextual tooltips. The
collapsed disclosure summarizes the selection and signals invalid input.

The trim explanation now sits directly beneath **Trim optional apps**, including
the removal-candidate note when enabled. The separate frozen-review summary is a
short **Included in preview: Trim optional apps** status. It remains present for
loaded reviews whose source controls are hidden. This distinguishes the editable
choice from the reviewed result without separating its explanation from its toggle.

**VERIFIED:** `make test-provisioning-screens` passes **92 checks with sixteen
PNGs**, zero runtime starts, on-display windows or activation. New checks verify
wide/narrow layouts, empty GitHub refusal, explicit Keep retaining the layout,
Most starred forwarding the existing marker, and repository edits invalidating
review. Four current light/dark appearance captures were inspected; screenshots
and hashes/report are retained under [setup-appearance-refined](media/setup-appearance-refined/evidence.json).
[Setup](media/setup-appearance-refined/setup-appearance-dark.png) shows adjacent
trim help and wide panels; [New VM](media/setup-appearance-refined/new-vm-appearance-dark.png)
shows the stacked panels. Release compilation and diff/export verification pass.
This slice changes native presentation and its isolated acceptance harness; shared
package/resources/pins, protocols and execution admission stay unchanged.

**TO PROVE:** physical input, focus/VoiceOver, hover, native file dialogs and real
guest/network behavior. No actual HTTP/gh/SSH/Ansible, host install, VM operation,
factory download or desktop takeover occurs. The product execution gate stays off.

## Visual dev-vm layout examples — 3 November 2026

The layout panel now offers Examples alongside Keep, Custom file and Remove. It
expands to a full-width gallery of four single-select cards: Four terminals,
Terminal + browser, VS Code + browser and Claude workspace. Wireframes show the
relative split proportions and browser overlap, with names, descriptions, app
prerequisites and a selected border/checkmark. The illustrations are native SwiftUI
views rather than downloaded images or live guest screenshots. The actual original
Lua is frozen when reviewed. Choosing a card does not install its prerequisite apps.

Fake-service acceptance adds empty-gallery refusal, card-to-source forwarding,
frozen example title recognition, invalidation after another card is selected and
a full-width existing-VM gallery. Card state is exercised through the same binding
as its button; this does not establish physical pointer/keyboard behavior. The
shared/core tests independently verify bundled byte hashes and actual frozen inputs.

**VERIFIED:** full manager tests pass 468 Swift functions/52 script tests and the
final screen target passes **100 checks with twenty PNGs**. Four current gallery
captures were inspected and retained with [hashes/report](media/setup-layout-cards/evidence.json):
[Setup](media/setup-layout-cards/setup-layout-cards-dark.png) shows all four cards
in one row, while [New VM](media/setup-layout-cards/new-vm-layout-cards-dark.png)
uses a two-column grid. These are synthetic fixtures with actual native views, no
runtime starts/on-display windows/activation, and no actual HTTP/gh/SSH/Ansible/Lua,
installs or VM operations. Physical input, VoiceOver and real guest placement remain
TO PROVE. Shared resource/source hashes and exact reviewed bytes have separate
local test coverage in the implementation record.

Final release compilation also passes without signing credentials. No operational
guest acceptance or distribution signing is implied.
