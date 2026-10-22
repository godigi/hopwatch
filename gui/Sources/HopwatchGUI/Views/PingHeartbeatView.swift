import SwiftUI

/// Displays a live, continuous line graph "heartbeat" of network ping latency.
///
/// Features:
/// 1. Visual latency zones behind the graph:
///    - Top band (red wash): High latency (> 150 ms)
///    - Middle band (white): Moderate latency (70 – 150 ms)
///    - Bottom band (green wash): Optimal latency (< 70 ms)
/// 2. Interactive hover inspection: hovering over any point displays the exact ping latency
///    in a floating callout bubble and highlights the inspected probe.
/// 3. Prominent visualization of packet drops ("MISSes" / timeouts) with vertical red
///    dashed markers, drop indicators, and outage breaks.
/// 4. Quick target toggle: Internet (`1.1.1.1`) vs. Router gateway IP.
/// 5. Animated beating heart icon synced with packet arrivals.
/// 6. Live radar beacon ripples on the leading edge (newest probe) ticking every 1.0 second.
/// 7. Decimal-precision millisecond telemetry giving unmistakable, tangible confirmation of live ICMP traffic.
struct PingHeartbeatView: View {
    @Environment(HopwatchCoordinator.self) private var coordinator
    var customHeartbeat: PingHeartbeat? = nil

    @State private var heartScale: CGFloat = 1.0
    @State private var livePulseScale: CGFloat = 1.0
    @State private var hoveredBeat: PingBeat?
    @State private var hoverLocation: CGPoint?

    private var heartbeat: PingHeartbeat {
        customHeartbeat ?? coordinator.heartbeat
    }

    private var linkDown: Bool {
        coordinator.linkIsDown
    }

    private var isPaused: Bool {
        coordinator.monitor.isPausedForAnyReason
    }

    private var gatewayIP: String? {
        coordinator.liveSample?.link.gateway
            ?? coordinator.monitor.latest?.link.gateway
    }

    init(heartbeat: PingHeartbeat? = nil) {
        self.customHeartbeat = heartbeat
    }

