import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum Lyrics {
    static func parse(_ text: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let offsetRegex = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let whole = text as NSString
        var offset = 0.0
        if let match = offsetRegex?.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)),
           let millis = Double(whole.substring(with: match.range(at: 1))) { offset = millis / 1000 }
        var result: [(Double, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let source = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: source.length))
            guard let last = matches.last else { continue }
            let content = source.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            for match in matches {
                let minutes = Double(source.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(source.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Double("0." + source.substring(with: fractionRange)) ?? 0)
                result.append((max(0, minutes * 60 + seconds + fraction + offset), content))
            }
        }
        return result.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
