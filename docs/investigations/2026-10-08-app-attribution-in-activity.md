# App attribution missing from activity history

## Finding

The reported behavior is real. Hopwatch's monitor captures per-process traffic and resolves app bundles, but its activity events retain only the generic HOG-1 rule title. The activity UI therefore cannot explain which app was busy at the time of the warning.

Read-only inspection of the installed app's `~/Library/Application Support/com.godigi.hopwatch/events.json` found three HOG-1 records. Each contained only `kind`, `id`, `continuesPrevious`, `network`, `date`, `ruleID`, and `summary`. All three summaries were “One app is using up your connection.” None contained an app name, process, traffic rate, direction, or measurement timestamp.

## Data flow

- `lib/common.sh`, `hog_capture_evidence` and `hog_judge`: collect nettop interval rates, resolve app bundles, and select direction, rate, process, app name/bundle and traffic dominance. Hopwatch's own traffic is excluded.
- `lib/monitor.sh`, `_mon_probe_hog`: invokes those functions but retains only `MON_HOG_ACTIVE` as the monitor's finding. It does not forward attribution evidence to the event stream.
- `helpers/monitor_sample.py`, `_rule_fired`: produces a change summary from the static rules catalog. The event journal attaches special evidence for SOCK-1, but has no equivalent HOG-1 evidence attachment.
- `gui/Sources/HopwatchGUI/Services/HopwatchCoordinator.swift`: records the change's summary, rule, network, and timestamp.
- `NetworkEvent` and `EventStore`: have no app-attribution fields.
- `ActivityEntry`: groups episodes by rule and day. Its detail shows count/duration, not traffic evidence.
- `ActivityRow`: displays that summary and detail. The menu's recent activity uses the same folded history.

`lib/diagnosis.sh` can already produce a named HOG-1 diagnosis with upload/download rate and a Quit action for a resolved regular GUI app. That separate check is not attached to the activity event. Its later measurement would not establish who was busy at the original event time.

## Recommended correction

Capture attribution in the monitor when the traffic evidence is measured, pass it through the stream and journal, and persist it with the activity episode. Show the resolved app name, upload/download rate, and observation time in both recent activity and the Activity page. Keep the supporting share-of-traffic and latency measurements available in detail.

Handle changing top apps explicitly: daily same-rule grouping must not label an entire multi-app group with just one app, and an ongoing warning needs to retain fresh observations when a later capture finds a different app without the rule clearing.

When a regular GUI app cannot be resolved, show the observed process where available and explicitly state that app identification was unavailable. Older events should say attribution was not recorded; do not fill them from current traffic or a later scan.

## Interpretation and verification limits

The HOG-1 detector requires degraded latency, clean ping loss and substantial sustained traffic dominated by one app group; it is more than simply a list of busy processes. However, that correlation does not establish causation. Prefer wording such as “High traffic from [app] while latency was elevated.” Pausing the transfer and checking whether latency improves can help test the suspected cause.

The original app behind the screenshot's event cannot be identified from the saved GUI event records inspected here. No historic attribution was recovered and no live traffic capture was used to infer a historic culprit. The initial investigation was read-only; the approved local implementation is described below.

Implementation validation should cover stream/journal evidence, backward-compatible persistence, different apps across episodes and during a continuous warning, unattributed/system processes, historic events without evidence, and visibility in both history surfaces. Local implementation must follow the project's version bump, build, install and relaunch rules; public release requires a separate explicit user decision.


## Local implementation — 2026-10-09

Implemented on `fix/app-activity-attribution` in `/Users/bfreeman/Documents/AI-Workspace/netdiag_worktrees/app-activity-attribution`, based on `11a9bbd`. Local version is 1.14.3. At the end of local validation, changes were uncommitted and no public release had been made.

The monitor now retains each successful capture's app name/bundle or process, transfer direction and rate, share of non-Hopwatch Mac traffic, capture timestamp, router RTT and router/internet jitter. HOG-1 fired events carry this evidence through the stream and journal. Recaptures produce `rule-updated` rather than a second firing. A recovery can retain the last capture with its original measurement timestamp; it never presents recovered latency or current traffic as the original evidence.

The GUI decodes and saves the evidence with the event. History folding keeps a single occurrence for updates, retains different app identities across continuous warnings and separate episodes, and selects the latest observation for each app/direction. An update whose opening falls outside the view window remains visible as an observation with an unobserved start. An orphan recovery can show the last captured app without inventing a duration. Old events with no attribution explicitly say it was not recorded.

A shared evidence view displays app/process, upload/download Mbps, traffic share and local observation time in Activity, the dashboard's recent activity, and the menu's recent activity. Latency evidence and the distinction between correlation and causation are available in the row's help text. The headline identifies high traffic without asserting that the app caused the connection problem.

Repeated updates of the same app/direction within an episode replace the prior update while retaining the opening and distinct app identities. This prevents one capture per minute from consuming the 500-event GUI history in a few hours. Updates do not reset the network-change reassurance timer. Lifecycle firings and recoveries bypass generic duplicate suppression so repeated incidents within ten minutes close correctly.

The source catalog, diagnosis-rule documentation and stream schema documentation have been updated. Version references were advanced using `scripts/bump.py --type patch --no-commit --no-tag`; the notes are under Unreleased with the repository's explicit local-build version marker, since 1.14.3 has not been publicly released.

## Validation and review

- Before implementation: all 51 existing HOG tests passed. New regressions failed for missing stream/journal evidence and missing event persistence/display attribution.
- Fresh GUI suite: 133 tests in 21 suites passed, including ten attribution tests covering serialization, legacy events, changing apps, daily grouping, unknown processes, truncated windows, bounded history, repeat recoveries and reassurance timing.
- Full CLI run: 1,206 tests completed, with 1,205 passing and one failure because the initial local version bump added a release heading without a release tag. The changelog was corrected to the existing Unreleased/local-build convention. A fresh complete run of the HOG and changelog files passed all 66 tests, including the formerly failing metadata check and all added attribution tests. No outstanding CLI failure remains from those results; the full 1,206-test command was not repeated after the metadata correction.
- GUI baseline repairs were limited to stale tests: removed three calls to the deleted `MenuBarLabel.formatPing` parameter; marked jitter fixture links up; used ICMP-1 for internet ping filtering rather than the gateway-filtering TCP-1; updated the link-down assertion to the current `.noLink` state. No corresponding application behavior was changed.
- Independent code review caught repeated-clear suppression, reassurance timing and orphan-clear evidence issues. Each was reproduced with a failing regression, corrected and re-reviewed; the reviewer found no remaining material issue.
- `make install-gui` built and signed the release configuration with the stable identity and installed it to `/Applications/Hopwatch.app`; the app was relaunched. Installed version 1.14.3 and the code signature were checked directly.
- The installed executable's `--verify` harness reported “All checks passed.” `git diff --check` passed.
- The running application's Activity accessibility tree was inspected. The old HOG warning now visibly reads “High app traffic with elevated latency” and “App attribution not recorded.” No new naturally occurring HOG warning appeared during this UI inspection, so named-event behavior was verified through controlled monitor captures and regression tests rather than a live bandwidth incident.

The user explicitly approved committing, pushing to main and publishing on 2026-10-09. The reviewed changes were transferred to the clean, current main checkout for Nimbalyst’s atomic commit tool. Release notes were rolled to 1.14.3. Build, tag and push steps are performed explicitly so the required Nimbalyst commit tool owns the commit rather than the automatic CLI commit in make ship. Release and downloadable-asset verification follows publication.
