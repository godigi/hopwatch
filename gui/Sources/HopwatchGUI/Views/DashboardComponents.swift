import SwiftUI
import AppKit
import Charts

// MARK: - 1. Page Heading

struct DashboardHeadingView: View {
    let networkName: String?
    let isWiFi: Bool
    let isScanning: Bool
    var isLinkDown: Bool = false
    let onRunFullCheck: () -> Void
    let onCancelScan: () -> Void
    let onCopyRedacted: () -> Void
    let onCopySupport: () -> Void
    let onSaveMarkdown: () -> Void
    let onSaveJSON: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network Overview")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.ink)

                HStack(spacing: 6) {
                    Text("Current connection:")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                    HStack(spacing: 4) {
                        Image(systemName: isWiFi ? "wifi" : "cable.connector")
                            .font(.system(size: 10))
                        Text(isLinkDown ? "Disconnected" : (networkName ?? "Identifying network…"))
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.ink)

                    Text("·")
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
    var statusPillText: String? = nil
    var statusPillTint: Color? = nil
    var statusPillBackground: Color? = nil
    var detectedTime: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconTint)
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(iconTint == Theme.ColorToken.green ? Color(red: 0.08, green: 0.5, blue: 0.24) : Theme.ColorToken.ink)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(iconTint == Theme.ColorToken.green ? Color(red: 0.09, green: 0.4, blue: 0.2) : Theme.ColorToken.muted)
                    .lineLimit(2)
            }

            Spacer()

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if let pill = statusPillText {
                Text(pill)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(statusPillTint ?? iconTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(statusPillBackground ?? iconBackground)
                    .clipShape(Capsule())
            } else if let detectedTime, !detectedTime.isEmpty {
                Text(detectedTime)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.quiet)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(iconBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(iconTint.opacity(0.3), lineWidth: 1)
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
    var vpnKnown: Bool = true
    let vpnProvider: String?
    let publicIP: String?
    let pingTarget: String?
    var pingTargetAlt: String? = nil
    var culpritHop: String? = nil
    var routerAdminURL: URL? = nil
    var routerAdminAvailable: Bool = false
    var internetDetailText: String? = nil
    var routerDetailText: String? = nil
    var isCritical: Bool = false
    var isWiFi: Bool = true
    var macStatusGood: Bool = true
    var isWifiLaggy: Bool = false
    /// The newest sample says there is no link. The router and internet
    /// hops render as unknown (grey, no badge, no flag, no invented gateway
    /// address or ISP) and the Mac hop as down; the caller supplies "—"
    /// for the readings. Neither "fine" nor "faulty" has been established
    /// for a hop nothing can reach.
    var linkDown: Bool = false

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
                    .foregroundStyle(linkDown || routerPingText == "—" ? Theme.ColorToken.line : ((routerWarn || isWifiLaggy) ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.green.opacity(0.6)))

                    // Dashed line hop2 -> hop3
                    Path { path in
                        path.move(to: CGPoint(x: x2 + 28, y: lineY))
                        path.addLine(to: CGPoint(x: x3 - 28, y: lineY))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(linkDown || internetPingText == "—" ? Theme.ColorToken.line : (internetWarn ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.green.opacity(0.6)))

                    // Intermediate labels
                    let firstLink = linkDown ? NoLinkCopy.nodeDetail : (isWiFi ? (isWifiLaggy ? "Wi-Fi (laggy) · local connection" : "Wi-Fi · local connection") : "Wired · local connection")
                    Text(firstLink)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isWifiLaggy ? Theme.ColorToken.amber : Theme.ColorToken.muted)
                        .position(x: (x1 + x2) / 2.0, y: lineY + 14)

                    Text(linkDown ? "" : "Broadband · internet connection")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .position(x: (x2 + x3) / 2.0, y: lineY + 14)
                }

                HStack(alignment: .top, spacing: 0) {
                    // Hop 1: This Mac
                    VStack(spacing: 3) {
                        VStack(spacing: 2) {
                            Text(linkDown ? "Network link" : (isWiFi ? "Wi-Fi signal" : "Interface link"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(wifiSignalText)
                                    .font(.system(size: (wifiSignalText.contains("laggy") ? 16 : 20), weight: .semibold))
                                    .foregroundStyle(wifiSignalTint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(wifiSignalDetail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                            }
                        }
                        .frame(height: 54)

                        let isMacCulprit = culpritHop == "wifi" || culpritHop == "mac"
                        hopNode(
                            icon: (isWiFi || linkDown) ? "laptopcomputer" : "cable.connector",
                            isWarning: !macStatusGood || isWifiLaggy,
                            flag: nil,
                            isCulprit: isMacCulprit && !linkDown,
                            isCritical: isCritical,
                            state: linkDown ? .down : (!macStatusGood && !isWifiLaggy && !isMacCulprit ? .unknown : .normal)
                        )

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
                                    .font(.system(size: routerPingText == "no reply" ? 14 : 20, weight: .semibold))
                                    .foregroundStyle(routerPingTint)
                                if routerPingText != "—" && routerPingText != "no reply" {
                                    Text("ms")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.ColorToken.muted)
                                }
                            }
                        }
                        .frame(height: 54)

                        hopNode(icon: "network", isWarning: routerWarn && !linkDown, flag: nil,
                                isCulprit: culpritHop == "router" && !linkDown, isCritical: isCritical,
                                state: linkDown || (routerPingText == "—" && !routerWarn) ? .unknown : .normal)

                        Text("Router")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 7)

                        if linkDown {
                            Text(NoLinkCopy.nodeDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                                .lineLimit(1)
                        } else if routerWarn, let detail = routerDetailText, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isCritical ? Theme.ColorToken.red : Theme.ColorToken.amber)
                                .lineLimit(1)
                            Text("\(routerIP) · gateway")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.muted)
                                .lineLimit(1)
                        } else if routerAdminAvailable, let routerAdminURL {
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

                        if !linkDown, let delta = routerLoadedDelta {
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
                                    .font(.system(size: (internetPingText == "no reply" || internetPingText == "TCP ok") ? 14 : 20, weight: .semibold))
                                    .foregroundStyle(internetPingTint)
                                if internetPingText != "—" && internetPingText != "no reply" && internetPingText != "TCP ok" {
                                    Text("ms")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.ColorToken.muted)
                                }
                            }
                        }
                        .frame(height: 54)

                        hopNode(icon: "globe", isWarning: internetWarn && !linkDown, flag: linkDown ? nil : countryFlag,
                                isCulprit: culpritHop == "internet" && !linkDown, isCritical: isCritical,
                                state: linkDown || (internetPingText == "—" && !internetWarn) ? .unknown : .normal)

                        Text("Internet")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.top, 7)

                        if linkDown {
                            Text(NoLinkCopy.nodeDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.ColorToken.muted)
                                .lineLimit(1)
                        } else if internetWarn, let detail = internetDetailText, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isCritical ? Theme.ColorToken.red : Theme.ColorToken.amber)
                                .lineLimit(1)
                            if let isp = ispName, !isp.isEmpty {
                                Text(isp)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.muted)
                                    .lineLimit(1)
                            } else if let countryName, !countryName.isEmpty {
                                Text(countryName)
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.muted)
                                    .lineLimit(1)
                            }
                        } else if let isp = ispName, !isp.isEmpty {
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

                        if !linkDown, let delta = internetLoadedDelta {
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
                    Text(vpnKnown ? (vpnActive ? "VPN on" : "VPN off") : "VPN checking…")
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
                    if !linkDown, let publicIP, !publicIP.isEmpty {
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

    /// `.unknown` and `.down` exist for the no-link state only.
    private enum HopState { case normal, unknown, down }

    private func hopNode(icon: String, isWarning: Bool, flag: String?, isCulprit: Bool, isCritical: Bool = false,
                         state: HopState = .normal) -> some View {
        let culpritTint = isCritical ? Theme.ColorToken.red : Theme.ColorToken.amber
        let culpritWash = isCritical ? Theme.ColorToken.redWash : Theme.ColorToken.amberWash

        return ZStack {
            Circle()
                .fill(state == .down ? Theme.ColorToken.redWash : (isCulprit ? culpritWash : (isWarning ? Theme.ColorToken.amberWash : Theme.ColorToken.nodeBackground)))
                .frame(width: 44, height: 44)
                .overlay(
                    Circle()
                        .strokeBorder(state == .down ? Theme.ColorToken.red.opacity(0.6) : (isCulprit ? culpritTint : (isWarning ? Theme.ColorToken.amber.opacity(0.6) : Theme.ColorToken.line)), lineWidth: isCulprit ? 2 : 1)
                )
                .shadow(color: isCulprit ? culpritTint.opacity(0.15) : Color.black.opacity(0.04), radius: isCulprit ? 5 : 3, y: 1)

            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(state == .unknown ? Theme.ColorToken.muted
                                 : state == .down ? Theme.ColorToken.red
                                 : (isCulprit ? culpritTint : (isWarning ? Theme.ColorToken.amber : Theme.ColorToken.green)))

            // Status Check or Warning Badge. None for a hop that has not
            // been reached: a check says "verified", a "!" says "faulty".
            if state != .unknown {
                Circle()
                    .fill(state == .down ? Theme.ColorToken.red : (isCulprit ? culpritTint : (isWarning ? Theme.ColorToken.amber : Theme.ColorToken.green)))
                    .frame(width: 15, height: 15)
                    .overlay(
                        Image(systemName: state == .down ? "xmark" : ((isWarning || isCulprit) ? "exclamationmark" : "checkmark"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: 16, y: 16)
            }

            // Optional Culprit Banner
            if isCulprit {
                Text("Issue source")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(culpritTint)
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
    var burstUntil: Date? = nil
    let onToggleBurst: () -> Void

    private var filteredSamples: [MonitorSample] {
        let cutoff = Date().addingTimeInterval(-Double(selectedWindowMinutes) * 60)
        return samples.filter { $0.timestamp >= cutoff }
    }

    private func buildInternetSeries(from filtered: [MonitorSample]) -> MonitorSeries.Result {
        MonitorSeries.build(filtered, tier: "fast") { sample in
            PingReadout.internetSeriesValue(for: sample)
        }
    }

    private func buildRouterSeries(from filtered: [MonitorSample]) -> MonitorSeries.Result {
        MonitorSeries.build(filtered, tier: "fast") { sample in
            sample.gateway.rttAvgMs
        }
    }

    private func computeInternetStats(from series: MonitorSeries.Result) -> (min: Double, avg: Double, max: Double)? {
        let segments = series.segments
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
        let filtered = filteredSamples
        let internetSeries = buildInternetSeries(from: filtered)
        let routerSeries = buildRouterSeries(from: filtered)
        let internetStats = computeInternetStats(from: internetSeries)
        let internetSegments = internetSeries.identifiedSegments
        let routerSegments = routerSeries.identifiedSegments

        VStack(spacing: 0) {
            // Panel Head
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ping over time")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.ink)
                    if isBursting {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Theme.ColorToken.blue)
                                .frame(width: 6, height: 6)
                            if let until = burstUntil {
                                Text("Testing latency · 2s interval until \(until.formatted(date: .omitted, time: .standard))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.blue)
                            } else {
                                Text("Testing latency · sampling every \(Defaults.latencyTestInterval)s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.blue)
                            }
                        }
                    } else {
                        Text("Live samples · last hour retained")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
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
            if filtered.isEmpty {
                VStack {
                    Text("No samples in this window")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 145)
            } else {
                Chart {
                    ForEach(internetSegments) { segment in
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

                    ForEach(routerSegments) { segment in
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
                if isBursting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Sampling fast cadence (every \(Defaults.latencyTestInterval)s)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.ColorToken.blue)
                    }
                } else {
                    Text("Response time in ms · lower is better")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()

                Button(action: onToggleBurst) {
                    HStack(spacing: 5) {
                        if isBursting {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text("Stop latency test")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                            Text("Start latency test")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(isBursting ? Theme.ColorToken.blue : Theme.ColorToken.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(isBursting ? Theme.ColorToken.blueWash : Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isBursting ? Theme.ColorToken.blue.opacity(0.35) : Theme.ColorToken.line, lineWidth: 1)
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
    enum EmptyState: Equatable {
        case awaiting
        case liveClear
        case savedClear
    }

    struct FindingItem: Identifiable {
        let id: String
        let title: String
        let explanation: String
        let nextStep: String?
        let isWarning: Bool
        /// The rule this finding came from, which a repair is judged
        /// against ("does the re-check still show it?").
        var ruleID: String? = nil
        /// The CLI's offers for this finding, already filtered to the
        /// ones that are current (`HopwatchCoordinator.repairsAreCurrent`).
        var repairs: [RunSnapshot.Diagnosis.Repair] = []
    }

    let checkTime: String?
    let findings: [FindingItem]
    let emptyState: EmptyState
    /// The repair the user last pressed and how it turned out. Shown above
    /// the findings rather than on one, because a repair that worked has
    /// removed the finding it was attached to.
    var outcome: RepairOutcome?
    var repairsBusy: Bool
    var onRepair: (FindingItem, RunSnapshot.Diagnosis.Repair) -> Void
    var onDismissOutcome: () -> Void
    /// "ruleID|repairID" of the repair whose confirmation is open.
    @State private var confirming: String?

    init(checkTime: String?,
         findings: [FindingItem],
         emptyState: EmptyState = .liveClear,
         outcome: RepairOutcome? = nil,
         repairsBusy: Bool = false,
         initiallyConfirming: String? = nil,
         onRepair: @escaping (FindingItem, RunSnapshot.Diagnosis.Repair) -> Void = { _, _ in },
         onDismissOutcome: @escaping () -> Void = {}) {
        self.checkTime = checkTime
        self.findings = findings
        self.emptyState = emptyState
        self.outcome = outcome
        self.repairsBusy = repairsBusy
        self.onRepair = onRepair
        self.onDismissOutcome = onDismissOutcome
        _confirming = State(initialValue: initiallyConfirming)
    }

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

            if let outcome {
                RepairOutcomeRow(outcome: outcome, onDismiss: onDismissOutcome)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            if findings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: emptyState == .liveClear ? "checkmark.circle.fill" : "clock")
                            .font(.system(size: 14))
                            .foregroundStyle(emptyState == .liveClear ? Theme.ColorToken.green : Theme.ColorToken.muted)
                        Text(emptyState == .liveClear ? "No active issues detected" :
                             emptyState == .savedClear ? "No findings in the last check" : "Awaiting network check")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }
                    Text(emptyState == .liveClear
                         ? "Current readings are within healthy thresholds."
                         : emptyState == .savedClear
                           ? "The saved check found no issues; current conditions may differ."
                           : "Findings will appear after this network is measured.")
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
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: item.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.isWarning ? Theme.ColorToken.amber : Theme.ColorToken.blue)
                                    .padding(.top, 1)
                                Text(item.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !item.explanation.isEmpty {
                                Text(item.explanation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.muted)
                                    .lineSpacing(2)
                                    .padding(.leading, 20)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let nextStep = item.nextStep, !nextStep.isEmpty {
                                Text(nextStep)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                    .padding(.leading, 20)
                                    .padding(.top, 2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !item.repairs.isEmpty {
                                RepairControls(
                                    item: item,
                                    confirming: $confirming,
                                    busy: repairsBusy,
                                    onRun: { onRepair(item, $0) })
                                    .padding(.leading, 20)
                                    .padding(.top, 4)
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

// MARK: - Repair controls

/// The "Fix it" buttons under one finding, and the confirmation that
/// stands between pressing one and running it.
///
/// Inline rather than a system alert: a confirmation dialog raised from a
/// menu-bar panel is unreliable, and an inline one can be seen by the
/// gallery harness. Every sentence here is the CLI's — `label` on the
/// button, `confirm` as the question — except the one line saying a
/// password will be asked for, which only a repair with `admin` true shows
/// (none in this first phase).
private struct RepairControls: View {
    let item: DashboardFindingsPanel.FindingItem
    @Binding var confirming: String?
    let busy: Bool
    let onRun: (RunSnapshot.Diagnosis.Repair) -> Void

    private func key(_ repair: RunSnapshot.Diagnosis.Repair) -> String {
        "\(item.ruleID ?? "?")|\(repair.id)"
    }

    var body: some View {
        if let open = item.repairs.first(where: { key($0) == confirming }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(open.confirm)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if open.admin {
                    Label("This will ask for your Mac's administrator password.",
                          systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.amber)
                }
                HStack(spacing: 8) {
                    Button(open.label) {
                        confirming = nil
                        onRun(open)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy)
                    Button("Cancel") { confirming = nil }
                        .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ColorToken.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1))
        } else {
            HStack(spacing: 8) {
                ForEach(item.repairs) { repair in
                    Button(repair.label) { confirming = key(repair) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(busy)
                }
            }
        }
    }
}

/// How the repair the user last pressed turned out. The status word is the
/// app's; the sentence under it is the CLI's.
struct RepairOutcomeRow: View {
    let outcome: RepairOutcome
    let onDismiss: () -> Void

    private var tint: Color {
        switch outcome.phase {
        case .fixed:                       return Theme.ColorToken.green
        case .working, .checking, .done:   return Theme.ColorToken.blue
        case .didntHelp, .failed:          return Theme.ColorToken.amber
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if outcome.isInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: outcome.phase == .fixed
                          ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(outcome.label): \(outcome.statusText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                if let detail = outcome.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !outcome.isInFlight {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ColorToken.muted)
                .help("Dismiss")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
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
    var hasSavedResult: Bool = true
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

                Text(hasSavedResult ? "Saved result" : "Awaiting check")
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
                Text(hasSavedResult
                     ? "Packet loss covers two destinations. “Usual” is this network’s median from saved checks; VPN and route changes can affect the comparison."
                     : "A check will add measurements and compare them with this network’s saved history.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineSpacing(2)

                if hasSavedResult {
                    Text("Saved on \(networkSSID ?? "this network"). Current readings appear above when available.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                } else {
                    Text("No saved check for this network yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
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

/// Custom visual progress bar for in-flight speed tests, providing continuous animation
/// and live throughput / percentage metrics.
struct SpeedTestProgressBarView: View {
    let speed: ScanProgress.Speed?

    private var direction: ScanProgress.Speed.Direction {
        speed?.direction ?? .prep
    }

    private var stageTitle: String {
        guard let speed = speed else {
            return "Connecting to speed test server…"
        }
        switch speed.direction {
        case .download: return "Testing download bandwidth…"
        case .upload:   return "Testing upload bandwidth…"
        case .ping:     return "Testing latency & jitter…"
        case .prep:     return "Connecting to server…"
        case .other:    return speed.stage.isEmpty ? "Testing speed…" : PhaseLabel.humanised(speed.stage)
        }
    }

    private var stageIcon: (name: String, color: Color) {
        switch direction {
        case .download:
            return ("arrow.down.circle.fill", Theme.ColorToken.green)
        case .upload:
            return ("arrow.up.circle.fill", Theme.ColorToken.blue)
        case .ping:
            return ("waveform.path", Theme.ColorToken.amber)
        case .prep, .other:
            return ("gauge.with.dots.needle.bottom.50percent", Theme.ColorToken.blue)
        }
    }

    private var progressGradient: LinearGradient {
        switch direction {
        case .download:
            return LinearGradient(
                colors: [Color.green.opacity(0.85), Color.teal],
                startPoint: .leading, endPoint: .trailing
            )
        case .upload:
            return LinearGradient(
                colors: [Color.blue.opacity(0.85), Color.cyan],
                startPoint: .leading, endPoint: .trailing
            )
        case .ping:
            return LinearGradient(
                colors: [Color.orange.opacity(0.85), Theme.ColorToken.amber],
                startPoint: .leading, endPoint: .trailing
            )
        case .prep, .other:
            return LinearGradient(
                colors: [Theme.ColorToken.blue.opacity(0.6), Theme.ColorToken.blue],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Stage Status and Live Throughput Pill
            HStack(spacing: 6) {
                Image(systemName: stageIcon.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stageIcon.color)

                Text(stageTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.ink)

                Spacer()

                if let mbps = speed?.mbps, (direction == .download || direction == .upload) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(direction == .download ? Theme.ColorToken.green : Theme.ColorToken.blue)
                            .frame(width: 5, height: 5)
                        Text(String(format: "%.1f Mbps", mbps))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.ink)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.ColorToken.neutralWash)
                    .clipShape(Capsule())
                } else if let progress = speed?.progress, progress > 0 {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
            }

            // Custom Visual Progress Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.ColorToken.neutralWash)
                        .frame(height: 6)

                    if let progress = speed?.progress, progress > 0 {
                        let clamped = min(max(progress, 0.0), 1.0)
                        let barWidth = max(6, geo.size.width * CGFloat(clamped))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressGradient)
                            .frame(width: barWidth, height: 6)
                            .animation(.easeOut(duration: 0.2), value: progress)
                    } else {
                        IndeterminateSpeedShimmer(gradient: progressGradient, totalWidth: geo.size.width)
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }
}

/// Shimmer animation bar used when the speed test backend doesn't emit continuous fractions
/// or while waiting for throughput stages to spin up.
struct IndeterminateSpeedShimmer: View {
    let gradient: LinearGradient
    let totalWidth: CGFloat
    @State private var offsetFraction: CGFloat = 0.0

    var body: some View {
        let pillWidth = max(40, totalWidth * 0.3)
        let travelDistance = max(0, totalWidth - pillWidth)
        RoundedRectangle(cornerRadius: 3)
            .fill(gradient)
            .frame(width: pillWidth, height: 6)
            .offset(x: offsetFraction * travelDistance)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    offsetFraction = 1.0
                }
            }
    }
}

struct DashboardSpeedCard: View {
    let downMbps: String
    let upMbps: String
    let testedMeta: String?
    let isScanning: Bool
    var isSpeedTesting: Bool = false
    var speedProgress: ScanProgress.Speed? = nil
    let onRunSpeedTest: () -> Void
    var onCancelSpeedTest: (() -> Void)? = nil

    private var displayedDownMbps: String {
        if isSpeedTesting, let speed = speedProgress {
            if speed.direction == .download, let mbps = speed.mbps {
                return String(format: "%.1f", mbps)
            } else if let dl = speed.downloadMbps {
                return String(format: "%.1f", dl)
            }
        }
        return downMbps
    }

    private var displayedUpMbps: String {
        if isSpeedTesting, let speed = speedProgress {
            if speed.direction == .upload, let mbps = speed.mbps {
                return String(format: "%.1f", mbps)
            } else if let ul = speed.uploadMbps {
                return String(format: "%.1f", ul)
            }
        }
        return upMbps
    }

    private var isDownloadActive: Bool {
        isSpeedTesting && speedProgress?.direction == .download
    }

    private var isUploadActive: Bool {
        isSpeedTesting && speedProgress?.direction == .upload
    }

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

                if isSpeedTesting {
                    Button(action: { onCancelSpeedTest?() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("Cancel")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.ColorToken.neutralWash)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                } else {
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
                            Text(displayedDownMbps)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(displayedDownMbps == "—" ? Theme.ColorToken.muted : (isDownloadActive ? Theme.ColorToken.green : Theme.ColorToken.ink))
                            Text("Mbps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ColorToken.muted)
                            if isDownloadActive {
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Theme.ColorToken.green)
                                    .clipShape(Capsule())
                            }
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
                            Text(displayedUpMbps)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(displayedUpMbps == "—" ? Theme.ColorToken.muted : (isUploadActive ? Theme.ColorToken.blue : Theme.ColorToken.ink))
                            Text("Mbps")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ColorToken.muted)
                            if isUploadActive {
                                Text("LIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Theme.ColorToken.blue)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("Upload")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Visual Speedtest Progress Bar
            if isSpeedTesting {
                SpeedTestProgressBarView(speed: speedProgress)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            // Subtitle
            if isSpeedTesting {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(activeTestingSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.muted)
                }
                .lineLimit(1)
            } else {
                Text(testedMeta ?? "Run a speed test to check download and upload bandwidth.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.ColorToken.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.ColorToken.line, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: isSpeedTesting)
    }

    private var activeTestingSubtitle: String {
        guard let speed = speedProgress else { return "Testing connection throughput in real time…" }
        switch speed.direction {
        case .download: return "Testing download bandwidth against server…"
        case .upload:   return "Testing upload bandwidth against server…"
        case .ping:     return "Testing round-trip latency and jitter…"
        case .prep:     return "Connecting to speed test server…"
        case .other:    return speed.stage.isEmpty ? "Testing connection throughput in real time…" : PhaseLabel.humanised(speed.stage)
        }
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
    var routerAdminURL: URL? = nil
    var routerAdminAvailable: Bool = false
    let onOpenNetworkSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                Text("Network Details")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Text("Current connection configuration")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 2-Column Key-Values Grid
            VStack(spacing: 0) {
                row(k1: "Interface", v1: interface, k2: "Public Country", v2: publicCountry)
                row(k1: "Local IP", v1: localIP, k2: "Public IP", v2: publicIP)
                row(k1: "Gateway IP", v1: gatewayIP, k2: "ISP Name", v2: ispName)
                row(k1: "DNS Server", v1: dnsServer, k2: "VPN Status", v2: vpnName)
                row(k1: "Wi-Fi Security", v1: wifiSecurity, k2: "Connection Cost", v2: connectionCost)
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 6)

            // Footer Action Links
            HStack(spacing: 16) {
                Button("Configure Interface…") {
                    onOpenNetworkSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)

                if routerAdminAvailable, let routerAdminURL {
                    Button("Open Router Admin →") {
                        NSWorkspace.shared.open(routerAdminURL)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.blue)
                }

                Spacer()
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
                                Text(entry.displaySummary)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.ink)
                                    .lineLimit(1)

                                AppTrafficEvidenceView(entry: entry, limit: 2)

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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.ink)

                Text("· Live real-world activity assessment")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.muted)

                Spacer()

                Text("Updated continuously")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.quiet)
            }

            HStack(spacing: 8) {
                ForEach(items) { item in
                    chip(item)
                        .frame(maxWidth: .infinity)
                }
            }
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

    private func chip(_ item: SuitabilityEngine.Item) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(item.tint.opacity(0.14))
                        .frame(width: 18, height: 18)
                    Image(systemName: item.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.tint)
                }

                Text(item.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.ink)
                    .lineLimit(1)
            }

            Text(item.status)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(item.tint)
                .lineLimit(1)

            if !item.metric.isEmpty {
                Text(item.metric)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.muted)
                    .lineLimit(1)
            }

            Text(item.consequence)
                .font(.system(size: 8.5))
                .foregroundStyle(item.verdict == .good ? Theme.ColorToken.muted : item.tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.verdict == .good ? Theme.ColorToken.nodeBackground : item.tint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(item.tint.opacity(item.verdict == .good ? 0.25 : 0.45), lineWidth: item.verdict == .good ? 1 : 1.5)
        )
        .help(item.helpText ?? "\(item.title): \(item.status) — \(item.consequence)")
    }
}

// MARK: - 11. Technical Details Panel

struct DashboardTechnicalPanel: View {
    let tracerouteHops: Int?
    let isIPv6: Bool?
    let isDoubleNAT: Bool?
    let wifiBandChannel: String
    let wifiSignal: String
    let wifiNoise: String
    let wifiSNR: String?
    let dhcpRemaining: String
    let ipConflict: Bool?
    let neighborCount: Int?
    let loadedRTT: String
    let appVersion: String
    let onViewRawJSON: () -> Void
    let onCopyRedacted: () -> Void
    let onSaveMarkdown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Panel Head
            HStack {
                Text("Technical Detail & Telemetry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.ink)
                Spacer()
                Text("System diagnostics & link metrics")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.muted)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 2-Column Key-Values Grid
            VStack(spacing: 0) {
                row(k1: "Traceroute Hops", v1: tracerouteHops.map { "\($0) hops to target" } ?? "Not measured",
                    k2: "IPv6 Reachability", v2: isIPv6.map { $0 ? "Dual-stack IPv6" : "IPv4 only (No global v6)" } ?? "Not measured")
                row(k1: "Double NAT Detection", v1: isDoubleNAT.map { $0 ? "Double NAT detected" : "None detected" } ?? "Not measured",
                    k2: "Wi-Fi Protocol & Channel", v2: wifiBandChannel.isEmpty ? "Not measured" : wifiBandChannel)
                row(k1: "Signal / Noise (RSSI)", v1: wifiSignal == "—" && wifiNoise == "—" ? "Not measured" : "\(wifiSignal) / \(wifiNoise)",
                    k2: "Signal-to-Noise Ratio", v2: wifiSNR ?? "Not measured")
                row(k1: "DHCP Lease Remaining", v1: dhcpRemaining,
                    k2: "IP Conflicts / Neighbors", v2: conflictAndNeighborText)
                row(k1: "Loaded Latency (Bufferbloat)", v1: loadedRTT,
                    k2: "Diagnostic Engine", v2: "netdiag v\(appVersion)")
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 6)

            // Footer Action Links
            HStack(spacing: 16) {
                Button("View Raw JSON") {
                    onViewRawJSON()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)

                Button("Copy Redacted Report") {
                    onCopyRedacted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)

                Button("Save Markdown…") {
                    onSaveMarkdown()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.blue)

                Spacer()
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

    private var conflictAndNeighborText: String {
        guard let ipConflict else { return "Not measured" }
        if ipConflict { return "IP conflict flagged" }
        return neighborCount.map { "0 duplicates · \($0) neighbors" } ?? "0 duplicates · neighbors not measured"
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
