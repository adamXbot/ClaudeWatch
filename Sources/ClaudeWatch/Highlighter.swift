import SwiftUI

enum Highlighter {
    /// `text` as an AttributedString with every case-insensitive occurrence of `query`
    /// tinted in the system accent colour. Font/size are left untouched so each call
    /// site keeps its own typography.
    static func attributed(_ text: String, query: String, accent: Color = .accentColor) -> AttributedString {
        var attr = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attr }

        var searchStart = text.startIndex
        while let r = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            if let lo = AttributedString.Index(r.lowerBound, within: attr),
               let hi = AttributedString.Index(r.upperBound, within: attr) {
                attr[lo..<hi].foregroundColor = accent
                attr[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = r.upperBound
            if searchStart == text.endIndex { break }
        }
        return attr
    }
}