    var body: some View {
        VStack(spacing: 6) {
            headerRow

            canvasArea
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                )

            footerStatsRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(
                    heartbeat.hasRecentMiss ? Theme.ColorToken.red.opacity(0.35) : Theme.ColorToken.line,
                    lineWidth: 1
                )
        )
        .onAppear {
            if !heartbeat.isRunning && !heartbeat.isPaused {
                heartbeat.start()
            }
        }
        .onChange(of: heartbeat.beatTick) { _, _ in
            triggerHeartPulse()
        }
    }

    // MARK: - 1. Header Row

    private var headerRow: some View {
        HStack(spacing: 6) {
            // Beating Heart Icon
            Image(systemName: linkDown ? "heart.slash.fill" : (heartbeat.latestBeat?.isMiss == true ? "exclamationmark.triangle.fill" : "heart.fill"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(heartIconColor)
                .scaleEffect(heartScale)

            Text("Ping Heartbeat")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.ink)

            // Live Cadence Badge
            liveCadenceBadge

            // Target Toggle Pill
            targetTogglePill

            Spacer()

            // Hovered Readout or Latest latency readout
            readoutView
        }
    }

    private var heartIconColor: Color {
        if linkDown { return .red }
        if isPaused { return Theme.ColorToken.muted }
        if heartbeat.latestBeat?.isMiss == true { return .red }
        guard let lat = heartbeat.latestBeat?.latencyMs else { return Theme.ColorToken.muted }
        if lat >= 150 { return Theme.ColorToken.red }
        if lat >= 70 { return Theme.ColorToken.amber }
        return Theme.ColorToken.green
    }

    private var liveCadenceBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(linkDown ? .red : (isPaused ? Theme.ColorToken.muted : Theme.ColorToken.green))
                .frame(width: 4.5, height: 4.5)
                .scaleEffect(livePulseScale)
            Text(isPaused ? "Paused" : "1s live")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.muted)
        }
        .padding(.horizontal, 4.5)
        .padding(.vertical, 1.5)
        .background(Theme.ColorToken.neutralWash)
        .clipShape(Capsule())
    }

    private var targetTogglePill: some View {
        Button {
            toggleTarget()
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(linkDown ? .red : (isPaused ? Theme.ColorToken.muted : Theme.ColorToken.green))
                    .frame(width: 4.5, height: 4.5)
                Text(heartbeat.target)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.muted)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Theme.ColorToken.muted.opacity(0.8))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.ColorToken.neutralWash)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to toggle ping target between Internet and Router Gateway")
    }

    private func toggleTarget() {
        if heartbeat.target == PingHeartbeat.defaultTarget {
            if let gw = gatewayIP, !gw.isEmpty {
                heartbeat.switchTarget(gw)
            }
        } else {
            heartbeat.switchTarget(PingHeartbeat.defaultTarget)
        }
    }

    @ViewBuilder
    private var readoutView: some View {
        if let hovered = hoveredBeat {
            // Hover inspection readout in header
            HStack(spacing: 4) {
                Text("Hover:")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.ColorToken.muted)
                if hovered.isMiss {
                    Text("MISS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                } else if let lat = hovered.latencyMs {
                    Text("\(formatLatency(lat)) ms")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(latencyColor(lat))
                }
            }
        } else if linkDown {
            Text("NO LINK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if isPaused {
            Text("PAUSED")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.muted)
        } else if let latest = heartbeat.latestBeat {
            if latest.isMiss {
                HStack(spacing: 2.5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                    Text("MISS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            } else if let lat = latest.latencyMs {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(formatLatency(lat))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(latencyColor(lat))
                    Text("ms")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }
        } else {
            Text("—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.muted)
        }
    }

    private func formatLatency(_ ms: Double) -> String {
        if ms < 100 {
            return String(format: "%.1f", ms)
        } else {
            return "\(Int(ms.rounded()))"
        }
    }

    private func latencyColor(_ ms: Double) -> Color {
        if ms < 70 { return Theme.ColorToken.green }
        if ms < 150 { return Theme.ColorToken.amber }
        return Theme.ColorToken.red
    }

    private func triggerHeartPulse() {
        withAnimation(.easeOut(duration: 0.12)) {
            heartScale = 1.28
            livePulseScale = 1.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
                heartScale = 1.0
                livePulseScale = 1.0
            }
        }
    }

    // MARK: - 2. Canvas Area

    @ViewBuilder
    private var canvasArea: some View {
        ZStack {
            if linkDown {
                // Link Down View
                ZStack {
                    Theme.ColorToken.nodeBackground
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.red.opacity(0.8))
                            .frame(height: 1.5)
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.horizontal.slash.fill")
                                .font(.system(size: 9))
                            Text("Connection lost — no packets returning")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
            } else if isPaused {
                // Paused Watermark
                ZStack {
                    Theme.ColorToken.nodeBackground
                    VStack(spacing: 2) {
                        Rectangle()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Color.gray.opacity(0.4))
                            .frame(height: 1)
                        Text("Monitoring paused")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.gray.opacity(0.6))
                    }
                }
            } else {
                let beats = heartbeat.recentBeats
                if beats.isEmpty {
                    ZStack {
                        Theme.ColorToken.nodeBackground
                        Text("Acquiring live heartbeat…")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                } else {
                    LinegraphZonedCanvas(
                        beats: beats,
                        beatTick: heartbeat.beatTick,
                        isPaused: isPaused,
                        linkDown: linkDown,
                        hoveredBeat: $hoveredBeat,
                        hoverLocation: $hoverLocation
                    )
                }
            }
        }
    }

    // MARK: - 3. Footer Stats Row

    private var footerStatsRow: some View {
        HStack {
            // Latency spread
            if let min = heartbeat.minLatency, let avg = heartbeat.avgLatency, let max = heartbeat.maxLatency {
                HStack(spacing: 4) {
                    Text("min \(formatLatency(min))ms")
                    Text("·")
                    Text("avg \(formatLatency(avg))ms")
                    Text("·")
                    Text("max \(formatLatency(max))ms")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.muted)
            } else {
                Text("Sampling every 1s")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.ColorToken.muted)
            }

            Spacer()

            // Reliability & Dropped packets counter
            if heartbeat.totalCount > 0 {
                HStack(spacing: 3) {
                    if heartbeat.missCount == 0 {
                        Circle()
                            .fill(Theme.ColorToken.green)
                            .frame(width: 4.5, height: 4.5)
                        Text("100% replied")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.ColorToken.green)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.ColorToken.red)
                        Text("\(heartbeat.missCount) missed (\(String(format: "%.1f", heartbeat.lossPct))%)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.red)
                    }
                }
            }
        }
    }
}

