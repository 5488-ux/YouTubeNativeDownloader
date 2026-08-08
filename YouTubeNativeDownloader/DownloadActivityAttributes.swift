import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var resolveProgress: Double
        var videoProgress: Double
        var audioProgress: Double
        var speedText: String
        var etaText: String
        var statusText: String
        var titleText: String
    }

    var title: String
    var kind: String
}
