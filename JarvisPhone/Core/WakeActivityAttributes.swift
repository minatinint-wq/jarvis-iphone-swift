import ActivityKit

struct WakeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var phase: String }
}
