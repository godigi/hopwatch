import SwiftUI
import AppKit

/// Design tokens: the values a card, a spacing gap or a severity colour
/// should have, decided once instead of at each of the 8 call sites that
/// used to hand-roll them (`.quaternary.opacity(0.25)` in seven places and
/// `0.22` in an eighth; corner radii of 5, 6 and 8 depending on which view
/// wrote it).
///
/// Nothing here decides whether a number is good or bad — that judgement
/// stays in lib/thresholds.sh, per CLAUDE.md. `Health` still arrives from
/// CLI-derived state; everything below only says which colour draws it.
enum Theme {

    // MARK: - Spacing

    /// A starting scale for new surfaces, not a census of the old ones —
    /// existing views use a wider spread of values (6 and 10 are common)
    /// and were left alone here; this task is the foundation, not a
    /// layout pass. The redesign tasks that build new views reach for
    /// these; retro-fitting old views happens when a view is rebuilt,
    /// not before.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Corner radius

    enum Radius {
        /// The one card radius. Seven of eight hand-rolled cards already
        /// used 8; ExpertPanel's raw-JSON box was the outlier at 6, and
        /// this being the only radius `.cardStyle()` reaches for is what
        /// fixes that drift.
        static let card: CGFloat = 8
        /// The dropdown's row-hover highlight — smaller than a card on
        /// purpose, since it marks an inline hover state, not a
        /// container.
        static let control: CGFloat = 5
    }

    /// The opacity every hand-rolled card multiplied `.quaternary` by.
    /// One view (NetworksView) had drifted to 0.22; the other seven used
    /// 0.25, so 0.25 is what `.cardStyle()` uses.
    static let cardOpacity: Double = 0.25

    // MARK: - Fonts

    enum Font {
        /// Menu-bar and dropdown IP addresses: small enough to sit beside
        /// the status dot without crowding it, and monospaced so digits
        /// don't jitter the layout as they change. No built-in semantic
        /// text style is this exact size, so it is named here rather than
        /// left as a bare literal at each call site.
        static let compactMonospace = SwiftUI.Font.system(size: 11, design: .monospaced)

        /// The raw-JSON disclosure in ExpertPanel: dense output where
        /// fitting more of it on screen matters more than matching the
        /// app's normal type scale.
        static let rawJSONMonospace = SwiftUI.Font.system(size: 10, design: .monospaced)
    }
}

// MARK: - Card modifier

extension View {
    /// The one card background+corner-radius definition, replacing every
    /// `.background(.quaternary.opacity(...), in: RoundedRectangle(cornerRadius: ...))`
    /// this app used to hand-roll per view. Deliberately takes no
    /// parameters: a card that needs a different radius needs a named
    /// token and a reason, not an argument.
    func cardStyle() -> some View {
        background(.quaternary.opacity(Theme.cardOpacity),
                   in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// Caps a block of running prose at a readable measure.
    ///
    /// Two reasons, one of them structural. The typographic one is
    /// ordinary: a sentence set 700pt wide is hard to track back to the
    /// start of the next line, and these views hold whole paragraphs of
    /// explanation.
    ///
    /// The structural one is why this is a shared modifier rather than a
    /// per-view judgement call. An uncapped `Text` reports its *ideal*
    /// width as the width of the whole sentence on one line, and a
    /// view's ideal width is what `NavigationSplitView` weighs when it
    /// decides whether the sidebar still fits beside the detail. One long
    /// unbroken sentence in a corner of a screen was therefore setting
    /// the width at which the whole window drops its sidebar: measured
    /// offscreen with `NSHostingView`, Trends' ideal width was 699pt, and
    /// 699 of that was the coverage note's prose. None of these views
    /// declares a hard minimum width — they all shrink to zero — so the
    /// ideal is the only number in play.
    ///
    /// The default is a measure, not a magic number: ~560pt is roughly 90
    /// characters at this app's body size, the upper end of what reads
    /// comfortably. Pass a narrower one for captions.
    func proseWidth(_ measure: CGFloat = 560) -> some View {
        frame(maxWidth: measure, alignment: .leading)
    }
}

// MARK: - Severity colour

/// The one place the three health states become a colour, in whichever
/// framework the call site needs it in. Three views and the menu-bar dot
/// used to each make this decision for themselves; a fourth palette was a
/// fourth chance for the dot to disagree with the report it summarises.
extension Health {
    var tint: Color {
        switch self {
        case .healthy:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }

    /// AppKit form, for the menu-bar dot. See `MenuBarLabel.dot(for:)` for
    /// why that image is rasterised with an explicit `NSColor` rather than
    /// tinted with `tint` above.
    var nsColor: NSColor {
        switch self {
        case .healthy:  return .systemGreen
        case .warning:  return .systemYellow
        case .critical: return .systemRed
        }
    }
}
