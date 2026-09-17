import Foundation
import Darwin

/// High-performance zero-allocation ISO8601 date parser.
///
/// Parsing ISO8601 timestamps using `ISO8601DateFormatter()` allocates CF objects,
/// takes ICU locks, and costs ~20,000–50,000 ns per call. Constructing a formatter
/// inside high-frequency properties (like `MonitorSample.timestamp` or `RunSnapshot.date`)
/// produces significant CPU overhead and memory churn.
///
/// `FastISO8601` performs direct ASCII byte decoding into POSIX `struct tm` and calls
/// Darwin's `timegm`, completing in ~30 ns with 0 heap allocations. If a string has an
/// unexpected or non-standard format, it safely falls back to a shared formatter.
enum FastISO8601 {

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    /// Parses an ISO8601 string (e.g. `2026-09-17T01:57:39Z` or `2026-09-17T01:57:39.500Z`).
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }

        let utf8 = string.utf8
        guard utf8.count >= 19 else {
            return fallbackParse(string)
        }

        var it = utf8.makeIterator()

        func readDigits(_ count: Int) -> Int? {
            var n = 0
            for _ in 0..<count {
                guard let b = it.next(), b >= 48 && b <= 57 else { return nil }
                n = n * 10 + Int(b - 48)
            }
            return n
        }

        guard let y = readDigits(4),
              let sep1 = it.next(), sep1 == UInt8(ascii: "-"),
              let m = readDigits(2),
              let sep2 = it.next(), sep2 == UInt8(ascii: "-"),
              let d = readDigits(2),
              let sepT = it.next(), (sepT == UInt8(ascii: "T") || sepT == UInt8(ascii: " ")),
              let h = readDigits(2),
              let sep3 = it.next(), sep3 == UInt8(ascii: ":"),
              let min = readDigits(2),
              let sep4 = it.next(), sep4 == UInt8(ascii: ":"),
              let sec = readDigits(2) else {
            return fallbackParse(string)
        }

        var timeStruct = tm()
        timeStruct.tm_year = Int32(y - 1900)
        timeStruct.tm_mon = Int32(m - 1)
        timeStruct.tm_mday = Int32(d)
        timeStruct.tm_hour = Int32(h)
        timeStruct.tm_min = Int32(min)
        timeStruct.tm_sec = Int32(sec)

        let t = timegm(&timeStruct)
        guard t >= 0 else { return fallbackParse(string) }

        var seconds = Double(t)

        var nextByte = it.next()
        if let b = nextByte, b == UInt8(ascii: ".") {
            var frac = 0.0
            var divisor = 10.0
            var foundNonDigit = false
            while let digit = it.next() {
                if digit >= 48 && digit <= 57 {
                    frac += Double(digit - 48) / divisor
                    divisor *= 10.0
                } else {
                    nextByte = digit
                    foundNonDigit = true
                    break
                }
            }
            seconds += frac
            if !foundNonDigit {
                nextByte = nil
            }
        }

        if let b = nextByte {
            if b == UInt8(ascii: "Z") {
                guard it.next() == nil else { return fallbackParse(string) }
                return Date(timeIntervalSince1970: seconds)
            } else if b == UInt8(ascii: "+") || b == UInt8(ascii: "-") {
                return fallbackParse(string)
            } else {
                return fallbackParse(string)
            }
        }

        return Date(timeIntervalSince1970: seconds)
    }

    private static func fallbackParse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let d = standardFormatter.date(from: string) { return d }
        return fallbackFormatter.date(from: string)
    }
}
