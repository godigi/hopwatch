import Foundation
import Testing
@testable import HopwatchGUI

struct FastISO8601Tests {

    @Test func standardUtcParsingMatchesFormatter() {
        let timestamp = "2026-09-17T01:57:39Z"
        let parsed = FastISO8601.parse(timestamp)
        let expected = ISO8601DateFormatter().date(from: timestamp)
        #expect(parsed != nil)
        #expect(parsed == expected)
    }

    @Test func fractionalSecondsParsing() {
        let timestamp = "2026-09-17T01:57:39.500Z"
        let parsed = FastISO8601.parse(timestamp)
        #expect(parsed != nil)
        #expect(parsed?.timeIntervalSince1970 == 1789610259.5)
    }

    @Test func spaceSeparatorParsing() {
        let timestamp = "2026-09-17 01:57:39"
        let parsed = FastISO8601.parse(timestamp)
        #expect(parsed != nil)
        let expected = FastISO8601.parse("2026-09-17T01:57:39Z")
        #expect(parsed == expected)
    }

    @Test func nilAndEmptyStringReturnNil() {
        #expect(FastISO8601.parse(nil) == nil)
        #expect(FastISO8601.parse("") == nil)
        #expect(FastISO8601.parse("invalid-date") == nil)
    }

    @Test func fallbackForNonStandardOffsets() {
        let timestamp = "2026-09-17T03:57:39+02:00"
        let parsed = FastISO8601.parse(timestamp)
        let expected = ISO8601DateFormatter().date(from: timestamp)
        #expect(parsed != nil)
        #expect(parsed == expected)
    }
}
