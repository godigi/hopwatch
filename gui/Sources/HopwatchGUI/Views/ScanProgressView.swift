import SwiftUI

/// The phase list that replaced the spinner, now topped with a determinate
/// bar.
///
/// Every row states one of three facts about a *check*: it ran, it was
/// skipped, or it did not complete. None of them is a fact about the
/// network. A phase is never coloured by how good its number was — that
/// judgement is `lib/diagnosis.sh`'s, it arrives in `diagnosis[].summary`,
/// and a progress list that pre-empted it with a red row would be the app
/// diagnosing on its own.
///
/// The bar above the grid is `Support/PhaseWeights.swift`'s fraction, not a
/// second opinion computed here — this view's job is to draw the number,
/// never to invent one. The "N of M · phase · mode" line stays exactly as
/// it was: the bar complements that count, it does not replace it, because
/// the count is still the honest answer to "how many checks are left" even
/// when the bar's answer to "how much longer" is a guess this build has not
/// yet earned (see `overallBar`).
struct ScanProgressView: View {
    var progress: ScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.hasPlan {
                overallBar
                summary
                if progress.isSpeedTesting, let speed = progress.speed {
                    SpeedometerGaugeView(speed: speed)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity
                        ))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
                          alignment: .leading, spacing: 4) {
                    ForEach(progress.phases) { row($0) }
                }
            } else {
                // No plan yet. Either the run has not announced one, or the
                // installed netdiag predates --progress and never will —
                // indistinguishable from here, and an indeterminate spinner
                // is the honest answer to both.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: progress.isSpeedTesting)
    }

    /// The determinate bar. Its fraction comes from `PhaseWeights`, weighted
    /// by durations measured on *this* machine on *this* mode; the ETA
    /// underneath is shown only once that history exists at all —
    /// `snapshot.isLearned` — because an ETA built from equal-weight guesses
    /// on a fresh install would claim precision the app does not have.
    private var overallBar: some View {
        let snapshot = progress.weights.progress(
            mode: progress.mode ?? "",
            phases: progress.phases,
            speedProgress: progress.speed?.progress,
            bufferbloatProgress: progress.bufferbloat?.progress)
        return VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: snapshot.fraction)
            if let eta = etaText(snapshot) {
                Text(eta).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// `nil` before any history exists for this mode — the "unlearned"
    /// state the bar shows without a time. Once learned, a countdown that
    /// has run down to (or below, from rounding) a couple of seconds reads
    /// as "finishing up" rather than as "0s left", which would look like a
    /// stalled or backwards-running clock on a phase that has not actually
    /// finished.
    private func etaText(_ snapshot: PhaseWeights.Progress) -> String? {
        guard snapshot.isLearned else { return nil }
        guard let remaining = snapshot.remainingSeconds, remaining > 2 else {
            return "Finishing up…"
        }
        return "About \(Self.formatted(seconds: remaining)) left"
    }

    private var summary: some View {
        HStack(spacing: 6) {
            // A count of a declared list, kept beside the bar rather than
            // replaced by it. The two answer different questions — how
            // many checks are left, and how much longer — and only the
            // first is exact. On a fresh install it is also the only one
            // the app can answer at all, since the bar has no learned
            // durations to weight itself by yet.
            Text("\(progress.resolvedCount) of \(progress.plannedCount)")
                .monospacedDigit()
            if let running = progress.runningPhase {
                Text("· \(running.label.lowercased())")
            }
            if let mode = progress.mode {
                Text("· \(mode)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(_ phase: ScanProgress.Phase) -> some View {
        HStack(spacing: 6) {
            icon(phase).frame(width: 14)
            Text(phase.label)
                .foregroundStyle(phase.state == .pending ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing = trailing(phase) {
                Text(trailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .help(phase.why ?? "")
    }

    @ViewBuilder
    private func icon(_ phase: ScanProgress.Phase) -> some View {
        switch phase.state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            // Green for "the check completed", amber for "it didn't" —
            // both statements about the tool. rc is the check function's
            // exit status, not a verdict on the link.
            Image(systemName: (phase.rc ?? 0) == 0 ? "checkmark.circle.fill"
                                                   : "exclamationmark.circle")
                .foregroundStyle((phase.rc ?? 0) == 0 ? Color.green : Color.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .didNotRun:
            Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
        }
    }

    /// The right-hand column. "not measured" is never rendered as a number,
    /// and a phase with no duration shows no duration.
    private func trailing(_ phase: ScanProgress.Phase) -> String? {
        switch phase.state {
        case .pending, .running:
            return nil
        case .done:
            let rc = phase.rc ?? 0
            let duration = phase.ms.map(Self.formatted(ms:))
            if rc != 0 { return duration.map { "exit \(rc) · \($0)" } ?? "exit \(rc)" }
            return duration
        case .skipped:
            return phase.why ?? "skipped"
        case .didNotRun:
            return "didn't run"
        }
    }

    static func formatted(ms: Int) -> String {
        ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms"
    }

    /// A rounded, human-scale "about how long" — "45s", "1m 20s", "2m" —
    /// never sub-second precision an estimate this coarse cannot back up.
    static func formatted(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
    }
}

/// A tactile speedometer dial with needle and gradient arc scaled dynamically to connection speed.
struct SpeedometerDialView: View {
    let mbps: Double?
    let isUpload: Bool

    // Dynamic scale based on speed
    var maxScale: Double {
        guard let speed = mbps, speed > 0 else { return 100 }
        if speed <= 50 { return 100 }
        if speed <= 250 { return 300 }
        if speed <= 500 { return 600 }
        if speed <= 1000 { return 1200 }
        return 2500
    }

    var fraction: Double {
        guard let speed = mbps, speed > 0 else { return 0 }
        return min(max(speed / maxScale, 0), 1)
    }

    var startAngle: Angle { .degrees(140) }
    var endAngle: Angle { .degrees(400) }
    var sweepAngle: Double { 260 }

    var currentAngle: Angle {
        .degrees(140 + fraction * sweepAngle)
    }

    var gradientColors: [Color] {
        if isUpload {
            return [Color.teal, Color.green]
        } else {
            return [Color.blue, Color.cyan]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 + 10)
            let radius = min(geo.size.width / 2 - 8, geo.size.height - 18)
            let needleLength = radius - 8

            ZStack {
                // Background track
                Path { path in
                    path.addArc(center: center, radius: radius,
                                startAngle: startAngle, endAngle: endAngle, clockwise: false)
                }
                .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // Active filled arc
                if fraction > 0.005 {
                    Path { path in
                        path.addArc(center: center, radius: radius,
                                    startAngle: startAngle, endAngle: currentAngle, clockwise: false)
                    }
                    .stroke(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }

                // Needle
                Path { path in
                    path.move(to: center)
                    let rad = currentAngle.radians
                    let tip = CGPoint(x: center.x + CGFloat(cos(rad)) * needleLength,
                                      y: center.y + CGFloat(sin(rad)) * needleLength)
                    path.addLine(to: tip)
                }
                .stroke(LinearGradient(colors: gradientColors, startPoint: .center, endPoint: .topLeading),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Pivot hub
                Circle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 8, height: 8)
                    .position(center)

                // Scale ticks / labels at bottom corners
                Text("0")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: center.x - radius + 2, y: center.y + 12)

                Text(formattedScale(maxScale))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: center.x + radius - 2, y: center.y + 12)
            }
        }
        .frame(width: 100, height: 74)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: mbps)
    }

    private func formattedScale(_ val: Double) -> String {
        if val >= 1000 {
            return String(format: "%.0fG", val / 1000)
        }
        return "\(Int(val))"
    }
}

/// Prominent live throughput hero card rendered during the speedtest phase.
struct SpeedometerGaugeView: View {
    let speed: ScanProgress.Speed

    var isDownload: Bool { speed.direction == .download }
    var isUpload: Bool { speed.direction == .upload }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header: Directional badge & previous milestones
            HStack(spacing: 8) {
                directionBadge
                Spacer()
                if let dl = speed.downloadMbps, isUpload {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                        Text(String(format: "↓ %.1f Mbps", dl))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }

            // Main gauge & live throughput
            HStack(alignment: .center, spacing: 16) {
                SpeedometerDialView(mbps: speed.mbps, isUpload: isUpload)

                VStack(alignment: .leading, spacing: 6) {
                    // Big readout
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(speed.mbps.map { String(format: "%.1f", $0) } ?? "--")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Mbps")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .animation(.easeInOut(duration: 0.2), value: speed.mbps)

                    // Stage progress bar
                    VStack(alignment: .leading, spacing: 2) {
                        if let progress = speed.progress {
                            ProgressView(value: min(max(progress, 0), 1))
                                .animation(.easeInOut(duration: 0.2), value: progress)
                        } else {
                            ProgressView().controlSize(.small)
                        }

                        HStack {
                            Text(stageCaption)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if let progress = speed.progress {
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Spacing.md)
        .cardStyle()
    }

    private var directionBadge: some View {
        HStack(spacing: 5) {
            if isDownload {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Download")
                    .foregroundStyle(.primary)
            } else if isUpload {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Text("Upload")
                    .foregroundStyle(.primary)
            } else if speed.direction == .ping {
                Image(systemName: "waveform.path")
                    .foregroundStyle(.orange)
                Text("Ping")
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                Text(speed.stage.isEmpty ? "Speed Test" : PhaseLabel.humanised(speed.stage))
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isDownload ? Color.blue : (isUpload ? Color.green : Color.secondary)).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var stageCaption: String {
        if isDownload { return "Measuring download bandwidth…" }
        if isUpload { return "Measuring upload bandwidth…" }
        if speed.direction == .ping { return "Measuring latency and jitter…" }
        return speed.stage.isEmpty ? "Connecting to server…" : PhaseLabel.humanised(speed.stage)
    }
}

/// The one-line form, for the dropdown. Same model, no room for a grid or a
/// bar — so the one-line equivalent of `overallBar` is text, appended to the
/// count rather than replacing it, and only once it is learned. The speed
/// line is left alone: it already shows live throughput and a stage name,
/// and a third clause there would crowd the one line that is busiest at
/// exactly the point in a run where crowding it is worst.
struct ScanProgressLine: View {
    var progress: ScanProgress

    var body: some View {
        if progress.isSpeedTesting, let speed = progress.speed {
            Text(speedLabel(speed))
        } else if progress.hasPlan {
            Text(countLabel).monospacedDigit()
        } else {
            Text("Working…")
        }
    }

    private var countLabel: String {
        var text = "\(progress.resolvedCount) of \(progress.plannedCount)"
        if let running = progress.runningPhase {
            text += " · \(running.label.lowercased())"
        }
        if let eta = etaSuffix {
            text += " · \(eta)"
        }
        return text
    }

    private var etaSuffix: String? {
        let snapshot = progress.weights.progress(
            mode: progress.mode ?? "",
            phases: progress.phases,
            speedProgress: progress.speed?.progress,
            bufferbloatProgress: progress.bufferbloat?.progress)
        guard snapshot.isLearned, let remaining = snapshot.remainingSeconds, remaining > 2 else {
            return nil
        }
        return "\(ScanProgressView.formatted(seconds: remaining)) left"
    }

    private func speedLabel(_ speed: ScanProgress.Speed) -> String {
        let arrow = speed.directionSymbol.map { "\($0) " } ?? ""
        let stage = speed.stage.isEmpty ? "Speed test" : PhaseLabel.humanised(speed.stage)
        guard let mbps = speed.mbps else { return "\(arrow)\(stage)" }
        return String(format: "%@%@ · %.1f Mbps", arrow, stage, mbps)
    }
}
