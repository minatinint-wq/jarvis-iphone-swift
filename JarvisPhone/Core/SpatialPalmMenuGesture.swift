import Foundation

/// Upturned, open palm followed by a deliberate four-finger curl. Pinches and
/// pointing never trigger; a held pose cannot repeatedly toggle the menu.
struct SpatialPalmMenuGesture {
    static func facing(_ points:[CGPoint?])->Bool {
        guard points.count==21,let wrist=points[0],let index=points[5],let middle=points[9],let pinky=points[17] else { return false }
        let span=hypot(index.x-pinky.x,index.y-pinky.y),height=hypot(wrist.x-middle.x,wrist.y-middle.y)
        guard span>0.001,height>span*0.28 else { return false }
        let area=abs((index.x-wrist.x)*(pinky.y-wrist.y)-(index.y-wrist.y)*(pinky.x-wrist.x))
        return area/(span*height)>0.28 && [index,middle,pinky].allSatisfy{$0.y<wrist.y-span*0.06} && abs(index.y-pinky.y)<span*0.85
    }
    private var openSince:Double?
    private var curledSince:Double?
    private var primed=false
    private var latched=false
    private var previous:Double?
    mutating func update(palmUp:Bool?,open:Bool,curled:Bool,time:Double,dragging:Bool=false)->Bool {
        guard time.isFinite else { self=Self();return false }
        if let previous,time<previous || time-previous>0.35 { self=Self() }
        previous=time
        guard palmUp==true,!dragging else { openSince=nil;curledSince=nil;primed=false;return false }
        if open {
            curledSince=nil
            if openSince == nil { openSince=time }
            if time-(openSince ?? time)>=0.18 { primed=true;latched=false }
            return false
        }
        guard primed,!latched,curled else { curledSince=nil;return false }
        if curledSince == nil { curledSince=time }
        guard time-(curledSince ?? time)>=0.22 else { return false }
        latched=true;primed=false;openSince=nil;curledSince=nil;return true
    }
}
