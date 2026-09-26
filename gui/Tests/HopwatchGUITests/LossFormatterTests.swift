import Foundation
import Testing
@testable import HopwatchGUI

@Suite struct LossFormatterTests {

    @Test func zeroLossFormatsWithoutDecimal() {
        #expect(LossFormatter.formatPct(0.0) == "0%")
        #expect(LossFormatter.formatPct(nil) == "0%")
        #expect(LossFormatter.formatPct(-1.0) == "0%")
        #expect(LossFormatter.formatPacketLoss(0.0) == "0% packet loss")
        #expect(LossFormatter.formatLoss(0.0) == "0% loss")
    }

    @Test func subOnePercentLossDisplaysDecimal() {
        #expect(LossFormatter.formatPct(0.3) == "0.3%")
        #expect(LossFormatter.formatPct(0.5) == "0.5%")
        #expect(LossFormatter.formatPct(0.8) == "0.8%")
        #expect(LossFormatter.formatPacketLoss(0.3) == "0.3% packet loss")
        #expect(LossFormatter.formatLoss(0.3) == "0.3% loss")
    }

    @Test func tinyLossDoesNotRoundToZero() {
        #expect(LossFormatter.formatPct(0.03) == "<0.1%")
        #expect(LossFormatter.formatPacketLoss(0.03) == "<0.1% packet loss")
        #expect(LossFormatter.formatLoss(0.03) == "<0.1% loss")
    }

    @Test func onePercentOrGreaterFormatsAsInteger() {
        #expect(LossFormatter.formatPct(1.0) == "1%")
        #expect(LossFormatter.formatPct(1.4) == "1%")
        #expect(LossFormatter.formatPct(2.0) == "2%")
        #expect(LossFormatter.formatPct(5.0) == "5%")
        #expect(LossFormatter.formatPct(12.0) == "12%")
        #expect(LossFormatter.formatPacketLoss(2.0) == "2% packet loss")
        #expect(LossFormatter.formatLoss(2.0) == "2% loss")
    }
}
