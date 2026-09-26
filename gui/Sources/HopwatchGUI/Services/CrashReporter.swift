import Foundation
import Sentry

/// Central coordinator for anonymous crash reporting via Sentry.
enum CrashReporter {

    static let dsn = "https://c521349348d1e46ab939b4731040ca08@o4512149999517696.ingest.us.sentry.io/4512150020358144"

    /// Initializes Sentry SDK with privacy safeguards.
    static func start() {
        guard !CommandLine.arguments.contains("--verify"),
              !CommandLine.arguments.contains("--gallery"),
              Defaults.crashReportingEnabled else {
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.enableCrashHandler = true
            options.enableAppHangTracking = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                options.releaseName = "hopwatch@\(version)"
            }

            options.beforeSend = { event in
                guard Defaults.crashReportingEnabled else { return nil }
                return sanitize(event: event)
            }
        }
    }

    /// Dynamically enables or disables Sentry based on user preference.
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            SentrySDK.close()
        }
    }

    /// Strips local usernames and user home directory paths from crash payloads.
    private static func sanitize(event: Event) -> Event {
        let username = NSUserName()
        let homeDir = NSHomeDirectory()

        func redact(_ str: String) -> String {
            str.replacingOccurrences(of: homeDir, with: "/Users/<redacted>")
               .replacingOccurrences(of: "/Users/\(username)", with: "/Users/<redacted>")
        }

        if let msg = event.message {
            event.message = SentryMessage(formatted: redact(msg.formatted))
        }

        if let exceptions = event.exceptions {
            for exc in exceptions {
                exc.value = redact(exc.value)
            }
        }

        if let breadcrumbs = event.breadcrumbs {
            for b in breadcrumbs {
                b.message = b.message.map { redact($0) }
            }
        }

        return event
    }
}
