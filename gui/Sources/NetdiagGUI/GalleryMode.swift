import SwiftUI
import AppKit
import Foundation

/// The app's screenshot harness, reached with `--gallery[=DIR]`.
///
/// ── Why this exists ────────────────────────────────────────────────────
/// This machine has no Xcode, so it has no SwiftUI previews (see
/// `Package.swift`'s header). The dev loop that stands in for them was
/// `make run` — launch the bundle and look at it — which works for a human
/// and not at all for anything that cannot see a screen. The two prior
/// attempts at closing that gap both fell short in the same way:
///
///   * `--verify`'s `runSnapshots()` renders a hand-written *stand-in* of
///     the dropdown's stage card. It proves the stage→colour mapping, and
///     its own header admits it is "not a pixel-identical snapshot of
///     `DropdownView`". A stand-in cannot show a layout bug, because the
///     layout it draws is not the one that ships.
///   * `TempLayoutDump` walked the real window's `NSView` tree and printed
///     frames, so "the sidebar is collapsed" could be told apart from "the
///     sidebar is empty" — numbers about a picture, in place of the picture.
///
/// This renders the **real views**, the ones `NetdiagApp` instantiates,
/// against the **real on-disk state** — so what comes out is what the app
/// actually looks like right now on this Mac, not a fixture's idea of it.
///
/// ── Why not screen capture ─────────────────────────────────────────────
/// `screencapture -l` and `CGWindowListCreateImage` both need the Screen
/// Recording TCC grant, which is per-binary, survives poorly across the
/// ad-hoc signing the Makefile warns about, and cannot be granted
/// non-interactively. `cacheDisplay(in:to:)` asks the view to draw itself
/// into a bitmap and needs no permission at all.
///
/// ── Why a real window and not `ImageRenderer` ──────────────────────────
/// `ImageRenderer` is the obvious tool and the wrong one here: it renders
/// a detached view graph, and every AppKit-backed SwiftUI control —
/// `List` (NSTableView), `ScrollView`, `Table` — draws empty or collapsed
/// without a window to belong to. `ActivityView`, the densest screen in
/// the app, is a `List`. So each view is hosted in a genuine `NSWindow`
/// parked far off the visible desktop, given a few run-loop turns to lay
/// out and fetch, and then asked to draw itself.
///
/// ── What this is not ───────────────────────────────────────────────────
/// Not a test. Nothing here asserts; there are no thresholds and no
/// pass/fail. It is a window onto the app for a reader who has no screen —
/// `--verify` remains the harness that *judges*.
@MainActor
enum GalleryMode {

    /// Present in the launch arguments? `--gallery` or `--gallery=DIR`.
    static var isRequested: Bool { directoryArgument != nil }

    private static var directoryArgument: String? {
        for argument in CommandLine.arguments {
            if argument == "--gallery" { return defaultDirectory }
            if argument.hasPrefix("--gallery=") {
                let value = String(argument.dropFirst("--gallery=".count))
                return value.isEmpty ? defaultDirectory : value
            }
        }
        return nil
    }

    private static let defaultDirectory = "/tmp/netdiag-gallery"

    /// Queue the render and return, letting AppKit launch normally.
    ///
    /// The obvious shape — do the work right here in
    /// `applicationWillFinishLaunching` and never return, spinning a nested
    /// `RunLoop.run()` so no SwiftUI scene is ever created — is the shape
    /// this started with, and it silently produced empty screens.
    /// `NSApp.run()` is not merely a run loop: it is what pumps
    /// `nextEventMatchingMask` and drives the window update cycle, and
    /// SwiftUI's `List` builds its `NSTableView` rows off that cycle. With
    /// AppKit's loop never entered, `ActivityView` laid out at the right
    /// size, drew its heading, and reported `numberOfRows == 0` against a
    /// store holding 329 events.
    ///
    /// So the app launches for real and the render runs as an ordinary task
    /// on the live event loop. What keeps that safe is `bootstrap()`'s
    /// `--gallery` guard, which is what actually prevents the monitor child
    /// from spawning — the nested loop was only ever an indirect way of
    /// achieving that, at the cost of the pictures being blank.
    static func scheduleIfRequested() -> Bool {
        guard isRequested else { return false }
        let directory = directoryArgument ?? defaultDirectory
        NSApp?.setActivationPolicy(.accessory)
        Task { @MainActor in
            await renderAll(into: directory)
            exit(0)
        }
        return true
    }

