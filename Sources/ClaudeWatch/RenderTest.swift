import Foundation
import ClaudeWatchCore

/// `ClaudeWatch --render-test [toolId]` renders one event's thread to HTML and prints
/// structural assertions, so the browser view can be verified without a GUI.
enum RenderTest {
    static func run() {
        let scanner = EventScanner()
        let events = scanner.fullScan().sorted { $0.timestamp > $1.timestamp }

        let requested = CommandLine.arguments.first { $0.hasPrefix("toolu_") }
        let event = requested.flatMap { id in events.first { $0.id == id } } ?? events.first

        guard let event else { print("no events found"); exit(1) }
        guard let url = TranscriptHTMLRenderer.renderToTempFile(
            transcriptPath: event.transcriptPath, highlightId: event.id
        ) else { print("render failed"); exit(1) }

        let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        print("event:   \(event.kind.label) — \(event.primary.prefix(60))")
        print("file:    \(url.path)")
        print("bytes:   \(html.utf8.count)")
        print("doctype: \(html.hasPrefix("<!doctype html>"))")
        print("has id:  \(html.contains("id=\"\(event.id)\""))")
        print("target:  \(html.contains("class=\"tool target\""))")
        print("scripted scroll: \(html.contains(".target"))")
        print("turns:   \(html.components(separatedBy: "<section").count - 1)")
        print("tools:   \(html.components(separatedBy: "class=\"tool").count - 1)")
        exit(0)
    }
}
