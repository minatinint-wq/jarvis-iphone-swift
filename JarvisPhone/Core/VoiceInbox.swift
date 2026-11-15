import Foundation

// This inbox is session-local. A notification is spoken literally, never parsed as an instruction.
struct VoiceInbox {
    private var entries: [(String,Date)] = []
    private var seen: [String:Date] = [:]
    mutating func insert(_ value:String, now:Date) -> Bool {
        let text = String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ").prefix(700))
        seen = seen.filter { now.timeIntervalSince($0.value) < 12 }
        guard !text.isEmpty, !text.contains("JARVIS_COMANDO"), seen[text] == nil else { return false }
        entries.removeAll { now.timeIntervalSince($0.1) >= 90 }
        if entries.count >= 12 { entries.removeFirst() }
        if seen.count >= 64, let key = seen.min(by: { $0.value < $1.value })?.key { seen.removeValue(forKey:key) }
        entries.append((text,now)); seen[text] = now
        return true
    }
    mutating func next(now:Date) -> String? {
        entries.removeAll { now.timeIntervalSince($0.1) >= 90 }
        return entries.isEmpty ? nil : entries.removeFirst().0
    }
}
