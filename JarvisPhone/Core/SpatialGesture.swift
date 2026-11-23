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
    private var pinchBegan: Double?
    private var pinchTarget: String?
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
            if pinchBegan == nil || pinchTarget != target { pinchBegan=time;pinchTarget=target }
            guard time-(pinchBegan ?? time)>=0.12 else { return [] }
            pinched = true
            held = target
            return target.map { [.press($0)] } ?? []
        }
        pinchBegan=nil;pinchTarget=nil
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

/// Horizontal movement of the two-finger pose, in fractions of the viewport.
struct SpatialPageSwipe {
    private var origin: CGPoint?
    private var started = 0.0
    private var lastTime: Double?
    private var fired = false

    mutating func update(point: CGPoint?, time: Double) -> Int? {
        guard let point, time.isFinite else { self = Self(); return nil }
        if let lastTime, time < lastTime || time-lastTime > 0.35 { self = Self() }
        lastTime=time
        guard let origin else { self.origin=point; started=time; return nil }
        guard !fired else { return nil }
        let dx=point.x-origin.x, dy=point.y-origin.y
        if time-started > 1.2 || abs(dy)>0.14 { self.origin=point; started=time; return nil }
        guard time-started >= 0.12, abs(dx)>=0.18, abs(dx)>1.5*abs(dy) else { return nil }
        fired=true
        return dx < 0 ? 1 : -1
    }
}

/// An open palm must remain over the selected target before depth motion scales
/// it. A free hand elsewhere cannot resize a selected object accidentally.
struct SpatialPalmScale {
    private var target: String?
    private var began=0.0
    private var lastTime=0.0
    private var previous: Double?
    private var filtered: Double?
    mutating func update(target: String?, depth: Double?, time: Double) -> Float? {
        guard let target,let depth,depth.isFinite,time.isFinite,(0.15...2).contains(depth) else { self=Self();return nil }
        if self.target != target || time-lastTime>0.35 || time<lastTime {
            self.target=target;began=time;previous=depth;filtered=depth
        }
        lastTime=time
        filtered=(filtered ?? depth)*0.65+depth*0.35
        guard time-began>=0.45,let value=filtered,let previous,abs(value-previous)>0.035 else { return nil }
        let multiplier=Float(exp((previous-value)*2))
        self.previous=value
        return min(1.2,max(0.8,multiplier))
    }
}
