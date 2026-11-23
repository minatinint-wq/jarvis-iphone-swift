import Foundation

/// A pinch owns its original target until release. Only pointing can activate it.
struct SpatialGesture {
    enum Event: Equatable { case press(String), drag(String), release, click(String), cancel }
    private var held: String?
    private var pinched = false
    private var hover: String?
    private var began = 0.0
    private var fired = false
    private var lastTime: Double?
    private(set) var progress = 0.0

    mutating func reset() { self = Self() }

    mutating func update(ratio: Double, pointing: Bool, target: String?, time: Double) -> [Event] {
        let interrupted = lastTime.map { time < $0 || time - $0 > 0.35 } ?? false
        if interrupted || !ratio.isFinite || !time.isFinite {
            let active = held != nil
            reset()
            if active || !ratio.isFinite || !time.isFinite { return active ? [.cancel] : [] }
        }
        lastTime = time
        if ratio < 0.28 || (pinched && ratio < 0.48) {
            hover = nil
            progress = 0
            fired = false
            if pinched { return held.map { [.drag($0)] } ?? [] }
            pinched = true
            held = target
            return target.map { [.press($0)] } ?? []
        }
        if pinched {
            pinched = false
            let active = held != nil
            held = nil
            return active ? [.release] : []
        }
        guard pointing, let target else {
            hover = nil
            fired = false
            progress = 0
            return []
        }
        if target != hover { hover = target; began = time; progress = 0 }
        guard !fired else { return [] }
        progress = min(1, (time - began) / 2)
        if time - began > 2 { fired = true; return [.click(target)] }
        return []
    }
}