// MARK: - Linegraph Canvas with Three Latency Zones (Red Top, White Middle, Green Bottom)

private struct LinegraphZonedCanvas: View {
    let beats: [PingBeat]
    let beatTick: Int
    let isPaused: Bool
    let linkDown: Bool
    @Binding var hoveredBeat: PingBeat?
    @Binding var hoverLocation: CGPoint?

    @State private var beaconScale: CGFloat = 1.0
    @State private var beaconOpacity: Double = 0.0

    @Environment(\.colorScheme) private var colorScheme
    private static let targetSlots = 26

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let totalSlots = Self.targetSlots
            let beatWidth = w / CGFloat(totalSlots)

            // Zone boundaries in points
            let y150 = h * 0.33 // Red top / White middle boundary (>150ms)
            let y70 = h * 0.66  // White middle / Green bottom boundary (70-150ms)

            let paddedBeats: [PingBeat?] = {
                if beats.count >= totalSlots {
                    return Array(beats.suffix(totalSlots)).map { Optional($0) }
                } else {
                    let padding = Array(repeating: nil as PingBeat?, count: totalSlots - beats.count)
                    return padding + beats.map { Optional($0) }
                }
            }()

            ZStack(alignment: .topLeading) {
                // 1. Three Horizontal Latency Zone Bands
                zoneBackgroundBands(w: w, h: h, y150: y150, y70: y70)

                // 2. Zone Grid Divider Lines & Faint Threshold Labels
                zoneDividersAndLabels(w: w, h: h, y150: y150, y70: y70)

                // 3. Red Drop Highlights for MISSes
                ForEach(0..<paddedBeats.count, id: \.self) { idx in
                    if let beat = paddedBeats[idx], beat.isMiss {
                        let x = CGFloat(idx) * beatWidth
                        Rectangle()
                            .fill(Color.red.opacity(0.16))
                            .frame(width: beatWidth, height: h)
                            .position(x: x + beatWidth / 2, y: h / 2)
                    }
                }

                // 4. Connecting Latency Line (breaks on MISS/outages)
                Path { path in
                    var inSegment = false
                    for (idx, maybeBeat) in paddedBeats.enumerated() {
                        guard let beat = maybeBeat, let lat = beat.latencyMs, !beat.isMiss else {
                            inSegment = false
                            continue
                        }
                        let x = CGFloat(idx) * beatWidth + beatWidth / 2
                        let y = yForLatency(lat, height: h, y150: y150, y70: y70)

                        if !inSegment {
                            path.move(to: CGPoint(x: x, y: y))
                            inSegment = true
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(
                    Color(red: 0.12, green: 0.50, blue: 0.90),
                    style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                )

                // 5. Individual Ping Points & MISS Markers
                ForEach(0..<paddedBeats.count, id: \.self) { idx in
                    let x = CGFloat(idx) * beatWidth + beatWidth / 2
                    let isLatest = (idx == paddedBeats.count - 1)

                    if let beat = paddedBeats[idx] {
                        if beat.isMiss {
                            // Vertical dashed drop marker
                            Path { p in
                                p.move(to: CGPoint(x: x, y: 2))
                                p.addLine(to: CGPoint(x: x, y: h - 2))
                            }
                            .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: isLatest ? 2.0 : 1.5, dash: [3, 2]))

                            if isLatest && !isPaused && !linkDown {
                                Circle()
                                    .stroke(Color.red.opacity(beaconOpacity), lineWidth: 1.75)
                                    .frame(width: 12 * beaconScale, height: 12 * beaconScale)
                                    .position(x: x, y: h / 2)
                            }

                            // "✕" Drop badge
                            Text("✕")
                                .font(.system(size: isLatest ? 10 : 8.5, weight: .black))
                                .foregroundStyle(.red)
                                .position(x: x, y: h / 2)
                        } else if let lat = beat.latencyMs {
                            let y = yForLatency(lat, height: h, y150: y150, y70: y70)
                            let isHovered = (hoveredBeat?.id == beat.id)

                            ZStack {
                                if isLatest && !isPaused && !linkDown {
                                    // Animated Radar Beacon Ripple Ring
                                    Circle()
                                        .stroke(pointColor(lat).opacity(beaconOpacity), lineWidth: 1.5)
                                        .frame(width: 8 * beaconScale, height: 8 * beaconScale)

                                    // Glowing halo behind latest point
                                    Circle()
                                        .fill(pointColor(lat).opacity(0.35))
                                        .frame(width: 11, height: 11)
                                }

                                if isHovered {
                                    Circle()
                                        .stroke(Color.primary.opacity(0.7), lineWidth: 1.5)
                                        .frame(width: 10, height: 10)
                                }
                                Circle()
                                    .fill(pointColor(lat))
                                    .frame(width: isLatest ? 5.5 : (isHovered ? 6 : 4.5), height: isLatest ? 5.5 : (isHovered ? 6 : 4.5))
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: isLatest ? 1.0 : 0.75))
                            }
                            .position(x: x, y: y)
                        }
                    }
                }

