import SwiftUI

/// Small views shared by more than one screen. `RuleChip` is the first
/// tenant; anything else that stops being one view's private detail moves
/// here rather than getting copy-pasted a second time.

/// A rule id, rendered as a capsule. The one place in this app a rule id
/// becomes a piece of UI — `RunListView` and `RunReportView` both used to
/// hand-roll this capsule themselves, which is exactly the kind of drift
/// this component closes off, the same way `Theme.cardStyle()` closed off
/// eight hand-rolled cards.
///
/// Two renderings, chosen by whether `RulesCatalogStore` has anything to
/// say about `ruleID`:
///
/// - **With a catalog entry:** tappable. A tap opens a popover with the
///   rule's title, a meta line naming its id and the catalog's own
///   (rule-general, not this-incident) severity, the catalog's blurb
///   verbatim, and a link into `docs/DIAGNOSIS-RULES.md` on GitHub for the
///   full trigger condition.
/// - **Without one** — no catalog loaded yet, an old CLI, or an id the
///   catalog doesn't recognise — an inert capsule with the bare id. This
///   is deliberately byte-for-byte what `RunListView` always rendered
///   before this component existed: nothing about the chip's appearance
///   changes for a user whose CLI predates `--rules-catalog`.
struct RuleChip: View {
    let ruleID: String
    @Environment(HopwatchCoordinator.self) private var coordinator
    @State private var showPopover = false

    var body: some View {
        if let rule = coordinator.rulesCatalog.catalog?[ruleID] {
            Button { showPopover = true } label: { capsule }
                .buttonStyle(.plain)
                .help("What rule \(ruleID) means")
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    RuleChipPopover(rule: rule)
                }
        } else {
            capsule
        }
    }

    /// The exact styling `RunListView`'s chip used before this file
    /// existed — see that view's git history for the literal it was lifted
    /// from.
    private var capsule: some View {
        Text(ruleID)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
    }
}

