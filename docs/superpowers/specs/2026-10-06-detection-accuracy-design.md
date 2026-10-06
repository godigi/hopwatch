# Network detection accuracy design

Approved on 2026-10-06. The scope is the 13 confirmed findings in [the audit](../../2026-10-06-detection-audit.md). The three policy-dependent candidates at the end of the audit are excluded.

## Outcome

One measurement must have the same meaning in the scan, saved history, monitor journal, and dashboard. Missing evidence stays unknown; a successful independent probe can refute a broader outage claim. Users should not receive an all-clear over repeated critical faults or a fault attribution to a component that was not measured.

## CLI and probe interpretation

- Gate P1/P2 on an actual public reachability check. A focused ping run with healthy public targets cannot use unrun DNS/public defaults to claim a critical outage.
- Treat the public-IP metadata service as a metadata source. Its failure alone cannot prove internet failure when independent traffic such as Apple's canary, TCP, or public pings succeeds. Preserve captive-portal precedence.
- Record configured DNS resolver success independently from direct public-resolver success. D5 requires a measured configured secondary answer; direct public success alone cannot name a configured fallback.
- The full-check final diagnosis consumes measured speed. Preserve early feedback where possible, but the final printed and saved verdict must agree. Do not overlap the speed test with latency, loss, or bufferbloat probes.

## Historical judgement and baseline

- Incorporate recurring recorded diagnosis severities in the network-level verdict. Do not let healthy medians across a limited metric subset override repeated critical faults. Avoid marking one rare, old critical event as a persistent fault.
- Judge each NTP drift observation by absolute magnitude for history and comparison. Preserve the signed raw value for display where useful. Keep cutoffs in `lib/thresholds.sh`.
- Exclude known ICMP-filtered gateway ping loss from historical fault judgement when the same run proves actual traffic works.
- Apply the scan's VPN/split-tunnel MTU exception and exact threshold boundary semantics in history. Keep the raw MTU visible.
- Match baseline records by the history's canonical network identity. The same gateway MAC remains the same network when SSID visibility changes.
- MTU increase is an improvement or neutral change, never a BL-1 regression. A decrease can remain an advisory when the baseline logic supports it.

## Monitor and dashboard

- A monitor sample with unknown measurement cannot clear a prior fault. Keep prior state until a fresh successful measurement supports recovery; the journal must not say “Resolved” merely because the rule set went empty.
- Dashboard channel crowding shows the measured same-channel neighbor count and uses the CLI's WS-1 verdict, not total nearby networks or a Swift cutoff.
- Dashboard checks that did not run show unknown or skipped instead of fabricated successes, values, or grades. Render the CLI's verdicts where available; do not add new thresholds to Swift.

## Verification and delivery

Add a failing regression for each finding before changing product code, then run focused and full CLI/GUI suites. Bump the local patch version once for the batch, build/install/relaunch `/Applications/Hopwatch.app`, and check the installed version. Work on `fix/network-detection-accuracy` based on released `main`, leaving active feature worktrees untouched. Do not commit or push to `main` or publish a release before the final user review.
