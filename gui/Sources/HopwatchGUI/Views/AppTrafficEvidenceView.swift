import SwiftUI

/// Shared by the menu, dashboard teaser and complete activity history.
struct AppTrafficEvidenceView: View {
    let entry: ActivityEntry
    var limit: Int? = nil

    var body: some View {
        if !entry.trafficEvidence.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(entry.trafficEvidence.prefix(limit ?? entry.trafficEvidence.count)), id: \.captureKey) { evidence in
                    Text(evidence.detail)
                        .help(["High traffic observed while latency was elevated; cause not confirmed.",
                               evidence.latencyDetail].compactMap { $0 }.joined(separator: "\n"))
                }
                if let limit, entry.trafficEvidence.count > limit {
                    Text("\(entry.trafficEvidence.count - limit) more traffic observations in Activity")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
