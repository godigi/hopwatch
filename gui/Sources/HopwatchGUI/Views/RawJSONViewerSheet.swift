import SwiftUI
import UniformTypeIdentifiers

/// Dedicated sheet for inspecting, searching, copying, and saving raw diagnostic JSON payloads.
struct RawJSONViewerSheet: View {
    let rawJSON: String?
    var title: String = "Raw JSON Report"
    var defaultFileName: String = "hopwatch-report.json"
    @Binding var isPresented: Bool

    @State private var searchQuery: String = ""
    @State private var copied: Bool = false
    @State private var wrapLines: Bool = true

    private var jsonText: String {
        rawJSON ?? "{\n  \"error\": \"No raw JSON available\"\n}"
    }

    private var matchCount: Int {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let pattern = NSRegularExpression.escapedPattern(for: query)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        let range = NSRange(jsonText.startIndex..., in: jsonText)
        return regex.numberOfMatches(in: jsonText, options: [], range: range)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.ColorToken.ink)
                    Text("\(jsonText.components(separatedBy: .newlines).count) lines · \(ByteCountFormatter.string(fromByteCount: Int64(jsonText.utf8.count), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(Theme.ColorToken.muted)
                }

                Spacer()

                // Search Bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.muted)
                    TextField("Filter JSON…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 140)

                    if !searchQuery.isEmpty {
                        Text("\(matchCount)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(matchCount > 0 ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(matchCount > 0 ? Theme.ColorToken.blueWash : Theme.ColorToken.nodeBackground)
                            .clipShape(Capsule())

                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ColorToken.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.ColorToken.nodeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))

                // Line Wrap Toggle
                Button {
                    wrapLines.toggle()
                } label: {
                    Image(systemName: wrapLines ? "text.word.spacing" : "arrow.left.and.right.text.vertical")
                        .font(.system(size: 11))
                        .foregroundStyle(wrapLines ? Theme.ColorToken.blue : Theme.ColorToken.muted)
                        .padding(5)
                        .background(Theme.ColorToken.nodeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(wrapLines ? "Disable soft word wrap" : "Enable soft word wrap")

                // Copy Button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: copied ? .bold : .regular))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(copied ? Theme.ColorToken.green : Theme.ColorToken.ink)
                    .background(Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(copied ? Theme.ColorToken.green.opacity(0.5) : Theme.ColorToken.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(rawJSON == nil)
                .opacity(rawJSON == nil ? 0.45 : 1.0)

                // Save Button
                Button {
                    DiagnosticReportSharing.saveFile(
                        content: jsonText,
                        defaultName: defaultFileName,
                        contentType: .json
                    )
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text("Save…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Theme.ColorToken.ink)
                    .background(Theme.ColorToken.nodeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.ColorToken.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(rawJSON == nil)
                .opacity(rawJSON == nil ? 0.45 : 1.0)

                // Done Button
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.ColorToken.cardBackground)

            Divider()

            // JSON Content Scroll Area
            ScrollView(wrapLines ? [.vertical] : [.horizontal, .vertical]) {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(jsonText)
                        .font(Theme.Font.rawJSONMonospace)
                        .foregroundStyle(Theme.ColorToken.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    highlightedContentView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    @ViewBuilder
    private var highlightedContentView: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = jsonText.components(separatedBy: .newlines)
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if line.localizedCaseInsensitiveContains(query) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.blue)
                            .frame(width: 32, alignment: .trailing)

                        Text(line)
                            .font(Theme.Font.rawJSONMonospace)
                            .foregroundStyle(Theme.ColorToken.ink)
                            .padding(.horizontal, 4)
                            .background(Theme.ColorToken.amberWash)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.muted.opacity(0.4))
                            .frame(width: 32, alignment: .trailing)

                        Text(line)
                            .font(Theme.Font.rawJSONMonospace)
                            .foregroundStyle(Theme.ColorToken.muted.opacity(0.6))
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}
