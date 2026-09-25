import AppKit
import Foundation
import UniformTypeIdentifiers

/// Utilities for exporting and sharing redacted diagnostics across RunReportView and DropdownView.
enum DiagnosticReportSharing {

    private static let lock = NSLock()
    private static let fallbackDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df
    }()

    /// Default file name based on run timestamp or current date.
    nonisolated static func defaultFileName(extension ext: String, timestamp: String? = nil) -> String {
        let base: String
        if let ts = timestamp, !ts.isEmpty {
            let sanitized = ts.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "T", with: "-")
                .replacingOccurrences(of: "Z", with: "")
            base = "netdiag-report-\(sanitized)"
        } else {
            lock.lock()
            let formatted = fallbackDateFormatter.string(from: Date())
            lock.unlock()
            base = "netdiag-report-\(formatted)"
        }
        return "\(base).\(ext)"
    }

    /// Copies the redacted report to the system pasteboard.
    @discardableResult
    static func copyRedactedReport(rawJSON: String?) async throws -> String {
        let text = try await NetdiagRunner.share(rawJSON: rawJSON)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    /// Copies the redacted JSON to the system pasteboard.
    @discardableResult
    static func copyRedactedJSON(rawJSON: String?) async throws -> String {
        let json = try await NetdiagRunner.shareJSON(rawJSON: rawJSON)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        return json
    }

    /// Opens an NSSavePanel and saves text content to the selected destination.
    static func saveFile(
        content: String,
        defaultName: String,
        contentType: UTType
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
