import Testing
import Foundation
import Sentry
@testable import HopwatchGUI

@Suite("CrashReporterTests")
struct CrashReporterTests {

    @Test("Sentry options configure crash handler and disable HTTP / network tracking")
    func sentryOptionsConfiguration() {
        let options = Options()
        CrashReporter.configure(options: options)

        #expect(options.enableCrashHandler == true)
        #expect(options.enableAppHangTracking == false)
        #expect(options.enableNetworkTracking == false)
        #expect(options.enableCaptureFailedRequests == false)
        #expect(options.enableNetworkBreadcrumbs == false)
        #expect(options.enableFileIOTracing == false)
        #expect(options.dsn == CrashReporter.dsn)
    }

    @Test("Sanitize redacts user home directory and username from crash payloads")
    func sanitizeRedactsPII() {
        let username = NSUserName()
        let homeDir = NSHomeDirectory()

        let event = Event()
        event.message = SentryMessage(formatted: "Crash while loading \(homeDir)/secret.json for \(username)")

        let exception = Exception(value: "Failed at \(homeDir)/App/main.swift", type: "Crash")
        event.exceptions = [exception]

        let breadcrumb = Breadcrumb(level: .info, category: "file")
        breadcrumb.message = "Opened \(homeDir)/Documents/file.txt"
        event.breadcrumbs = [breadcrumb]

        let sanitized = CrashReporter.sanitize(event: event)

        #expect(sanitized.message?.formatted.contains(homeDir) == false)
        #expect(sanitized.message?.formatted.contains("/Users/<redacted>") == true)

        #expect(sanitized.exceptions?.first?.value.contains(homeDir) == false)
        #expect(sanitized.exceptions?.first?.value.contains("/Users/<redacted>") == true)

        #expect(sanitized.breadcrumbs?.first?.message?.contains(homeDir) == false)
        #expect(sanitized.breadcrumbs?.first?.message?.contains("/Users/<redacted>") == true)
    }
}
