import Foundation

struct AirString: Identifiable {
    let id = UUID()
    let start: CGPoint
    let end: CGPoint
    let note: UInt8
    var lastHit = -Double.infinity
    var hitPosition = 0.5
    var strength = 0.5
    var label: String {
        let names = ["Dó", "Dó♯", "Ré", "Ré♯", "Mi", "Fá", "Fá♯", "Sol", "Sol♯", "Lá", "Lá♯", "Si"]
        return names[Int(note) % 12] + String(Int(note) / 12 - 1)
    }
}

/// Normalized portrait coordinates; stage and mirrored camera are both 3:4.
struct AirStringBoard {
    enum Mode: String, CaseIterable { case create = "Criar", play = "Tocar" }
    struct Pluck { let note: UInt8; let velocity: UInt8 }
    struct Hold { let index: Int; let position: Double; var point: CGPoint }
    private(set) var strings: [AirString] = []
    private(set) var anchor: CGPoint?
    private(set) var held: Hold?
    private var previous: (point: CGPoint, time: Double)?
    private var pinching = false
    private var closeSince: Double?
    private var openSince: Double?
    private var armed = false
    var mode = Mode.play { didSet { resetGesture() } }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y) * 4 / 3)
    }
    static func valid(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y) }
    static func note(for length: Double) -> UInt8 {
        guard length.isFinite else { return 60 }
        let scale: [UInt8] = [48, 50, 52, 55, 57, 60, 62, 64, 67, 69, 72, 74, 76]
        return scale[Int(((1 - min(1, max(0, (length - 0.10) / 0.9))) * Double(scale.count - 1)).rounded())]
    }
    mutating func preset(guitar: Bool = false) {
        clear()
        let notes: [UInt8] = guitar ? [40,45,50,55,59,64] : [60,62,64,65,67,69,71,72]
        for (index,note) in notes.enumerated() {
            let fraction=Double(index)/Double(notes.count-1)
            let x=0.16+fraction*0.665
            strings.append(AirString(start:CGPoint(x:x,y:guitar ? 0.19 : 0.17+fraction*0.175),end:CGPoint(x:x,y:0.84),note:note))
        }
        mode = .play
    }
    mutating func resetGesture() {
        anchor = nil; held = nil; previous = nil; pinching = false
        closeSince = nil; openSince = nil; armed = false
    }
    mutating func clear() { strings.removeAll(); resetGesture() }
    mutating func undo() { if !strings.isEmpty { strings.removeLast() }; resetGesture() }
    @discardableResult mutating func add(from a: CGPoint, to b: CGPoint) -> Bool {
        guard Self.valid(a), Self.valid(b), strings.count < 12, Self.distance(a,b) >= 0.10 else { return false }
        strings.append(AirString(start:a,end:b,note:Self.note(for:Self.distance(a,b))))
        return true
    }
    private func near(_ p: CGPoint) -> Hold? {
        var best: (Hold,Double)?
        for (i,s) in strings.enumerated() {
            let dx = Double(s.end.x-s.start.x), dy = Double(s.end.y-s.start.y)*4/3
            let px = Double(p.x-s.start.x), py = Double(p.y-s.start.y)*4/3
            let t = (px*dx+py*dy)/(dx*dx+dy*dy)
            let distance = hypot(px-dx*t,py-dy*t)
            if (0.07...0.93).contains(t), distance < 0.045, distance < (best?.1 ?? .infinity) {
                best = (Hold(index:i,position:t,point:p),distance)
            }
        }
        return best?.0
    }
    mutating func beginPull(_ point: CGPoint) {
        guard mode == .play, Self.valid(point) else { return }
        held = near(point)
    }
    mutating func dragPull(_ point: CGPoint) {
        guard Self.valid(point), var hold = held else { return }
        hold.point = point; held = hold
    }
    mutating func endPull(time: Double) -> [Pluck] {
        defer { held = nil }
        guard time.isFinite, let h = held, strings.indices.contains(h.index) else { return [] }
        let s = strings[h.index]
        let origin = CGPoint(x:s.start.x+(s.end.x-s.start.x)*h.position,y:s.start.y+(s.end.y-s.start.y)*h.position)
        let strength = min(1,max(0.18,Self.distance(origin,h.point)/0.16))
        guard time-s.lastHit >= 0.18 else { return [] }
        strings[h.index].lastHit = time; strings[h.index].hitPosition = h.position; strings[h.index].strength = strength
        return [Pluck(note:s.note,velocity:UInt8(48+strength*65))]
    }
    /// Cancel tracking gaps and jumps instead of turning an occlusion into a note.
    mutating func consume(point: CGPoint, pinchRatio: Double, time: Double) -> [Pluck] {
        guard Self.valid(point), pinchRatio.isFinite, pinchRatio >= 0, time.isFinite else { resetGesture(); return [] }
        if let previous, time <= previous.time || time-previous.time > 0.25 || Self.distance(previous.point,point)>0.30 { resetGesture() }
        defer { previous = (point,time) }
        if !pinching && pinchRatio > 0.55 { armed = true }
        if !pinching && armed && pinchRatio < 0.30 {
            if closeSince == nil { closeSince = time }
            if time-(closeSince ?? time) >= 0.08 {
                pinching = true; armed = false; closeSince = nil
                if mode == .create { anchor = point } else { beginPull(point) }
            }
        } else if !pinching { closeSince = nil }
        if pinching {
            if mode == .play { dragPull(point) }
            if pinchRatio > 0.55 {
                if openSince == nil { openSince = time }
                if time-(openSince ?? time) >= 0.07 {
                    pinching = false; openSince = nil; armed = true
                    if mode == .create {
                        if let anchor { _ = add(from:anchor,to:point) }; anchor = nil
                    } else { return endPull(time:time) }
                }
            } else { openSince = nil }
            return []
        }
        guard mode == .play, pinchRatio > 0.55, let previous, time>previous.time else { return [] }
        let movement = Self.distance(previous.point,point)
        guard movement > 0.006, movement/(time-previous.time)>0.12 else { return [] }
        return strings.indices.compactMap { i in
            let s = strings[i]
            guard time-s.lastHit > 0.2, let t = Self.crossing(previous.point,point,s.start,s.end) else { return nil }
            strings[i].lastHit = time; strings[i].hitPosition = t; strings[i].strength = 0.40
            return Pluck(note:s.note,velocity:80)
        }
    }
    /// Finite before the first note too (lastHit == -infinity).
    func offset(index: Int, position t: Double, time: Double, reducedMotion: Bool = false) -> CGPoint {
        let s = strings[index]
        if let h = held, h.index == index {
            let origin = CGPoint(x:s.start.x+(s.end.x-s.start.x)*h.position,y:s.start.y+(s.end.y-s.start.y)*h.position)
            let shape = t <= h.position ? t/h.position : (1-t)/(1-h.position)
            return CGPoint(x:min(0.18,max(-0.18,h.point.x-origin.x))*shape,y:min(0.135,max(-0.135,h.point.y-origin.y))*shape)
        }
        let age = time-s.lastHit
        guard !reducedMotion, age.isFinite, age>=0, age<1.6 else { return .zero }
        let dx = s.end.x-s.start.x, dy = (s.end.y-s.start.y)*4/3, length = hypot(dx,dy)
        let wave = 0.035*s.strength*exp(-age*3.5)*sin(t * .pi)*sin(age*40)
        return CGPoint(x:-dy/length*wave,y:dx/length*wave*3/4)
    }
    static func crossing(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Double? {
        let rx=Double(b.x-a.x),ry=Double(b.y-a.y),sx=Double(d.x-c.x),sy=Double(d.y-c.y)
        let den=rx*sy-ry*sx
        guard abs(den)>0.000001 else { return nil }
        let qx=Double(c.x-a.x),qy=Double(c.y-a.y),u=(qx*sy-qy*sx)/den,v=(qx*ry-qy*rx)/den
        return u>0 && u<=1 && (0.07...0.93).contains(v) ? v : nil
    }
}

