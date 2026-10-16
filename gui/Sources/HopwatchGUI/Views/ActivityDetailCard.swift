import SwiftUI
import AppKit

/// Expandable detail card for an item in the Activity History.
/// Provides plain-English ("Explain Like I'm 5") translations,
/// explains why Hopwatch alerted (e.g. latency impact during high traffic),
/// displays specific network metrics (IPs, ISP, latency, jitter),
/// offers actionable remediation steps, and includes a copy button.
struct ActivityDetailCard: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    let entry: ActivityEntry

    @State private var copied = false

    private var explanation: PlainExplanation {
        PlainEnglishTranslator.translate(ruleId: entry.ruleID, summary: entry.summary)
    }

    private var catalogRule: RulesCatalog.Rule? {
        entry.ruleID.flatMap { coordinator.rulesCatalog.catalog?[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - Plain English Explanation
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)

                    Text(explanation.title)
                        .font(.subheadline.weight(.semibold))

                    if let ruleID = entry.ruleID {
                        RuleChip(ruleID: ruleID)
                    }

                    Spacer()
                }

                Text(explanation.explanation)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // MARK: - Specific Diagnostic Context & Telemetry
            diagnosticContextSection

            // MARK: - Actionable Advice
            if !explanation.action.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("What you can do:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(explanation.action)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // MARK: - Footer (Timestamps & Copy Action)
            HStack(alignment: .center) {
                timingSummary
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy Details")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied ? .green : .secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
        .padding(.vertical, 4)
    }

    // MARK: - Diagnostic Context Section
    @ViewBuilder
    private var diagnosticContextSection: some View {
        if entry.ruleID == "HOG-1" || !entry.trafficEvidence.isEmpty {
            hogDiagnosticView
        } else if entry.kind == "public-ip-changed" || entry.summary.contains("Public IP") {
            publicIPDiagnosticView
        } else if let blurb = catalogRule?.blurb, !blurb.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Technical Analysis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - App Traffic / HOG-1 Context
    private var hogDiagnosticView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.trafficEvidence, id: \.captureKey) { evidence in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(evidence.name)
                            .font(.caption.weight(.bold))

                        if let friendly = evidence.friendlyProcessDescription {
                            Text("(\(friendly))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if evidence.appName == nil && evidence.process != nil {
                            Text("(macOS Background Process)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let date = evidence.observedDate {
                            Text("Observed \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if let rate = evidence.rateMbps, let share = evidence.dominancePct {
                        let verb = evidence.direction == "up" ? "Uploading" : "Downloading"
                        Text("\(verb) \(rate.formatted(.number.precision(.fractionLength(0...1)))) Mbps (\(Int(share.rounded()))% of Mac's network traffic)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Network Latency Correlation Note
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("Network Latency Impact Observed:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                        if let latDetail = evidence.latencyDetail {
                            Text(latDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Hopwatch does not alert simply because a big file is downloading. It only alerts when high bandwidth usage actively degrades network latency and causes jitter (bufferbloat) for other apps and devices on your connection.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Public IP Change Context
    private var publicIPDiagnosticView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Address Transition")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let from = entry.fromValue {
                    GridRow {
                        Text("Previous IP:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(from)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let to = entry.toValue ?? coordinator.currentPublicInfo?.ip {
                    GridRow {
                        Text("New Public IP:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(to)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    }
                }

                if let isp = entry.extraDetail ?? coordinator.currentPublicInfo?.isp {
                    GridRow {
                        Text("Internet Provider:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(isp)
                            .font(.caption.weight(.medium))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Text("Your public IP is provided by your internet service provider (ISP). It changes when your ISP renews dynamic leases, after a modem reboot, or when switching network connections (e.g. Wi-Fi to cellular or VPN).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Timing Summary
    private var timingSummary: some View {
        HStack(spacing: 6) {
            Text("Recorded \(entry.latest.formatted(date: .abbreviated, time: .shortened))")
            if entry.occurrences > 1 {
                Text("· \(entry.occurrences) times")
            }
            if let duration = entry.totalDuration {
                Text("· total duration \(ActivityEntry.duration(duration))\(entry.durationIsLowerBound ? "+" : "")")
            }
        }
    }

    // MARK: - Clipboard Action
    private func copyToClipboard() {
        var text = "\(explanation.title)\n"
        text += "Summary: \(entry.summary)\n"
        if let ruleID = entry.ruleID { text += "Rule: \(ruleID)\n" }
        text += "Explanation: \(explanation.explanation)\n"
        if let from = entry.fromValue, let to = entry.toValue {
            text += "IP: \(from) → \(to)\n"
        }
        if let isp = entry.extraDetail ?? coordinator.currentPublicInfo?.isp {
            text += "ISP: \(isp)\n"
        }
        for ev in entry.trafficEvidence {
            text += "Traffic: \(ev.detail)\n"
            if let lat = ev.latencyDetail { text += "Latency: \(lat)\n" }
        }
        if !explanation.action.isEmpty {
            text += "Action: \(explanation.action)\n"
        }
        text += "Date: \(entry.latest.formatted(date: .abbreviated, time: .standard))"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
