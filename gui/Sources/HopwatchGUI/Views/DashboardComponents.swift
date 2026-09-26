import SwiftUI
import AppKit
import Charts

// MARK: - 1. Page Heading

struct DashboardHeadingView: View {
    let networkName: String?
    let isWiFi: Bool
    let isScanning: Bool
    let onRunFullCheck: () -> Void
    let onCancelScan: () -> Void
    let onCopyRedacted: () -> Void
    let onCopySupport: () -> Void
    let onSaveMarkdown: () -> Void
    let onSaveJSON: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your connection, hop by hop.")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)

                HStack(spacing: 6) {
                    Image(systemName: isWiFi ? "wifi" : "cable.connector")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text(networkName ?? "Disconnected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.line)
                    Text(isWiFi ? "Wi-Fi" : "Ethernet")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Menu {
                    Button("Copy redacted report", action: onCopyRedacted)
                    Button("Copy for support / front desk", action: onCopySupport)
                    Divider()
                    Button("Save Markdown…", action: onSaveMarkdown)
                    Button("Save redacted JSON…", action: onSaveJSON)
                    Divider()
                    Text("Network name, IP addresses and precise location are masked.")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text("Share diagnostics")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if isScanning {
                    Button(action: onCancelScan) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Cancel check")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.ColorToken.nodeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onRunFullCheck) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Run full check")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.ColorToken.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 2. Status Hero Banner

struct DashboardStatusHeroView: View {
    let iconName: String
    let iconTint: Color
    let iconBackground: Color
    let headline: String
    let subtitle: String
    var detectedTime: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.statusIcon)
                    .fill(iconBackground)
                    .frame(width: 32, height: 32)
                Image(systemName: iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineLimit(2)
            }

            if let actionTitle, let onAction {
                Spacer()
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if let detectedTime, !detectedTime.isEmpty {
                Spacer()
                Text(detectedTime)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.quiet)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(iconBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(iconTint.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - 3. Connection Path Panel

struct DashboardRouteView: View {
    let wifiSignalText: String
    let wifiSignalDetail: String
    let wifiSignalTint: Color
    var wifiPHY: String? = nil
    var wifiSNR: String? = nil
    let macIP: String
    let routerPingText: String
    let routerPingTint: Color
    let routerWarn: Bool
    let routerIP: String
    let routerLossText: String
    let routerJitterText: String
    var routerLoadedDelta: String? = nil
    let internetPingText: String
    let internetPingTint: Color
    let internetWarn: Bool
    let countryFlag: String?
    let countryName: String?
    var ispName: String? = nil
    let internetLossText: String
    let internetJitterText: String
    var internetLoadedDelta: String? = nil
    let bandChannelText: String
    let vpnActive: Bool
    let vpnProvider: String?
    let publicIP: String?
    let pingTarget: String?
    var pingTargetAlt: String? = nil
    var culpritHop: String? = nil
    var routerAdminURL: URL? = nil
    var routerAdminAvailable: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                Text("Connection path")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Text("Live readings · loss over the last 60 seconds")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // 3-Hop Route
            ZStack {
                GeometryReader { geo in
                    let w = geo.size.width
                    let hopWidth = w / 3.0
                    let x1 = hopWidth * 0.5
                    let x2 = hopWidth * 1.5
                    let x3 = hopWidth * 2.5
                    let lineY: CGFloat = 84

                    // Dashed line hop1 -> hop2
                    Path { path in
                        path.move(to: CGPoint(x: x1 + 28, y: lineY))
                        path.addLine(to: CGPoint(x: x2 - 28, y: lineY))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(routerWarn ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.green.opacity(0.6))

                    // Dashed line hop2 -> hop3
                    Path { path in
                        path.move(to: CGPoint(x: x2 + 28, y: lineY))
                        path.addLine(to: CGPoint(x: x3 - 28, y: lineY))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(internetWarn ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.green.opacity(0.6))

                    // Intermediate labels
                    Text("Wi-Fi · local connection")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .position(x: (x1 + x2) / 2.0, y: lineY + 14)

                    Text("Broadband · internet connection")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .position(x: (x2 + x3) / 2.0, y: lineY + 14)
                }

                HStack(alignment: .top, spacing: 0) {
                    // Hop 1: This Mac
                    VStack(spacing: 3) {
                        VStack(spacing: 2) {
                            Text("Wi-Fi signal")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(wifiSignalText)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(wifiSignalTint)
                                Text(wifiSignalDetail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }
                        .frame(height: 54)

                        hopNode(icon: "laptopcomputer", isWarning: false, flag: nil, isCulprit: false)

                        Text("This Mac")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 7)

                        Text(macIP)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.muted)
                            .lineLimit(1)

                        if let phy = wifiPHY {
                            Text(phy)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.ColorToken.quiet)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Hop 2: Router
                    VStack(spacing: 3) {
                        VStack(spacing: 2) {
                            Text("Router ping")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(routerPingText)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(routerPingTint)
                                Text("ms")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }
                        .frame(height: 54)

                        hopNode(icon: "network", isWarning: routerWarn, flag: nil, isCulprit: culpritHop == "router")

                        Text("Router")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 7)

                        if routerAdminAvailable, let routerAdminURL {
                            Button {
                                NSWorkspace.shared.open(routerAdminURL)
                            } label: {
                                HStack(spacing: 2) {
                                    Text("\(routerIP) · gateway")
                                        .underline()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8))
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Open router admin page (\(routerAdminURL.absoluteString))")
                        } else {
                            Text("\(routerIP) · gateway")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(routerWarn ? Theme.ColorToken.amber : Theme.ColorToken.muted)
                                .lineLimit(1)
                        }

                        if let delta = routerLoadedDelta {
                            Text("Load: \(delta)")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.ColorToken.quiet)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Hop 3: Internet
                    VStack(spacing: 3) {
                        VStack(spacing: 2) {
                            Text("Internet ping")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(internetPingText)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(internetPingTint)
                                Text("ms")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }
                        .frame(height: 54)

                        hopNode(icon: "globe", isWarning: internetWarn, flag: countryFlag, isCulprit: culpritHop == "internet")

                        Text("Internet")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 7)

                        if let isp = ispName, !isp.isEmpty {
                            Text(isp)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.ColorToken.ink)
                                .lineLimit(1)
                        } else if let countryName, !countryName.isEmpty {
                            Text(countryName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.ink)
                                .lineLimit(1)
                        } else {
                            Text("Public WAN")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }

                        if let delta = internetLoadedDelta {
                            Text("Load: \(delta)")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.ColorToken.quiet)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 10)

            // Route Metrics 3-Column Bar
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(bandChannelText)
                    if let snr = wifiSNR {
                        Text("· SNR \(snr)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 18)

                HStack(spacing: 5) {
                    Text("Loss")
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text(routerLossText)
                        .fontWeight(.semibold)
                        .foregroundStyle(routerLossText == "0%" ? Theme.ColorToken.ink : Theme.ColorToken.amber)
                    Text("· Jitter")
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text(routerJitterText)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ColorToken.ink)
                    if let delta = routerLoadedDelta {
                        Text("· \(delta)")
                            .foregroundStyle(Theme.ColorToken.quiet)
                    }
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 18)

                HStack(spacing: 5) {
                    Text("Loss")
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text(internetLossText)
                        .fontWeight(.semibold)
                        .foregroundStyle(internetLossText == "0%" ? Theme.ColorToken.ink : Theme.ColorToken.amber)
                    Text("· Jitter")
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text(internetJitterText)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ColorToken.ink)
                    if let delta = internetLoadedDelta {
                        Text("· \(delta)")
                            .foregroundStyle(Theme.ColorToken.quiet)
                    }
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }

            // Bottom VPN & Targets Context Row
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(vpnActive ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                    Text(vpnActive ? "VPN on" : "VPN off")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(vpnActive ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                    if let vpnProvider, !vpnProvider.isEmpty {
                        Text("· \(vpnProvider)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }

                Spacer()

                HStack(spacing: 16) {
                    if let publicIP, !publicIP.isEmpty {
                        HStack(spacing: 4) {
                            Text("Public IP")
                                .foregroundStyle(Theme.ColorToken.muted)
                            Text(publicIP)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.ColorToken.ink)
                        }
                    }

                    if let pingTarget, !pingTarget.isEmpty {
                        HStack(spacing: 4) {
                            Text("Ping targets")
                                .foregroundStyle(Theme.ColorToken.muted)
                            let targets = pingTargetAlt != nil ? "\(pingTarget) / \(pingTargetAlt!)" : pingTarget
                            Text(targets)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.ColorToken.ink)
                        }
                    }
                }
                .font(.system(size: 10))
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 9)
            .background(vpnActive ? Theme.ColorToken.blueWash : Theme.ColorToken.footerBackground)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func hopNode(icon: String, isWarning: Bool, flag: String?, isCulprit: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isWarning ? Theme.ColorToken.amberWash : Theme.ColorToken.nodeBackground)
                .frame(width: 44, height: 44)
                .overlay(
                    Circle()
                        .strokeBorder(isCulprit ? Theme.ColorToken.red : (isWarning ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.line), lineWidth: isCulprit ? 2 : 1)
                )
                .shadow(color: isCulprit ? Theme.ColorToken.red.opacity(0.15) : Color.black.opacity(0.04), radius: isCulprit ? 5 : 3, y: 1)

            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isCulprit ? Theme.ColorToken.red : (isWarning ? Theme.ColorToken.amber : Theme.ColorToken.green))

            // Status Check or Warning Badge
            Circle()
                .fill(isCulprit ? Theme.ColorToken.red : (isWarning ? Theme.ColorToken.amber : Theme.ColorToken.green))
                .frame(width: 15, height: 15)
                .overlay(
                    Image(systemName: isWarning ? "exclamationmark" : "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                )
                .offset(x: 16, y: 16)

            // Optional Culprit Banner
            if isCulprit {
                Text("Issue source")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Theme.ColorToken.red)
                    .clipShape(Capsule())
                    .offset(y: -26)
            }

            // Optional Flag Badge on Internet Node
            if let flag, !flag.isEmpty {
                Text(flag)
                    .font(.system(size: 12))
                    .padding(2)
                    .background(Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                    )
                    .offset(x: 18, y: -16)
            }
        }
        .frame(width: 44, height: 44)
    }
}

// MARK: - 4. Live Ping Chart Panel

struct DashboardLiveChartPanel: View {
    let samples: [MonitorSample]
    @Binding var selectedWindowMinutes: Int
    let isBursting: Bool
    let onToggleBurst: () -> Void

    private var filteredSamples: [MonitorSample] {
        let cutoff = Date().addingTimeInterval(-Double(selectedWindowMinutes) * 60)
        return samples.filter { $0.timestamp >= cutoff }
    }

    private var internetSeries: MonitorSeries.Result {
        MonitorSeries.build(filteredSamples, tier: "medium") { sample in
            sample.status.icmpFiltered ? nil : sample.internet.rttAvgMs
        }
    }

    private var routerSeries: MonitorSeries.Result {
        MonitorSeries.build(filteredSamples, tier: "fast") { sample in
            sample.gateway.rttAvgMs
        }
    }

    private var internetStats: (min: Double, avg: Double, max: Double)? {
        let segments = internetSeries.segments
        var minVal = Double.infinity
        var maxVal = -Double.infinity
        var sum = 0.0
        var count = 0
        for segment in segments {
            for point in segment {
                let v = point.value
                if v < minVal { minVal = v }
                if v > maxVal { maxVal = v }
                sum += v
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (minVal, sum / Double(count), maxVal)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ping over time")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("Live samples · last hour retained")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()

                // Range Selector
                HStack(spacing: 2) {
                    segmentButton(title: "15m", value: 15)
                    segmentButton(title: "1h", value: 60)
                }
                .padding(2)
                .background(Theme.ColorToken.neutralWash)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Chart Legend
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.ColorToken.blue)
                        .frame(width: 14, height: 3)
                    Text("Internet")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.ColorToken.amber)
                        .frame(width: 14, height: 3)
                    Text("Router")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // The Chart
            if filteredSamples.isEmpty {
                VStack {
                    Text("No samples in this window")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 145)
            } else {
                Chart {
                    ForEach(internetSeries.identifiedSegments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Ping", point.value),
                                series: .value("Series", "Internet-\(segment.id.timeIntervalSinceReferenceDate)")
                            )
                            .foregroundStyle(Theme.ColorToken.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.75))
                        }
                    }

                    ForEach(routerSeries.identifiedSegments) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Ping", point.value),
                                series: .value("Series", "Router-\(segment.id.timeIntervalSinceReferenceDate)")
                            )
                            .foregroundStyle(Theme.ColorToken.amber)
                            .lineStyle(StrokeStyle(lineWidth: 1.75))
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            .foregroundStyle(Theme.ColorToken.line)
                        AxisValueLabel {
                            if let intVal = value.as(Double.self) {
                                Text("\(Int(intVal))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Theme.ColorToken.line)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                .frame(height: 145)
                .padding(.horizontal, 14)
            }

            // Chart Foot
            HStack {
                Text("Internet min / avg / max")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                Spacer()
                if let stats = internetStats {
                    Text("\(Int(round(stats.min))) / \(Int(round(stats.avg))) / \(Int(round(stats.max))) ms")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.ink)
                } else {
                    Text("— / — / —")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }

            // Chart Actions Bar
            HStack {
                Text("Response time in ms · lower is better")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)

                Spacer()

                Button(action: onToggleBurst) {
                    Text(isBursting ? "Stop latency test" : "Start latency test")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.ColorToken.nodeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.ColorToken.footerBackground)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func segmentButton(title: String, value: Int) -> some View {
        Button {
            selectedWindowMinutes = value
        } label: {
            Text(title)
                .font(.system(size: 10, weight: selectedWindowMinutes == value ? .semibold : .regular))
                .foregroundStyle(selectedWindowMinutes == value ? Theme.ColorToken.ink : Theme.ColorToken.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(selectedWindowMinutes == value ? Theme.ColorToken.nodeBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: selectedWindowMinutes == value ? Color.black.opacity(0.05) : Color.clear, radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 5. Findings & Next Steps Panel

struct DashboardFindingsPanel: View {
    struct FindingItem: Identifiable {
        let id: String
        let title: String
        let explanation: String
        let nextStep: String?
        let isWarning: Bool
    }

    let checkTime: String?
    let findings: [FindingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel Head
            HStack {
                Text("Findings & next steps")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                if let checkTime, !checkTime.isEmpty {
                    Text(checkTime)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if findings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ColorToken.green)
                        Text("No active issues detected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }
                    Text("Connection latency and stability are within healthy thresholds.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .padding(.leading, 21)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(findings.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 {
                            Divider().foregroundStyle(Theme.ColorToken.line)
                                .padding(.vertical, 10)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: item.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.isWarning ? Theme.ColorToken.amber : Theme.ColorToken.blue)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                            }

                            if !item.explanation.isEmpty {
                                Text(item.explanation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                                    .lineSpacing(2)
                                    .padding(.leading, 20)
                            }

                            if let nextStep = item.nextStep, !nextStep.isEmpty {
                                Text(nextStep)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                    .padding(.leading, 20)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }
}

// MARK: - 6. Check Details Table

struct DashboardCheckTable: View {
    enum GradeTone: Equatable, Sendable {
        case good
        case warn
        case critical
        case neutral

        var foreground: Color {
            switch self {
            case .good: return Theme.ColorToken.green
            case .warn: return Theme.ColorToken.amber
            case .critical: return Theme.ColorToken.red
            case .neutral: return Theme.ColorToken.muted
            }
        }

        var background: Color {
            switch self {
            case .good: return Theme.ColorToken.greenWash
            case .warn: return Theme.ColorToken.amberWash
            case .critical: return Theme.ColorToken.redWash
            case .neutral: return Theme.ColorToken.neutralWash
            }
        }
    }

    struct GradeBadge: Equatable, Sendable {
        let label: String
        let tone: GradeTone
    }

    struct Row: Identifiable {
        let id: String
        let icon: String
        let label: String
        let measured: String
        let subvalue: String?
        let usual: String
        let badge: GradeBadge?
        let isWarning: Bool
        let isGood: Bool

        init(id: String, icon: String, label: String, measured: String, subvalue: String? = nil, usual: String, badge: GradeBadge? = nil, isWarning: Bool = false, isGood: Bool = false) {
            self.id = id
            self.icon = icon
            self.label = label
            self.measured = measured
            self.subvalue = subvalue
            self.usual = usual
            self.badge = badge
            self.isWarning = isWarning
            self.isGood = isGood
        }
    }

    let checkSubtitle: String
    let networkSSID: String?
    let vpnActive: Bool
    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.clipboard.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.blue)
                        Text("Check details & evidence")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }
                    Text(checkSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()

                Text("Saved result")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.ColorToken.neutralWash)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Table Header
            HStack(spacing: 0) {
                Text("Measurement")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Measured & State")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Usual")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.ColorToken.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.ColorToken.footerBackground)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }
            .overlay(alignment: .bottom) { Divider().foregroundStyle(Theme.ColorToken.line) }

            // Table Rows
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(alignment: .center, spacing: 0) {
                        // Label
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: row.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(row.isWarning ? Theme.ColorToken.amber : (row.isGood ? Theme.ColorToken.green : Theme.ColorToken.muted))
                                .frame(width: 14)
                            Text(row.label)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Measured & Grade Badge
                        HStack(alignment: .center, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.measured)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(row.isWarning ? Theme.ColorToken.amber : Theme.ColorToken.ink)
                                if let sub = row.subvalue {
                                    Text(sub)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Theme.ColorToken.muted)
                                }
                            }

                            Spacer(minLength: 4)

                            if let badge = row.badge {
                                Text(badge.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(badge.tone.foreground)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(badge.tone.background)
                                    .clipShape(Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Usual
                        Text(row.usual)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.muted)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)

                    if idx < rows.count - 1 {
                        Divider().foregroundStyle(Theme.ColorToken.line.opacity(0.6))
                    }
                }
            }

            // Check Note Footer
            VStack(alignment: .leading, spacing: 3) {
                Text("Packet loss covers two destinations. “Usual” is this network’s median from saved checks; VPN and route changes can affect the comparison.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineSpacing(2)

                HStack(spacing: 4) {
                    Text("Saved on \(networkSSID ?? "current network") · \(vpnActive ? "VPN on." : "VPN off.")")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("Live readings are shown above.")
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .font(.system(size: 10))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ColorToken.footerBackground)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }
}

// MARK: - 7. Vitals Cards (Speed & Reliability)

struct DashboardSpeedCard: View {
    let downMbps: String
    let upMbps: String
    let testedMeta: String?
    let isScanning: Bool
    let onRunSpeedTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.blue)
                    Text("Throughput & Speed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                }

                Spacer()

                Button(action: onRunSpeedTest) {
                    HStack(spacing: 4) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Testing…")
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                            Text("Test Speed")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.ColorToken.blueWash)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
            }

            // Speed Metrics
            HStack(spacing: 16) {
                // Download
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ColorToken.green)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(downMbps)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(downMbps == "—" ? Theme.ColorToken.muted : Theme.ColorToken.ink)
                            Text("Mbps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        Text("Download")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 32)

                // Upload
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.ColorToken.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(upMbps)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(upMbps == "—" ? Theme.ColorToken.muted : Theme.ColorToken.ink)
                            Text("Mbps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        Text("Upload")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Subtitle
            Text(testedMeta ?? "Run a full check to test download and upload speed.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }
}

struct DashboardReliabilityCard: View {
    let observationSummary: String
    let outageCount: String
    let totalDowntime: String
    let longestOutage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.green)
                Text("Connection Reliability")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
            }

            // Metrics in a row
            HStack(spacing: 0) {
                metric(title: outageCount, subtitle: "Recorded drops")
                    .frame(maxWidth: .infinity)

                Divider().frame(height: 32)

                metric(title: totalDowntime, subtitle: "Total downtime")
                    .frame(maxWidth: .infinity)

                Divider().frame(height: 32)

                metric(title: longestOutage, subtitle: "Longest outage")
                    .frame(maxWidth: .infinity)
            }

            // Subtitle
            Text(observationSummary)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func metric(title: String, subtitle: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.ink)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
        }
    }
}

struct DashboardReliabilityStrip: View {
    let unobservedFraction: String
    let outageCount: String
    let totalDowntime: String
    let longestOutage: String

    var body: some View {
        HStack(spacing: 0) {
            // Intro
            VStack(alignment: .leading, spacing: 3) {
                Text("Connection reliability")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Text(unobservedFraction)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 34)

            // Metric 1: Outages
            metric(title: outageCount, subtitle: "Recorded interruptions")
                .frame(maxWidth: .infinity)

            Divider().frame(height: 34)

            // Metric 2: Downtime
            metric(title: totalDowntime, subtitle: "Total downtime")
                .frame(maxWidth: .infinity)

            Divider().frame(height: 34)

            // Metric 3: Longest
            metric(title: longestOutage, subtitle: "Longest outage")
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func metric(title: String, subtitle: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.ink)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
        }
    }
}

// MARK: - 8. Network Details Panel

struct DashboardNetworkDetailsPanel: View {
    let interface: String
    let publicCountry: String
    let localIP: String
    let publicIP: String
    let gatewayIP: String
    let ispName: String
    let dnsServer: String
    let vpnName: String
    let wifiSecurity: String
    let connectionCost: String
    let lastSpeedMeta: String
    let downMbps: String
    let upMbps: String
    let onRunSpeedTest: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                Text("Network details")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Text("Current connection")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 2-Column Key-Values Grid
            VStack(spacing: 0) {
                row(k1: "Interface", v1: interface, k2: "Public IP country", v2: publicCountry)
                row(k1: "Local IP", v1: localIP, k2: "Public IP", v2: publicIP)
                row(k1: "Gateway", v1: gatewayIP, k2: "ISP / exit network", v2: ispName)
                row(k1: "DNS server", v1: dnsServer, k2: "VPN", v2: vpnName)
                row(k1: "Wi-Fi security", v1: wifiSecurity, k2: "Connection cost", v2: connectionCost)
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 6)

            // Footer Speed Test Summary
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last speed test · \(lastSpeedMeta)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                    Text("Before VPN · previous connection")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ColorToken.quiet)
                }

                Spacer()

                HStack(spacing: 12) {
                    Text("↓ \(downMbps)   ↑ \(upMbps) Mbps")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)

                    Button(action: onRunSpeedTest) {
                        Text("Run speed test")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(Theme.ColorToken.footerBackground)
            .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line) }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func row(k1: String, v1: String, k2: String, v2: String) -> some View {
        HStack(spacing: 18) {
            cell(k: k1, v: v1)
            cell(k: k2, v: v2)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().foregroundStyle(Theme.ColorToken.line.opacity(0.6)) }
    }

    private func cell(k: String, v: String) -> some View {
        HStack {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
            Spacer()
            Text(v)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ColorToken.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 9. Recent Activity Panel

struct DashboardRecentActivityPanel: View {
    let events: [ActivityEntry]
    let onOpenActivity: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                Text("Recent activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Button("View all") {
                    onOpenActivity()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if events.isEmpty {
                VStack(spacing: 4) {
                    Text("No incidents recorded")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.prefix(4).enumerated()), id: \.element.id) { idx, entry in
                        if idx > 0 {
                            Divider().foregroundStyle(Theme.ColorToken.line.opacity(0.6))
                        }

                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(EventStyle.tint(for: entry.kind))
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.summary)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                    .lineLimit(1)

                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.ColorToken.muted)
                                }
                            }

                            Spacer()

                            RelativeTimeText(date: entry.latest)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }
}

// MARK: - 10. Suitability Strip

struct DashboardSuitabilityStrip: View {
    let items: [SuitabilityEngine.Item]
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("What should work")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)

                if let subtitle, !subtitle.isEmpty {
                    Text("· \(subtitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()

                Text("Live assessment")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.quiet)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        chip(item)
                            .frame(maxWidth: .infinity)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            chip(item)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func chip(_ item: SuitabilityEngine.Item) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                    .lineLimit(1)

                HStack(spacing: 3) {
                    Text(item.status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.tint)
                        .lineLimit(1)

                    Text("·")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ColorToken.line)

                    Text(item.metric)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.ColorToken.nodeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(item.tint.opacity(0.25), lineWidth: 1)
        )
        .help(item.helpText ?? "\(item.title): \(item.status)")
    }
}

// MARK: - 11. Technical Details Panel

struct DashboardTechnicalPanel: View {
    let routerIP: String
    let routerLoss: String
    let internetTargets: String
    let internetLoss: String
    let tracerouteHops: Int
    let isIPv6: Bool
    let isDoubleNAT: Bool
    let wifiSignal: String
    let wifiNoise: String
    let wifiSNR: String
    let wifiBandChannel: String
    let dhcpRemaining: String
    let ipConflict: Bool
    let neighborCount: Int
    let backgroundTraffic: Bool
    let checkTimestamp: String
    let dnsResolversList: String
    let tcpReachability: String
    let loadedRTT: String
    let onViewRawJSON: () -> Void
    let onCopyRedacted: () -> Void
    let onSaveMarkdown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel Header (Permanently unfolded)
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.blue)
                Text("Technical Detail & Telemetry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Text("Route hops, radio telemetry, DNS, DHCP, and diagnostic reports")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                Spacer()
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)

            Divider().foregroundStyle(Theme.ColorToken.line)

            // 2x2 Grid of Technical Details (Always visible)
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 16) {
                GridRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Route & reachability · saved check")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                        bullet("Router: \(routerIP) · \(routerLoss)")
                        bullet("Internet probes: \(internetTargets) · \(internetLoss)")
                        bullet("Traceroute: \(tracerouteHops) responding hops")
                        bullet(isIPv6 ? "IPv6 available" : "IPv6 unavailable; connection uses IPv4")
                        bullet(isDoubleNAT ? "Double NAT detected" : "NAT topology: no double NAT detected")
                        bullet("Public IP location describes lookup exit, not every app route")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Wi-Fi & local network · saved check")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                        bullet("Signal \(wifiSignal) · noise \(wifiNoise) · SNR \(wifiSNR)")
                        bullet(wifiBandChannel)
                        bullet("DHCP lease: \(dhcpRemaining)")
                        bullet(ipConflict ? "IP conflict flagged" : "No duplicate IP detected")
                        bullet("Channel scan: \(neighborCount) neighboring networks")
                        bullet(backgroundTraffic ? "High background traffic measured" : "Local traffic: no background transfer flagged")
                    }
                }

                GridRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Test context")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                        bullet("Check run at \(checkTimestamp)")
                        bullet("DNS: \(dnsResolversList)")
                        bullet("TCP 1.1.1.1:443 · \(tcpReachability)")
                        bullet("Loaded RTT: \(loadedRTT)")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Reports & diagnostic tools")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                        Text("Inspect full raw report for per-hop tables and individual probes.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                        Text("Copy a redacted report when sharing with support.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
            }
            .padding(17)

            // Actions
            HStack(spacing: 10) {
                Button("View raw JSON", action: onViewRawJSON)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Copy redacted report", action: onCopyRedacted)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Save Markdown…", action: onSaveMarkdown)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 15)
        }
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.routeCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.routeCard)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
                .lineSpacing(2)
        }
    }
}

// MARK: - 12. Dashboard Footer

struct DashboardFooterView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.muted)
            Text("Country is based on the public IP. VPN detection does not verify every app’s route.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ColorToken.muted)
            Spacer()
            Text("Hopwatch v\(AppVersion.display)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.ColorToken.muted)
        }
        .padding(.vertical, 8)
    }
}