/// The popover a tappable `RuleChip` opens. Every string here is either the
/// CLI's own catalog prose, rendered verbatim, or presentational scaffolding
/// around it ("Rule", "·", the link label) — nothing composes an opinion
/// about the rule.
private struct RuleChipPopover: View {
    let rule: RulesCatalog.Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rule.title ?? rule.id).font(.headline)
            Text(metaLine).font(.caption).foregroundStyle(.secondary)
            if let blurb = rule.blurb, !blurb.isEmpty {
                Text(blurb)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let url = docURL {
                Link("More in the Diagnosis guide", destination: url)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    /// "Rule G3 · warning · judged by the CLI, not the app" — the
    /// mockup's own wording (nimbalyst-local/mockups/netdiag-activity.
    /// mockup.html), restated here rather than copied as a literal because
    /// the id and severity are this rule's, not the mockup's example.
    /// `severity` is the catalog's rule-general answer, not this
    /// incident's — see `RulesCatalog.Rule`'s header — which is exactly
    /// why the line says "judged by the CLI, not the app": the popover is
    /// reference material about the rule, not a verdict about this run.
    private var metaLine: String {
        "Rule \(rule.id) · \(rule.severity ?? "info") · judged by the CLI, not the app"
    }

    /// `rule.doc` is a repo-relative anchor into `docs/DIAGNOSIS-RULES.md`
    /// (docs/JSON-SCHEMA.md: "a GitHub-style anchor"); this is that same
    /// string turned into the GitHub URL a `Link` can actually open.
    /// `godigi/netdiag` and the `main` branch match every other hardcoded
    /// reference to this repo in the app (`BinaryLocator.missingBinaryMessage`).
    private var docURL: URL? {
        guard let doc = rule.doc, !doc.isEmpty else { return nil }
        return URL(string: "https://github.com/godigi/hopwatch/blob/main/docs/\(doc)")
    }
}

/// The five activity rows: "what should work here", as one icon strip.
///
/// Shared rather than private to `RunReportView` because Home, a stored
/// run's detail and the run list all render it through that view, and a
/// user sees those surfaces seconds apart — describing a verdict
/// differently in each is how an app contradicts itself. Same reason
/// `SignalScale.cellContent` and `AlertStageCard` are shared.
///
/// This carried a second, vertical layout and a `compact` flag for a
/// dropdown arrival card that was to render the same five rows. That card
/// shipped (`ArrivalCard.swift`) stating mechanism only and rendering no
/// suitability at all, so both were dead the day they landed: one call
/// site, always the strip. Deleted rather than kept warm — git history has
/// them if the arrival card ever grows the rows it was supposed to.
///
/// ── What this view is allowed to decide ────────────────────────────────
/// A colour, a glyph, and a two-or-three-word category word. That is all.
///
/// The label ("Video & voice calls"), the ordering, the reason sentence and
/// the verdict itself are the CLI's, from `helpers/suitability.py`, and are
/// rendered verbatim. The category word is the same latitude
/// `AlertDefinition.title` takes — see that file's header — and must stay a
/// label rather than growing into a sentence about the network. If a future
/// edit wants to explain *why* an activity won't work, that belongs in
/// `helpers/rules_catalog.py`'s `impacts` table and its blurbs, not here.
struct SuitabilityPanel: View {
    let rows: [RunSnapshot.SuitabilityRow]

    var body: some View {
        // Nothing at all, rather than an empty card: a report from a CLI
        // predating `suitability` has no answer to give, and a heading
        // over blank space reads as a failure rather than an absence.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("What should work here")
                    .font(.headline)
                    .padding(.bottom, Theme.Spacing.sm)
                // Home and a full report have enough width to make the five
                // answers glanceable side by side.
                HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                    ForEach(rows) { row in
                        tileView(row)
                    }
                }
            }
        }
    }

    /// One activity as an icon-first tile. The verdict still has both a
    /// distinct glyph and a word, so colour accelerates the scan without
    /// becoming the only way to read it. Longer CLI-authored reasons move
    /// to hover help, because five of them inline would be a paragraph
    /// where the point is a glance.
    private func tileView(_ row: RunSnapshot.SuitabilityRow) -> some View {
        let tint = Self.tint(row.verdict)
        return VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: Self.activitySymbol(row.activity))
                .font(.title3)
                .foregroundStyle(tint)
            Text(row.label ?? row.id)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
            HStack(spacing: 3) {
                Image(systemName: Self.symbol(row.verdict))
                Text(Self.word(row.verdict))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .top)
        .background(tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .help(Self.detail(row) ?? Self.word(row.verdict))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Mappings
    //
    // Static and internal rather than private closures in the body, so
    // `VerifyMode` can call them directly — the only runnable harness on
    // this toolchain cannot construct a SwiftUI view. Same shape and same
    // reason as `StageResolver` and `FullCheckPolicy`.

    /// The sentence under a row: the CLI's own explanation of what wasn't
    /// measured, or the rules that decided the verdict. Never a sentence
    /// composed here.
    static func detail(_ row: RunSnapshot.SuitabilityRow) -> String? {
        if let reason = row.unmeasuredReason, !reason.isEmpty { return reason }
        guard !row.because.isEmpty else { return nil }
        return "because " + row.because.joined(separator: ", ")
    }

    /// Deliberately four distinct *shapes*, not four tints of one shape.
    /// Colour is never the only signal — `MenuBarLabel.dot` follows the
    /// same rule and explains why: a status a user cannot read without
    /// distinguishing red from green is a status some users cannot read.
    static func symbol(_ verdict: RunSnapshot.SuitabilityRow.Verdict) -> String {
        switch verdict {
        case .good:       return "checkmark.circle.fill"
        case .degraded:   return "exclamationmark.triangle.fill"
        case .broken:     return "xmark.octagon.fill"
        case .unmeasured: return "minus.circle"
        case .unknown:    return "questionmark.circle"
        }
    }

    /// Activity identity is visual too; the status glyph beside the word
    /// remains separate. The keys are the CLI's closed activity set and a
    /// future unknown key gets a generic network icon rather than a blank.
    static func activitySymbol(_ activity: String?) -> String {
        switch activity {
        case "calls":     return "video.fill"
        case "streaming": return "play.rectangle.fill"
        case "gaming":    return "gamecontroller.fill"
        case "vpn":       return "lock.shield.fill"
        case "browsing":  return "globe"
        default:           return "network"
        }
    }

    static func tint(_ verdict: RunSnapshot.SuitabilityRow.Verdict) -> Color {
        switch verdict {
        case .good:       return .green
        case .degraded:   return .orange
        case .broken:     return .red
        case .unmeasured, .unknown: return .secondary
        }
    }

    /// Category labels, matching the CLI text report's own wording so the
    /// terminal and the app say the same thing about the same run.
    ///
    /// "Won't hold up" rather than "Broken" is deliberate and load-bearing:
    /// the CLI only assigns `broken` to persistent, present-tense faults —
    /// no route, no DNS, a captive portal — never to intermittent or
    /// historical ones. The word has to carry that weight honestly.
    static func word(_ verdict: RunSnapshot.SuitabilityRow.Verdict) -> String {
        switch verdict {
        case .good:       return "Fine"
        case .degraded:   return "Rough"
        case .broken:     return "Won't hold up"
        case .unmeasured: return "Not measured"
        case .unknown:    return "—"
        }
    }
}

/// A small "what does this mean?" affordance next to a jargon term —
/// `RunReportView`'s answer to "When I see 'packets', 'size', and 'MTU', I
/// have no idea what they mean." Looks `key` up in
/// `RulesCatalogStore`'s `metrics` glossary (schema `2`,
/// `helpers/rules_catalog.py`) and shows the CLI's own `help` sentence —
/// never a Swift-authored explanation, the same discipline `RuleChip`
/// applies to a rule's blurb.
///
/// Renders nothing when the glossary hasn't loaded yet or doesn't
/// recognise `key` (an old CLI, or a term this build asks about that a
/// future catalog renamed) — an absent hint is a smaller gap than a
/// button that opens on an empty popover.
struct HelpHint: View {
    let key: String
    @Environment(HopwatchCoordinator.self) private var coordinator
    @State private var showPopover = false

    private var catalogMetric: RulesCatalog.Metric? {
        coordinator.rulesCatalog.catalog?.metric(key)
    }

    private var helpText: String? {
        if let help = catalogMetric?.help, !help.isEmpty {
            return help
        }
        return MetricGlossary.entry(for: key)?.fullHelp
    }

    private var titleText: String {
        catalogMetric?.label
            ?? MetricGlossary.entry(for: key)?.title
            ?? key
    }

    var body: some View {
        if let help = helpText, !help.isEmpty {
            Button { showPopover = true } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(help)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(titleText).font(.headline)
                    Text(help)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(width: 280, alignment: .leading)
            }
        }
    }
}
