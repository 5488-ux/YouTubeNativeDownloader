import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var speedText: String
        var etaText: String
        var statusText: String
    }

    var title: String
    var kind: String
}
