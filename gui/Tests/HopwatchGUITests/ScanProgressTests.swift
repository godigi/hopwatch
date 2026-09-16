import Testing
import Foundation
@testable import HopwatchGUI

@Suite("ScanProgressTests")
struct ScanProgressTests {

    @Test("speed direction mapping and labels")
    func speedDirectionMapping() {
        let dl = ScanProgress.Speed(stage: "download", progress: 0.5, mbps: 200.0)
        #expect(dl.direction == .download)
        #expect(dl.directionSymbol == "↓")
        #expect(dl.directionLabel == "↓ Download")

        let ul = ScanProgress.Speed(stage: "upload", progress: 0.8, mbps: 50.0)
        #expect(ul.direction == .upload)
        #expect(ul.directionSymbol == "↑")
        #expect(ul.directionLabel == "↑ Upload")

        let ping = ScanProgress.Speed(stage: "ping", progress: 0.2, mbps: nil)
        #expect(ping.direction == .ping)
        #expect(ping.directionSymbol == "●")
        #expect(ping.directionLabel == "Ping")

        let prep = ScanProgress.Speed(stage: "testStart")
        #expect(prep.direction == .prep)
        #expect(prep.directionSymbol == "⋯")
        #expect(prep.directionLabel == "Preparing")

        let other = ScanProgress.Speed(stage: "custom_check")
        #expect(other.direction == .other)
        #expect(other.directionSymbol == nil)
        #expect(other.directionLabel == "Custom check")
    }

    @Test("in-flight speed milestone accumulation and active testing state")
    @MainActor
    func speedMilestoneAccumulation() {
        let progress = ScanProgress()
        #expect(!progress.isSpeedTesting)

        // Ingest plan
        progress.ingest(line: #"{"t":"plan","mode":"full","phases":["gateway","speedtest","mtr"]}"#)
        #expect(!progress.isSpeedTesting)
        #expect(progress.plannedCount == 3)

        // Start speedtest phase
        progress.ingest(line: #"{"t":"phase","name":"speedtest","state":"start"}"#)
        #expect(progress.isSpeedTesting)

        // Download milestone
        progress.ingest(line: #"{"t":"speed","stage":"download","progress":0.45,"mbps":254.3}"#)
        #expect(progress.isSpeedTesting)
        #expect(progress.speed?.mbps == 254.3)
        #expect(progress.speed?.downloadMbps == 254.3)
        #expect(progress.speed?.uploadMbps == nil)
        #expect(progress.speed?.direction == .download)

        // Upload milestone (downloadMbps is preserved!)
        progress.ingest(line: #"{"t":"speed","stage":"upload","progress":0.8,"mbps":84.1}"#)
        #expect(progress.isSpeedTesting)
        #expect(progress.speed?.mbps == 84.1)
        #expect(progress.speed?.downloadMbps == 254.3)
        #expect(progress.speed?.uploadMbps == 84.1)
        #expect(progress.speed?.direction == .upload)

        // Finish speedtest phase -> reverts gracefully
        progress.ingest(line: #"{"t":"phase","name":"speedtest","state":"done","rc":0,"ms":24500}"#)
        #expect(!progress.isSpeedTesting)
        #expect(progress.speed == nil)
    }

    @Test("speedtest skipped reverts gracefully")
    @MainActor
    func speedtestSkippedReverts() {
        let progress = ScanProgress()
        progress.ingest(line: #"{"t":"plan","mode":"quick","phases":["gateway","speedtest"]}"#)
        progress.ingest(line: #"{"t":"phase","name":"speedtest","state":"start"}"#)
        #expect(progress.isSpeedTesting)

        progress.ingest(line: #"{"t":"phase","name":"speedtest","state":"skip","why":"--quick"}"#)
        #expect(!progress.isSpeedTesting)
        #expect(progress.speed == nil)
    }
}