    // MARK: - The catalogue

    /// One screen to draw: a name, a size, and how to build it.
    ///
    /// Sizes are the app's own: 360pt is the width `NetdiagApp` gives the
    /// dropdown, 920×680 its `defaultSize` for the dashboard, 520×560 for
    /// Settings. A gallery rendered at invented sizes would show layout
    /// that no user ever gets.
    private struct Screen {
        let name: String
        let size: NSSize
        let build: () -> AnyView
    }

    private static func screens(_ coordinator: NetdiagCoordinator) -> [Screen] {
        func wrap<V: View>(_ view: V) -> AnyView {
            AnyView(view
                .environment(coordinator)
                .environment(coordinator.appSettings)
                // The backdrop is applied *in SwiftUI*, not as the window's
                // `backgroundColor`. `NSColor.windowBackgroundColor` is
                // dynamic and resolves against the appearance current at
                // draw time, not against the window it was assigned to, so
                // setting it on the window painted a light backdrop behind
                // dark-mode content: `ActivityView`'s heading came out as
                // white-on-white and read as a real contrast bug in the app.
                // SwiftUI resolves the same colour through its own
                // `colorScheme`, which does follow the window's appearance.
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        return [
            // The one the memory note says cannot be screenshotted: a
            // MenuBarExtra panel is not in the window list, so no capture
            // tool can reach it. Hosted directly, it draws like anything else.
            Screen(name: "dropdown", size: NSSize(width: 360, height: 620)) {
                wrap(DropdownView().frame(width: 360))
            },
            Screen(name: "main-window", size: NSSize(width: 920, height: 680)) {
                wrap(MainWindow())
            },
            Screen(name: "activity", size: NSSize(width: 700, height: 680)) {
                wrap(ActivityView())
            },
            Screen(name: "home", size: NSSize(width: 700, height: 680)) {
                wrap(HomeView())
            },
            Screen(name: "live", size: NSSize(width: 700, height: 680)) {
                wrap(LiveView())
            },
            Screen(name: "trends", size: NSSize(width: 700, height: 680)) {
                wrap(TrendsView())
            },
            Screen(name: "networks", size: NSSize(width: 700, height: 680)) {
                wrap(NetworksView())
            },
            Screen(name: "settings", size: NSSize(width: 520, height: 560)) {
                wrap(SettingsView())
            },
        ]
    }

    // MARK: - Driving it

    private static func renderAll(into directory: String) async {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        let coordinator = NetdiagCoordinator()
        await hydrate(coordinator)

        print("netdiag gallery → \(directory)")
        print("state: \(coordinator.eventLog.events.count) events, "
              + "\(coordinator.history.document.networks.count) networks, "
              + "\(coordinator.alerts.activeSorted.count) active alerts")
        print("")

        // `--gallery-only=NAME[,NAME]` narrows the run to named screens.
        // A full pass is ~16 windows and several seconds of settling;
        // when one screen is misbehaving, iterating on it alone is the
        // difference between a 2-second loop and a 20-second one.
        let only: Set<String> = CommandLine.arguments
            .first { $0.hasPrefix("--gallery-only=") }
            .map { Set($0.dropFirst("--gallery-only=".count)
                        .split(separator: ",").map(String.init)) } ?? []

        for screen in screens(coordinator) where only.isEmpty || only.contains(screen.name) {
            for appearance in Appearance.both {
                let path = "\(directory)/\(screen.name)-\(appearance.suffix).png"
                if let image = await render(screen.build(), size: screen.size,
                                            appearance: appearance) {
                    write(image, to: path)
                } else {
                    print("  ✘ \(screen.name) [\(appearance.suffix)] — no bitmap")
                }
            }
        }
    }

    /// Load the same state `start()` would, minus everything that acts.
    ///
    /// Deliberately partial: `history.load()`, the rules catalog and the
    /// signal scale are reads, and reads are what the views render from.
    /// `monitor.start()`, `events.start()`, the workspace observers, the
    /// notification authorisation prompt and the first-sighting auto-scan
    /// are all writes — of processes, of TCC prompts, of `seenNetworks` —
    /// and a screenshot run must cause none of them.
    private static func hydrate(_ coordinator: NetdiagCoordinator) async {
        coordinator.rulesCatalog.ensureLoaded()
        coordinator.signalScale.ensureLoaded()
        await coordinator.history.load()
        await coordinator.rulesCatalog.refresh()
        await coordinator.hydrateFromHistoryIfNeeded()
        // `start()` also calls `eventLog.rephraseLegacyRuleEvents` here.
        // Deliberately skipped: it can rewrite `events.json`, and this
        // paragraph's whole claim is that a screenshot run writes nothing.
        // The cost is that a store still holding pre-catalog "Issue G2
        // detected" phrasing would render that way in the gallery — which
        // is the honest picture of a store in that state anyway.
    }

    // MARK: - Appearance

    private struct Appearance {
        let suffix: String
        let name: NSAppearance.Name
        static let both = [
            Appearance(suffix: "light", name: .aqua),
            Appearance(suffix: "dark", name: .darkAqua),
        ]
    }

    // MARK: - Rendering

    /// Host `view` in a real window, let it settle, and draw it into a
    /// bitmap.
    ///
    /// The window is placed at a genuine screen origin, not parked
    /// off-desktop: AppKit gives no display pass to a window that
    /// intersects no screen, and without one SwiftUI's `List` never builds
    /// its rows. It is ordered out again immediately, and with `.accessory`
    /// activation it never steals focus for more than the render.
    private static func render(_ view: AnyView, size: NSSize,
                               appearance: Appearance) async -> NSImage? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let origin = NSScreen.main.map {
            NSPoint(x: $0.frame.minX, y: $0.frame.minY)
        } ?? .zero
        // Borderless, with one known limitation recorded rather than
        // papered over: `MainWindow` is a `NavigationSplitView`, and its
        // sidebar renders empty here. That is a property of hosting it in
        // a borderless window, not a claim about the shipped app — the
        // obvious fix, a `.titled` + `.fullSizeContentView` window, renders
        // the whole dashboard blank instead, so this harness cannot
        // currently vouch for the sidebar either way. The five destination
        // views are each rendered standalone below, which is where their
        // content can be trusted; `main-window` is useful for the content
        // column and should not be read as evidence about the sidebar.
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance.name)
        window.contentView = hosting
        // Opaque, because a transparent backing store captures the app's
        // own vibrancy as alpha and the PNG comes out see-through — which
        // reads as a rendering bug in the app rather than in this harness.
        // The visible backdrop is drawn in SwiftUI instead; see `wrap`.
        window.isOpaque = true
        window.makeKeyAndOrderFront(nil)

        await settle()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await settle()

        if CommandLine.arguments.contains("--gallery-debug") {
            describe(hosting, depth: 0)
        }

        defer { window.orderOut(nil) }
        return capture(hosting, size: size)
    }

