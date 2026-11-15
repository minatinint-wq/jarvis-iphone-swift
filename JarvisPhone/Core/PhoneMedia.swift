import Foundation

// Monotonic time. A turn owns the microphone window; rotating a Speech request does not.
struct WakeConversationWindow {
    enum Phase: Equatable { case standby, listening(until: TimeInterval), answering }
    private(set) var phase = Phase.standby
    static let silence: TimeInterval = 60
    mutating func listen(at now: TimeInterval) { phase = .listening(until: now + Self.silence) }
    mutating func expire(at now: TimeInterval) {
        if case let .listening(until) = phase, now >= until { phase = .standby }
    }
    mutating func pause(at now: TimeInterval) {
        expire(at: now)
        if case .listening = phase { phase = .answering }
    }
    mutating func resume(at now: TimeInterval) { if phase == .answering { listen(at: now) } }
}

enum PhoneMedia {
    static func pairingCode(_ input:String)->String? {
        var value=input.trimmingCharacters(in:.whitespacesAndNewlines)
        if let c=URLComponents(string:value),let scheme=c.scheme {
            let app=scheme=="jarvisiphone" && c.host=="parear" && c.path.isEmpty
            let site=scheme=="https" && c.host=="jarvis-remoto.minatinint.workers.dev" && c.path=="/login"
            guard app || site,c.port==nil,c.user==nil,c.password==nil,c.query==nil,let fragment=c.fragment,fragment.hasPrefix("pair=") else{return nil}
            value=String(fragment.dropFirst(5))
        }
        return value.range(of:"^(jpc1[.][0-9a-f]{64}|[A-Za-z0-9_-]{32,128})$",options:.regularExpression) != nil ? value : nil
    }
    // Both the existing PC ASR and the Fish voice return little-endian mono PCM16.
    static func wave(_ pcm: Data, rate: UInt32) -> Data {
        var out = Data()
        func tag(_ s: String) { out.append(contentsOf: s.utf8) }
        func le<T: FixedWidthInteger>(_ v: T) { var n = v.littleEndian; withUnsafeBytes(of: &n) { out.append(contentsOf: $0) } }
        tag("RIFF"); le(UInt32(pcm.count + 36)); tag("WAVE"); tag("fmt "); le(UInt32(16))
        le(UInt16(1)); le(UInt16(1)); le(rate); le(rate * 2); le(UInt16(2)); le(UInt16(16))
        tag("data"); le(UInt32(pcm.count)); out.append(pcm); return out
    }
    static func samples(_ wave: Data) -> Data? {
        let b = [UInt8](wave)
        func str(_ i: Int) -> String { String(decoding: b[i..<i+4], as: UTF8.self) }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        guard b.count >= 44, str(0) == "RIFF", str(8) == "WAVE" else { return nil }
        var i = 12, formatOK = false
        while i+8 <= b.count {
            let kind = str(i), n = u32(i+4), start = i+8
            guard n <= b.count-start else { return nil }
            if kind == "fmt ", n >= 16 { formatOK = u16(start)==1 && u16(start+2)==1 && u32(start+4)==16000 && u16(start+14)==16 }
            if kind == "data" { return formatOK && n > 0 && n % 2 == 0 ? Data(b[start..<start+n]) : nil }
            i = start + n + n % 2
        }
        return nil
    }
    static let cameraPrefix = Data("JXLVCAM1".utf8)
    static func cameraPacket(_ jpeg: Data) -> Data? {
        guard (4...120_000).contains(jpeg.count), jpeg.starts(with:[0xff,0xd8,0xff]), jpeg.suffix(2)==Data([0xff,0xd9]) else { return nil }
        return cameraPrefix + jpeg
    }
}
