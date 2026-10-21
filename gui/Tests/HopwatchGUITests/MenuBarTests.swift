import Foundation
import Testing
import SwiftUI
import AppKit
@testable import HopwatchGUI

@Suite struct MenuBarTests {

    @Test func menuBarStyleDotAndPingCases() {
        #expect(MenuBarStyle.allCases.contains(.dotAndPing))
        #expect(MenuBarStyle.dotAndPing.rawValue == "dot+ping")
        #expect(MenuBarStyle.dotAndPing.label == "Dot and ping time")
        #expect(MenuBarStyle(rawValue: "dot+ping") == .dotAndPing)
    }

    @Test func formatsPingCorrectly() {
        #expect(MenuBarLabel.formatPing(internetRtt: 18.2, gatewayRtt: nil) == "18ms")
        #expect(MenuBarLabel.formatPing(internetRtt: nil, gatewayRtt: 4.8) == "5ms")
        #expect(MenuBarLabel.formatPing(internetRtt: 24.6, gatewayRtt: 5.2) == "25ms")
        #expect(MenuBarLabel.formatPing(internetRtt: 0.0, gatewayRtt: nil) == "0ms")
        #expect(MenuBarLabel.formatPing(internetRtt: nil, gatewayRtt: nil) == nil)
        #expect(MenuBarLabel.formatPing(internetRtt: -5.0, gatewayRtt: nil) == nil)
    }

    @Test @MainActor func showInDockDefaultsAndToggles() {
        let original = Defaults.showInDock
        defer { Defaults.showInDock = original }

        let settings = AppSettings()
        #expect(settings.showInDock == Defaults.showInDock)

        settings.showInDock = true
        #expect(Defaults.showInDock == true)

        settings.showInDock = false
        #expect(Defaults.showInDock == false)
    }

    @Test @MainActor func dropdownWindowSizeAndTopEdgeAnchoring() {
        let coordinator = HopwatchCoordinator()
        var sample = MonitorSample()
        sample.ts = HistoryDocument.iso.string(from: Date())
        sample.network.id = "net-test"
        sample.network.label = "Home Wi-Fi"
        sample.link.up = true
        sample.link.type = "wifi"
        sample.link.ssid = "Home Wi-Fi"
        sample.link.interface = "en0"
        sample.gateway.rttAvgMs = 4.2
        sample.gateway.lossPct = 0
        sample.internet.rttAvgMs = 18.5
        sample.internet.lossPct = 0
        sample.dns.ok = true
        sample.tcp.anyOk = true
        sample.publicInfo.ok = true
        sample.publicInfo.country = "Brazil"
        sample.publicInfo.countryISO = "BR"
        sample.publicInfo.ip = "177.136.244.18"
        sample.status.severity = "ok"
        sample.status.measurement = "ok"
        coordinator.handleSampleForTesting(sample)

        let rootView = DropdownView()
            .environment(coordinator)
            .environment(coordinator.appSettings)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.layoutSubtreeIfNeeded()

        let offscreenFitting = hostingController.view.fittingSize
        let proposedSize = hostingController.sizeThatFits(in: NSSize(width: 420, height: 880))

        #expect(offscreenFitting.width == 420)
        #expect(offscreenFitting.height > 500 && offscreenFitting.height < 880)
        #expect(abs(proposedSize.height - offscreenFitting.height) <= 1.0)

        let topMaxY: CGFloat = (NSScreen.main?.visibleFrame.maxY ?? 1073) - 2
        let panel = NSPanel(
            contentRect: NSRect(x: 900, y: topMaxY - offscreenFitting.height, width: 420, height: offscreenFitting.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        hostingController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let healthyHeight = hostingController.view.fittingSize.height

        #expect(abs(panel.frame.maxY - topMaxY) < 1.0)
        #expect(abs(panel.frame.height - healthyHeight) < 1.0)

        // Show update banner (dynamically increases DropdownView height)
        coordinator.updateChecker.hasUpdate = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hostingController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        let expandedHeight = hostingController.view.fittingSize.height
        #expect(expandedHeight > healthyHeight + 20)
        #expect(abs(panel.frame.height - expandedHeight) < 1.0)
        #expect(abs(panel.frame.maxY - topMaxY) < 1.0)

        // Hide update banner (shrinks height back down while keeping top edge pinned)
        coordinator.updateChecker.hasUpdate = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hostingController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        #expect(abs(panel.frame.height - healthyHeight) < 1.0)
        #expect(abs(panel.frame.maxY - topMaxY) < 1.0)
    }
}

