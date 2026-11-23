import Foundation
import CoreGraphics

/// Time-based hysteresis: missing samples never count as a deliberate release.
struct SpatialGesture {
    enum Event: Equatable { case press(String), drag(String), release(String,Bool), poke(String), cancel }
    private var armed=false
    private var opening=0
    private var closing=0
    private var target:String?
    private var began:Double=0
    private var dragging=false
    private var lastSeen:Double=0
    private var hover:String?
    private var hoverSince:Double=0
    private var pushBase:Double?
    private var pushLatched=false
    private var lastClick:Double = -.infinity

    mutating func reset() { self=Self() }
    mutating func update(point:CGPoint?,ratio:Double,target hit:String?,push:Double?,time:Double) -> [Event] {
        guard let point,point.x.isFinite,point.y.isFinite,ratio.isFinite else {
            if target != nil { reset();return [.cancel] }
            if time-lastSeen>0.18 { let held=target != nil;reset();return held ? [.cancel] : [] }
            return []
        }
        if lastSeen>0 && time-lastSeen>0.25 { reset() }
        lastSeen=time
        if hit != hover { hover=hit;hoverSince=time;pushBase=push;pushLatched=false }
        if ratio>0.55 {
            opening+=1;closing=0
            if opening>=2 {
                if let target {
                    let click = !dragging && time-began<0.5 && time-lastClick>0.6
                    self.target=nil;dragging=false;armed=false;opening=0;lastClick=time
                    return [.release(target,click)]
                }
                armed=true
            }
            if let push,let base=pushBase,pushLatched,push<base-0.02 { pushLatched=false;pushBase=push }
            if let hit,let push,let base=pushBase,!pushLatched,armed,time-hoverSince>0.2,time-lastClick>0.9,
               push-base>0.035,push-base<0.12 {
                lastClick=time;armed=false;opening=0;pushBase=push;pushLatched=true;return [.poke(hit)]
            }
            if !pushLatched,let push,let base=pushBase,push<base { pushBase=push }
        } else if ratio<0.28 {
            closing+=1;opening=0
            if target==nil,armed,closing>=2,let hit,time-hoverSince>0.12,time-lastClick>0.6 {
                target=hit;began=time;dragging=false;armed=false;return [.press(hit)]
            }
        } else { opening=0;closing=0 }
        if let target,ratio<0.55,time-began>=0.4 {
            dragging=true;return [.drag(target)]
        }
        return []
    }
}
