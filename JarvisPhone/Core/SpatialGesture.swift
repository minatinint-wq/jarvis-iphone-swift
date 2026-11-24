import Foundation
import simd

/// The SDK callback and display-link fallback share one monotonic frame input.
struct SpatialFrameGate {
    private var last = -Double.infinity
    mutating func accept(_ timestamp:Double) -> Bool {
        guard timestamp.isFinite,timestamp>last else { return false }
        last=timestamp;return true
    }
}

/// Reject discontinuous camera poses without smoothing or delaying head motion.
/// A relocalization correction must settle before spatial input becomes active.
struct SpatialPoseStability {
    private var previous: SIMD3<Float>?
    private var direction: SIMD3<Float>?
    private var time: Double?
    private var settleUntil = -Double.infinity
    mutating func reset() { self=Self() }
    mutating func update(position: SIMD3<Float>,forward: SIMD3<Float>,time: Double) -> Bool {
        guard time.isFinite,position.x.isFinite,position.y.isFinite,position.z.isFinite,
              forward.x.isFinite,forward.y.isFinite,forward.z.isFinite,simd_length(forward)>0.5 else { reset();return false }
        let next=simd_normalize(forward)
        if let old=self.time,let previous,let direction {
            let dt=time-old
            if dt<=0 || dt>0.25 { settleUntil=time+0.8 }
            else {
                let distance=simd_distance(position,previous)
                let angle=acos(min(1,max(-1,simd_dot(direction,next))))
                if distance>max(0.18,Float(dt)*3) || angle>max(0.65,Float(dt)*10) { settleUntil=time+0.8 }
            }
        }
        previous=position;direction=next;self.time=time
        return time>=settleUntil
    }
}

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
    private var pinchLostSince: Double?
    private(set) var progress = 0.0

    mutating func reset() { self = Self() }

    mutating func update(ratio: Double, pointing: Bool, target: String?, time: Double) -> [Event] {
        let interrupted = lastTime.map { time < $0 || time - $0 > 0.35 } ?? false
        let invalidPinch = !ratio.isFinite && (!pointing || pinched)
        if interrupted || !time.isFinite {
            let active = held != nil
            reset()
            if active || invalidPinch || !time.isFinite { return active ? [.cancel] : [] }
        }
        if invalidPinch && pinched {
            if pinchLostSince == nil { pinchLostSince=time }
            lastTime=time;progress=0
            if time-(pinchLostSince ?? time)<=0.25 { return [] }
            let active=held != nil;reset();return active ? [.cancel] : []
        }
        if invalidPinch { reset();return [] }
        pinchLostSince=nil
        lastTime = time
        if ratio.isFinite && (ratio < 0.28 || (pinched && ratio < 0.48)) {
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
        if target != hover { hover = target; began = time; progress = 0; fired=false }
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

struct SpatialPalmCalibration {
    private var target: String?
    private var span=0.0
    private var depth=0.5
    private var metric=false
    mutating func estimate(target: String?,span: Double?,measured: Double?) -> Double? {
        guard let target,let span,span.isFinite,span>0.015 else { self=Self();return nil }
        if self.target != target {
            self.target=target;self.span=span;depth=measured ?? 0.5;metric=measured != nil
        }
        let value=(metric ? measured : nil) ?? depth*self.span/span
        return min(2,max(0.15,value))
    }
}

struct SpatialPalmRecall {
    private var target: String?
    private var started=0.0
    private var lastTime=0.0
    private var fired=false
    private(set) var progress=0.0
    var hasFired: Bool { fired }
    mutating func update(open: Bool,target: String?,overInterface: Bool,time: Double) -> String? {
        guard open,time.isFinite else { self=Self();return nil }
        if fired { return nil }
        guard !overInterface,let target else { self=Self();return nil }
        if self.target != target || time-lastTime>0.35 || time<lastTime {
            self.target=target;started=time;fired=false
        }
        lastTime=time
        progress=min(1,max(0,time-started))
        guard !fired,time-started>=1 else { return nil }
        fired=true;return target
    }
}

/// Depth motion during an owned pinch changes size; screen motion still drags.
struct SpatialPinchZoom {
    private var span: Double?
    private var initialDepth=0.5
    private var metric=false
    private var filtered=1.0
    private var applied=1.0
    private var lastTime: Double?
    mutating func begin(span: Double?,depth: Double?,time: Double) {
        self=Self();self.span=span.flatMap { $0.isFinite && $0>0.015 ? $0 : nil }
        if let depth,depth.isFinite,(0.15...2).contains(depth) { initialDepth=depth;metric=true }
        filtered=1;applied=1;lastTime=time
    }
    mutating func update(span: Double?,depth: Double?,time: Double) -> Float? {
        guard let lastTime,time.isFinite,time>=lastTime,time-lastTime<0.45 else { self=Self();return nil }
        let dt=time-lastTime
        self.lastTime=time
        let value:Double
        if metric {
            guard let depth,depth.isFinite,(0.15...2).contains(depth) else { return nil }
            value=initialDepth/depth
        }
        else if let original=self.span,let span,span.isFinite,span>0.015 { value=span/original }
        else { return nil }
        guard (0.25...4).contains(value),dt>0 else { return nil }
        // A fixed origin avoids cumulative zoom from small palm-width noise.
        let alpha=1-exp(-dt/0.18)
        filtered+=(value-filtered)*alpha
        guard abs(log(filtered/applied))>0.09 else { return nil }
        let limit=exp(min(0.08,dt*0.8))
        let factor=min(limit,max(1/limit,filtered/applied))
        applied*=factor
        return Float(factor)
    }
}

/// Brief camera occlusion does not throw away an already stable room. Actual
/// relocalization, interruptions and longer losses must still hide old anchors.
struct WallTrackingGate {
    private var normalSince: TimeInterval?
    private var lastNormal: TimeInterval?
    private var ready=false
    mutating func update(normal: Bool,at time: TimeInterval,transient: Bool = false) -> Bool {
        guard time.isFinite else { self=Self();return false }
        if normal {
            if let lastNormal,time<lastNormal { self=Self() }
            lastNormal=time
            if ready { return true }
            if normalSince == nil { normalSince=time }
            ready=time-(normalSince ?? time)>=0.6;return ready
        }
        if transient,ready,let lastNormal,time>=lastNormal,time-lastNormal<=1.2 { return true }
        self=Self();return false
    }
}
