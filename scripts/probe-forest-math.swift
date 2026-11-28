import Foundation
import simd

func roomFixture(detail:Bool=true)->RoomForestRegistration.Capture {
    let walls:[RoomForestRegistration.Wall]=[
        .init(center:SIMD3(0,1,1.5),normal:SIMD3(1,0,0),low:-3,high:0,bottom:0,top:2.5),
        .init(center:SIMD3(4,1,1.5),normal:SIMD3(1,0,0),low:-3,high:0,bottom:0,top:2.5),
        .init(center:SIMD3(2,1,0),normal:SIMD3(0,0,1),low:0,high:4,bottom:0,top:2.5),
        .init(center:SIMD3(2,1,3),normal:SIMD3(0,0,1),low:0,high:4,bottom:0,top:2.5)]
    var points:[RoomForestRegistration.Point]=[]
    for i in 0...12 { for j in 0...12 {
        let x=Float(i)/3,z=Float(i)/4,y=Float(j)*2.5/12
        points += [.init(p:SIMD3(0,y,z),n:SIMD3(1,0,0),kind:1),.init(p:SIMD3(4,y,z),n:SIMD3(1,0,0),kind:1),.init(p:SIMD3(x,y,0),n:SIMD3(0,0,1),kind:1),.init(p:SIMD3(x,y,3),n:SIMD3(0,0,1),kind:1)]
        if detail {
            points.append(.init(p:SIMD3(0.45+Float(i)*0.06,0.65,0.65+Float(j)*0.05),n:SIMD3(0,1,0),kind:0))
            points.append(.init(p:SIMD3(0.45+Float(i)*0.06,Float(j)*0.05,0.65),n:SIMD3(0,0,1),kind:0))
            points.append(.init(p:SIMD3(0.45,Float(j)*0.05,0.65+Float(i)*0.05),n:SIMD3(1,0,0),kind:0))
        }
    }}
    return .init(floor:0,walls:walls,points:points)
}
@main struct ForestProbe {
    static func main() {
        let source=roomFixture();var pose=simd_float4x4(simd_quatf(angle:0.63,axis:SIMD3(0,1,0)));pose.columns.3=SIMD4(0.7,0.4,-1.2,1)
        func transformed(_ source:RoomForestRegistration.Capture)->RoomForestRegistration.Capture {
            let walls=source.walls.enumerated().filter{$0.offset != 1}.map { _,w -> RoomForestRegistration.Wall in
                let c=pose*SIMD4(w.center,1),n=pose*SIMD4(w.normal,0)
                return .init(center:SIMD3(c.x,c.y,c.z),normal:SIMD3(n.x,n.y,n.z),low:0,high:0,bottom:0,top:3)
            }
            let points=source.points.filter{$0.p.x<3.95}.map { x -> RoomForestRegistration.Point in
                let p=pose*SIMD4(x.p,1),n=pose*SIMD4(x.n,0)
                return .init(p:SIMD3(p.x,p.y,p.z),n:SIMD3(n.x,n.y,n.z),kind:x.kind)
            }
            return .init(floor:0.4,walls:walls,points:points)
        }
        guard let fit=RoomForestRegistration.fit(source:source,live:transformed(source)) else { fatalError("Unique metric room fit was rejected") }
        assert(simd_distance(fit.pose.columns.3,pose.columns.3)<0.02)
        assert(simd_dot(fit.pose.columns.0,pose.columns.0)>0.999)
        let symmetric=roomFixture(detail:false)
        assert(RoomForestRegistration.fit(source:symmetric,live:transformed(symmetric))==nil,"Ambiguous room accepted")
        var gun=SpatialPortalTrigger()
        for t in [0.0,0.15,0.31] { assert(!gun.update(gun:true,thumbRaised:true,time:t)) }
        assert(gun.update(gun:true,thumbRaised:false,time:0.35));assert(!gun.update(gun:true,thumbRaised:false,time:0.4))
        _=gun.update(gun:nil,thumbRaised:false,time:0.5);assert(!gun.update(gun:true,thumbRaised:false,time:0.6))
        var door=SpatialDoorPassage(),events:[Bool]=[];var time=0.0
        for z:Float in [1,0.7,0.4,0.1,-0.1,-0.4,-0.1,0.1,0.4] {
            if let event=door.update(position:SIMD3(0,0.55,z),time:time,width:0.8,height:2,stable:true) { events.append(event) };time+=0.1
        }
        assert(events==[false,true],"Door passage direction or hysteresis failed")
        door.reset();_=door.update(position:SIMD3(0,0,-0.5),time:0,width:0.8,height:2,stable:true)
        assert(door.update(position:SIMD3(0,0,0.5),time:0.1,width:0.8,height:2,stable:true)==nil)
        var palm=[CGPoint?](repeating:nil,count:21);palm[0]=CGPoint(x:0,y:3);palm[5]=CGPoint(x:-1,y:1);palm[9]=CGPoint(x:0,y:0.8);palm[17]=CGPoint(x:1,y:1)
        assert(SpatialPalmMenuGesture.facing(palm),"Upright palm facing viewer rejected")
        let sideways=palm.map{$0.map{CGPoint(x:-$0.y,y:$0.x)}}
        assert(!SpatialPalmMenuGesture.facing(sideways),"Sideways palm summoned menu")
        var gate=SpatialPalmMenuGesture()
        for t in [0.0,0.10,0.20] { assert(!gate.update(palmUp:true,open:true,curled:false,time:t)) }
        assert(!gate.update(palmUp:true,open:false,curled:true,time:0.25))
        assert(gate.update(palmUp:true,open:false,curled:true,time:0.50))
        assert(!gate.update(palmUp:true,open:false,curled:true,time:0.60))
        print("PALM_MENU_PROBE_OK upright facing pose, sideways rejection, deliberate curl and held-pose latch")
        print("FOREST_MATH_OK unique fit, ambiguous rejection, thumb trigger, exit/reentry and tracking-jump rejection")
    }
}
