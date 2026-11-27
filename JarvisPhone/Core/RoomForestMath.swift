import Foundation
import simd

enum SpatialHandTarget:Equatable {
    case none,panel,desktop,object,portal,game,portalGun,liveWall,capturedWall
    static func choose(held:Self?=nil,panel:Bool=false,desktop:Bool=false,object:Bool=false,portal:Bool=false,placing:Bool=false,gun:Bool=false,liveWall:Bool=false,capturedWall:Bool=false,game:Bool=false)->Self {
        if let held { return held }
        if panel { return .panel };if desktop { return .desktop };if portal { return .portal };if object { return .object }
        if gun { return .portalGun };if liveWall { return .liveWall };if capturedWall { return .capturedWall }
        if placing { return .object };return game ? .game : .none
    }
}

/// Save only a settled move to a new area, never a stationary stream of snapshots.
struct SpatialAreaSaveGate {
    private var saved:SIMD3<Float>?
    private var quiet:SIMD3<Float>?
    private var quietSince:Double=0
    private var lastAttempt = -Double.infinity
    mutating func record(position:SIMD3<Float>,time:Double) {
        saved=position;quiet=position;quietSince=time;lastAttempt=time
    }
    mutating func update(position:SIMD3<Float>,time:Double,stable:Bool)->Bool {
        guard time.isFinite,position.x.isFinite,position.y.isFinite,position.z.isFinite else { quiet=nil;return false }
        guard stable else { quiet=nil;return false }
        guard let saved else { record(position:position,time:time);return false }
        if quiet == nil || simd_distance(quiet!,position)>0.08 { quiet=position;quietSince=time }
        let delta=SIMD2(position.x-saved.x,position.z-saved.z)
        guard simd_length(delta)>=1.5,time-quietSince>=2,time-lastAttempt>=25 else { return false }
        lastAttempt=time;return true
    }
}

/// A metric fit is accepted only when geometry, gravity and a distinct solution agree.
enum RoomForestRegistration {
    struct Point:Sendable { var p:SIMD3<Float>;var n:SIMD3<Float>;var kind:Int }
    struct Wall:Sendable {
        var center:SIMD3<Float>;var normal:SIMD3<Float>
        var low:Float;var high:Float;var bottom:Float;var top:Float
        var tangent:SIMD3<Float> { simd_normalize(simd_cross(SIMD3<Float>(0,1,0),normal)) }
        func error(_ p:SIMD3<Float>,_ n:SIMD3<Float>)->Float {
            guard abs(simd_dot(n,normal))>0.96 else { return 10 }
            let u=simd_dot(p,tangent)
            guard u>low-0.35,u<high+0.35,p.y>bottom-0.25,p.y<top+0.25 else { return 10 }
            return abs(simd_dot(p-center,normal))
        }
    }
    struct Capture:Sendable { var floor:Float;var walls:[Wall];var points:[Point] }
    struct Match:Sendable { var pose:simd_float4x4;var support:Float;var error:Float;var margin:Float }
    private struct Cell:Hashable { var x:Int;var y:Int;var z:Int
        init(_ p:SIMD3<Float>) { x=Int(floor(p.x/0.18));y=Int(floor(p.y/0.18));z=Int(floor(p.z/0.18)) }
        init(_ x:Int,_ y:Int,_ z:Int) { self.x=x;self.y=y;self.z=z }
    }
    static func fit(source:Capture,live:Capture)->Match? {
        guard source.floor.isFinite,live.floor.isFinite,source.walls.count>=2,live.walls.count>=2,
              source.points.count>=100,live.points.count>=100 else { return nil }
        let walls=Array(live.walls.prefix(8))
        var candidates:[(simd_float4x4,Float)]=[]
        for i in walls.indices { for j in walls.indices where j>i {
            let a=walls[i],b=walls[j],det=a.normal.x*b.normal.z-a.normal.z*b.normal.x
            guard abs(det)>0.35 else { continue }
            for c in source.walls { for d in source.walls {
                guard abs(simd_dot(c.normal,d.normal))<0.92 else { continue }
                for sign:Float in [-1,1] {
                    let angle=atan2(c.normal.z,c.normal.x)-atan2(a.normal.z*sign,a.normal.x*sign)
                    var pose=simd_float4x4(simd_quatf(angle:angle,axis:SIMD3(0,1,0)))
                    let rn=pose*SIMD4(d.normal,0)
                    guard abs(simd_dot(SIMD3(rn.x,rn.y,rn.z),b.normal))>0.985 else { continue }
                    let ca=pose*SIMD4(c.center,1),db=pose*SIMD4(d.center,1)
                    let x=simd_dot(a.center-SIMD3(ca.x,ca.y,ca.z),a.normal)
                    let y=simd_dot(b.center-SIMD3(db.x,db.y,db.z),b.normal)
                    pose.columns.3=SIMD4((x*b.normal.z-y*a.normal.z)/det,live.floor-source.floor,(a.normal.x*y-b.normal.x*x)/det,1)
                    let inverse=simd_inverse(pose)
                    var error:Float=0,matched=0
                    for wall in walls {
                        let p=inverse*SIMD4(wall.center,1),n=inverse*SIMD4(wall.normal,0)
                        let e=source.walls.map{$0.error(SIMD3(p.x,p.y,p.z),SIMD3(n.x,n.y,n.z))}.min() ?? 10
                        if e<0.18 { matched+=1 };error+=min(0.5,e)
                    }
                    guard matched>=min(3,walls.count),matched*4>=walls.count*3 else { continue }
                    if candidates.contains(where:{simd_distance($0.0.columns.3,pose.columns.3)<0.12 && simd_dot($0.0.columns.0,pose.columns.0)>0.999}) { continue }
                    candidates.append((pose,error/Float(walls.count)))
                }
            }}
        }}
        candidates.sort{$0.1<$1.1};candidates=Array(candidates.prefix(walls.count==2 ? 96 : 32))
        var grid:[Cell:[Point]]=[:]
        for point in source.points { grid[Cell(point.p),default:[]].append(point) }
        let step=max(1,live.points.count/1600),sample=stride(from:0,to:live.points.count,by:step).map{live.points[$0]}
        var results:[Match]=[]
        for (pose,_) in candidates {
            let inverse=simd_inverse(pose)
            var hits=0,distance:Float=0,wallHits=0,wallCount=0,detailHits=0,detailCount=0
            for point in sample {
                let q=inverse*SIMD4(point.p,1),n=inverse*SIMD4(point.n,0),p=SIMD3(q.x,q.y,q.z),normal=SIMD3(n.x,n.y,n.z),cell=Cell(p)
                var best:Float=0.18
                for x in -1...1 { for y in -1...1 { for z in -1...1 {
                    for s in grid[Cell(cell.x+x,cell.y+y,cell.z+z)] ?? [] {
                        guard point.kind==0 || s.kind==point.kind,abs(simd_dot(s.n,normal))>0.7 else { continue }
                        best=min(best,simd_distance(p,s.p))
                    }
                }}}
                if point.kind==1 { wallCount+=1 };if point.kind==0 { detailCount+=1 }
                if best<0.18 {
                    hits+=1;distance+=best
                    if point.kind==1 { wallHits+=1 };if point.kind==0 { detailHits+=1 }
                }
            }
            guard wallCount>=50,hits>=80 else { continue }
            let fraction=Float(hits)/Float(sample.count),wallFraction=Float(wallHits)/Float(wallCount)
            // Furniture provides the asymmetry needed to disambiguate similar corners.
            let detailFraction=detailCount>30 ? Float(detailHits)/Float(detailCount) : fraction
            let support=fraction*0.45+wallFraction*0.35+detailFraction*0.20,error=distance/Float(hits)
            if support>=0.72,wallFraction>=0.70,error<0.12 { results.append(Match(pose:pose,support:support,error:error,margin:0)) }
        }
        results.sort{($0.support-$0.error)>($1.support-$1.error)}
        guard var best=results.first else { return nil }
        let other=results.dropFirst().first { simd_distance($0.pose.columns.3,best.pose.columns.3)>0.30 || simd_dot($0.pose.columns.0,best.pose.columns.0)<0.98 }
        best.margin=other.map{(best.support-best.error)-($0.support-$0.error)} ?? 1
        guard best.margin>=0.055 else { return nil };return best
    }
}