                // 6. Interactive Hover Tooltip & Hairline Guide
                if let hovered = hoveredBeat, let loc = hoverLocation {
                    let hoveredIdx = Int(loc.x / beatWidth)
                    let x = CGFloat(hoveredIdx) * beatWidth + beatWidth / 2

                    // Vertical Hairline Snapping to Point
                    Rectangle()
                        .fill(Color.primary.opacity(0.20))
                        .frame(width: 1, height: h)
                        .position(x: x, y: h / 2)

                    // Floating Tooltip Bubble
                    hoverBubble(for: hovered, x: x, height: h, y150: y150, y70: y70)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    let idx = Int(location.x / beatWidth)
                    if idx >= 0 && idx < paddedBeats.count {
                        hoveredBeat = paddedBeats[idx]
                    } else {
                        hoveredBeat = nil
                    }
                case .ended:
                    hoverLocation = nil
                    hoveredBeat = nil
                }
            }
            .onChange(of: beatTick) { _, _ in
                triggerBeaconPulse()
            }
        }
    }

    private func triggerBeaconPulse() {
        beaconScale = 1.0
        beaconOpacity = 0.85
        withAnimation(.easeOut(duration: 0.85)) {
            beaconScale = 2.4
            beaconOpacity = 0.0
        }
    }

    // MARK: - Zone Background Bands

    private func zoneBackgroundBands(w: CGFloat, h: CGFloat, y150: CGFloat, y70: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Top Zone: High Latency (> 150ms) -> Soft Red
            Rectangle()
                .fill(
                    colorScheme == .dark
                        ? Color.red.opacity(0.15)
                        : Color(red: 0.99, green: 0.88, blue: 0.88).opacity(0.75)
                )
                .frame(width: w, height: y150)

            // Middle Zone: Moderate Latency (70 - 150ms) -> Clean White / Neutral
            Rectangle()
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.white
                )
                .frame(width: w, height: y70 - y150)

            // Bottom Zone: Good Latency (< 70ms) -> Soft Green
            Rectangle()
                .fill(
                    colorScheme == .dark
                        ? Color.green.opacity(0.14)
                        : Color(red: 0.88, green: 0.97, blue: 0.90).opacity(0.75)
                )
                .frame(width: w, height: h - y70)
        }
    }

    private func zoneDividersAndLabels(w: CGFloat, h: CGFloat, y150: CGFloat, y70: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 150ms dashed separator line
            Path { p in
                p.move(to: CGPoint(x: 0, y: y150))
                p.addLine(to: CGPoint(x: w, y: y150))
            }
            .stroke(Color.red.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

            // 70ms dashed separator line
            Path { p in
                p.move(to: CGPoint(x: 0, y: y70))
                p.addLine(to: CGPoint(x: w, y: y70))
            }
            .stroke(Color.green.opacity(0.30), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

            // Subtle zone watermarks on left
            Text("150ms")
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.red.opacity(0.6))
                .position(x: 16, y: y150 - 5)

            Text("70ms")
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.muted.opacity(0.7))
                .position(x: 14, y: y70 - 5)
        }
    }

    // MARK: - Hover Callout Bubble

    @ViewBuilder
    private func hoverBubble(for beat: PingBeat, x: CGFloat, height: CGFloat, y150: CGFloat, y70: CGFloat) -> some View {
        let yPoint: CGFloat = {
            if let lat = beat.latencyMs {
                return yForLatency(lat, height: height, y150: y150, y70: y70)
            }
            return height / 2
        }()

        // Display above the point, or below if point is near the top
        let bubbleY: CGFloat = yPoint < 22 ? yPoint + 16 : yPoint - 14

        Group {
            if beat.isMiss {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 7.5))
                    Text("MISS (Timeout)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Color.red)
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
            } else if let lat = beat.latencyMs {
                HStack(spacing: 2) {
                    Circle()
                        .fill(pointColor(lat))
                        .frame(width: 4, height: 4)
                    Text("\(formatLatency(lat)) ms")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.ink)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Theme.ColorToken.nodeBackground)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.ColorToken.line, lineWidth: 0.75))
                .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
            }
        }
        .position(x: min(max(x, 40), 380), y: bubbleY)
    }

    private func formatLatency(_ ms: Double) -> String {
        if ms < 100 {
            return String(format: "%.1f", ms)
        } else {
            return "\(Int(ms.rounded()))"
        }
    }

    // MARK: - Y-Positioning Math (Zone-Aware Mapping)

    private func yForLatency(_ ms: Double, height: CGFloat, y150: CGFloat, y70: CGFloat) -> CGFloat {
        let topMargin: CGFloat = 6
        let bottomMargin: CGFloat = 6

        if ms <= 70.0 {
            // Green Zone: 0ms to 70ms -> mapped from (height - bottomMargin) up to y70
            let t = max(0.0, ms) / 70.0
            let yBottom = height - bottomMargin
            return yBottom - CGFloat(t) * (yBottom - y70)
        } else if ms <= 150.0 {
            // White Zone: 70ms to 150ms -> mapped from y70 up to y150
            let t = (ms - 70.0) / 80.0
            return y70 - CGFloat(t) * (y70 - y150)
        } else {
            // Red Zone: 150ms to 300ms -> mapped from y150 up to topMargin
            let t = min(1.0, (ms - 150.0) / 150.0)
            return y150 - CGFloat(t) * (y150 - topMargin)
        }
    }

    private func pointColor(_ ms: Double) -> Color {
        if ms < 70 { return Color(red: 0.10, green: 0.75, blue: 0.45) }
        if ms < 150 { return Color(red: 0.95, green: 0.65, blue: 0.10) }
        return Color(red: 0.95, green: 0.30, blue: 0.30)
    }
}