    /// Draw a view into a bitmap sized to the window's backing store, so
    /// the PNG is Retina-sharp rather than a 1x approximation of a 2x
    /// screen — small type in the report card is otherwise unreadable.
    private static func capture(_ view: NSView, size: NSSize) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Print the structural bits of a hosted hierarchy — scroll views,
    /// table views, row counts, layer-backing. Reached with
    /// `--gallery --gallery-debug`, and the thing to run first when a
    /// screen comes out blank: it separates "the view drew nothing"
    /// from "the capture missed what it drew".
    private static func describe(_ view: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let name = String(describing: type(of: view))
        if name.contains("Scroll") || name.contains("Table")
            || name.contains("Clip") || name.contains("Hosting") {
            print("\(pad)\(name) frame=\(view.frame) layer=\(view.layer != nil) "
                  + "wantsLayer=\(view.wantsLayer) hidden=\(view.isHidden)")
        }
        if let table = view as? NSTableView {
            print("\(pad)  → rows=\(table.numberOfRows)")
        }
        for sub in view.subviews { describe(sub, depth: depth + 1) }
    }

    /// Yield to AppKit long enough for the view graph to lay out and for
    /// `List`'s table view to ask for its rows.
    ///
    /// `await Task.sleep` rather than a nested `RunLoop.run`: sleeping
    /// returns control to `NSApp.run()`, which is the loop that actually
    /// drives window updates. Nesting a run loop here reproduces the
    /// original empty-`List` bug in miniature.
    private static func settle(_ seconds: Double = 0.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func write(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("  ✘ \(path) — could not encode PNG")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("  ✔ \(path)")
        } catch {
            print("  ✘ \(path) — \(error.localizedDescription)")
        }
    }
}