/// Deliberate thumb trigger after a stable gun pose; loss never fires a shot.
struct SpatialPortalTrigger {
    private var readyAt:Double?
    private var primed=false
    private var lastTime:Double?
    private var lastShot = -Double.infinity
    mutating func reset() { readyAt=nil;primed=false;lastTime=nil }
    mutating func update(gun:Bool?,thumbRaised:Bool,time:Double)->Bool {
        guard time.isFinite else { reset();return false }
        if let lastTime,time<lastTime || time-lastTime>0.4 { reset() }
        lastTime=time
        guard gun==true,time-lastShot>0.7 else { readyAt=nil;primed=false;return false }
        if thumbRaised {
            if readyAt==nil { readyAt=time }
            if time-(readyAt ?? time)>=0.3 { primed=true }
            return false
        }
        guard primed else { readyAt=nil;return false }
        lastShot=time;readyAt=nil;primed=false;return true
    }
}

struct SpatialDoorPassage {
    private var previous:(SIMD3<Float>,Double)?
    private var side:Int?
    private var crossed=false
    mutating func reset() { previous=nil;side=nil;crossed=false }
    /// +Z is the mapped room. Only a continuous path through the actual aperture counts.
    mutating func update(position p:SIMD3<Float>,time:Double,width:Float,height:Float,stable:Bool)->Bool? {
        guard stable,p.x.isFinite,p.y.isFinite,p.z.isFinite,time.isFinite else { reset();return nil }
        defer { previous=(p,time) }
        guard let (old,t)=previous,time>t,time-t<0.4,simd_distance(old,p)<0.45 else {
            side=abs(p.z)>0.18 ? (p.z>0 ? 1 : -1) : nil;crossed=false;return nil
        }
        if old.z*p.z<0 {
            let k=old.z/(old.z-p.z),at=old+(p-old)*k
            crossed=abs(at.x)<width/2+0.05 && abs(at.y)<height/2+0.05
        }
        guard abs(p.z)>0.18 else { return nil }
        let next=p.z>0 ? 1 : -1
        let oldSide=side;side=next
        guard let oldSide,oldSide != next,crossed else { crossed=false;return nil }
        crossed=false;return next==1
    }
}

enum RoomForestShot {
    static func visible(target:Float?,obstacle:Float?)->Bool {
        guard let target,target.isFinite,target>0 else { return false }
        guard let obstacle else { return true }
        guard obstacle.isFinite,obstacle>0 else { return false }
        return target<=obstacle+0.08
    }
}
