import Foundation

/// A few short byte strings to look for in one pass over a transcript line, to tell
/// whether the line is worth parsing at all.
///
/// Every marker contains an underscore, which is rare in what fills most of a transcript
/// (base64 and prose), so the scan is a `memchr` for that byte and a comparison around
/// each hit. A plain `memmem` per marker was most of the cost of reading a Codex history.
struct LineMarkers {

    private static let anchor = UInt8(ascii: "_")
    private let markers: [(bytes: [UInt8], anchorAt: Int)]

    init(_ markers: [String]) {
        self.markers = markers.map { marker in
            let bytes = Array(marker.utf8)
            guard let anchorAt = bytes.firstIndex(of: Self.anchor) else {
                preconditionFailure("marker \(marker) has no underscore to anchor on")
            }
            return (bytes, anchorAt)
        }
    }

    func match(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        var offset = 0
        while offset < line.count,
              let hit = memchr(base + offset, Int32(Self.anchor), line.count - offset) {
            let at = base.distance(to: UnsafeRawPointer(hit))
            for marker in markers {
                let start = at - marker.anchorAt
                if start >= 0, start + marker.bytes.count <= line.count,
                   memcmp(base + start, marker.bytes, marker.bytes.count) == 0 {
                    return true
                }
            }
            offset = at + 1
        }
        return false
    }
}
