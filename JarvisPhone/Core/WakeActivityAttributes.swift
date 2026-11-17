import ActivityKit
import Foundation

struct WakeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
        var steps: Int?
        var stepsDate: Date?
        var battery: Int?
        var preview: String?
        var received: Date?
    }
}
