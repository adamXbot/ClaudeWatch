import Foundation
import ClaudeWatchCore

/// Headless verification / inspection mode: `ClaudeWatch --dump` parses real transcripts
/// and prints the latest events as text. Lets the parsing + discovery pipeline be tested
/// end-to-end without launching the menu-bar UI.
enum DumpRunner {
    static func run() {
        let scanner = EventScanner()
        let events = scanner.fullScan().sorted { $0.timestamp > $1.timestamp }
        let limit = 40

        FileHandle.standardError.write(Data(
            "ClaudeWatch --dump: \(events.count) command events from \(scanner.root.path)\n\n".utf8
        ))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for event in events.prefix(limit) {
            let sub = event.isSubagent ? " [subagent]" : ""
            let primary = event.primary.replacingOccurrences(of: "\n", with: " ⏎ ")
            var lines = [
                "\(formatter.string(from: event.timestamp))  \(event.kind.label.uppercased())\(sub)  (\(event.projectName))",
                "   \(String(primary.prefix(160)))",
            ]
            if let s = event.secondary, !s.isEmpty {
                lines.append("   ↳ \(String(s.prefix(120)))")
            }
            lines.append("   session \(event.sessionId)  ·  \((event.transcriptPath as NSString).lastPathComponent)")
            print(lines.joined(separator: "\n"))
            print("")
        }
        exit(0)
    }
}
