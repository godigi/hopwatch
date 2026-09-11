import Foundation
import Testing
@testable import NetdiagGUI

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
}
