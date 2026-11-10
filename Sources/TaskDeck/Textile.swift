import Foundation

/// Converts Redmine Textile to Markdown, to be shown by MarkdownView.
/// Covers what shows up in issues: headings, emphasis, lists, links, images, quotes,
/// <pre> blocks, tables, macros and issue references (#123).
enum Textile {
    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Fixed patterns from this file.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func sub(_ r: NSRegularExpression, _ s: String, _ template: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func match(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static let headingRx = rx(#"^h([1-6])[<>=()]*\.\s+(.*)$"#)
    private static let bqRx = rx(#"^bq[<>=()]*\.\s+(.*)$"#)
    private static let paraRx = rx(#"^p[<>=()]*\.\s+(.*)$"#)
    private static let footRx = rx(#"^fn(\d+)\.\s+(.*)$"#)
    private static let listRx = rx(#"^([*#]+)\s+(.*)$"#)
    private static let collapseRx = rx(#"^\{\{collapse(?:\(([^)]*)\))?\s*$"#)
    private static let macroLineRx = rx(#"^\{\{[<>]?(toc|child_pages|include)[^}]*\}\}\s*$"#)
    private static let cellModRx = rx(#"^(?:_|[<>=^~]|\\\d+|/\d+|\{[^}]*\}|\([^)]*\))+\.(?:\s|$)"#)
    private static let codeTagRx = rx(#"</?code[^>]*>"#, [.caseInsensitive])

    private static let codeSpanRx = rx(#"(?<![\w@])@(\S(?:[^@\n]*\S)?)@(?![\w@])"#)
    private static let htmlCodeRx = rx(#"<code>(.*?)</code>"#, [.caseInsensitive])
    private static let linkRx = rx(#""([^"\n]+)":((?:https?://|ftp://|mailto:|/)[^\s<]*[^\s<.,;:!?)])"#)
    private static let imageRx = rx(#"!([<>=]?)(https?://[^\s!()]+)(?:\(([^)]*)\))?!"#)
    private static let attachImageRx = rx(#"![<>=]?([^\s!()/]+\.(?:png|jpe?g|gif|webp|svg|bmp))(?:\([^)]*\))?!"#, [.caseInsensitive])
    private static let boldRx = rx(#"(?<![\w*\\])\*(\S(?:[^*\n]*\S)?)\*(?![\w*])"#)
    private static let italicRx = rx(#"(?<![\w_/:.])_(\S(?:[^_\n]*\S)?)_(?![\w_])"#)
    private static let italic2Rx = rx(#"(?<![\w_])__(\S(?:[^\n]*?\S)?)__(?![\w_])"#)
    private static let strikeRx = rx(#"(?<![\w\-/<])-(\S(?:[^\-\n]*\S)?)-(?![\w\->])"#)
    private static let underlineRx = rx(#"(?<![\w+])\+(\S(?:[^+\n]*\S)?)\+(?![\w+])"#)
    private static let citeRx = rx(#"\?\?(\S(?:[^?\n]*\S)?)\?\?"#)
    private static let supRx = rx(#"(?<=\S)\^(\S[^\^\s]*)\^"#)
    private static let spanRx = rx(#"%(?:\{[^}]*\})?(\S(?:[^%\n]*\S)?)%"#)
    private static let wikiLinkRx = rx(#"\[\[(?:[^\]|]*\|)?([^\]]+)\]\]"#)
    private static let issueRefRx = rx(#"(?<![\w&/\[(#])#(\d+)\b(?![\]\)])"#)
    private static let footRefRx = rx(#"(?<=\S)\[(\d+)\]"#)

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Emphasis, links and references in a non-code span.
    private static func spans(_ text: String, issueBase: String) -> String {
        var s = text
        s = sub(imageRx, s, "[🖼 image]($2)")
        s = sub(attachImageRx, s, "🖼 $1")
        s = sub(linkRx, s, "[$1]($2)")
        s = sub(italic2Rx, s, "*$1*")
        s = sub(boldRx, s, "**$1**")
        s = sub(italicRx, s, "*$1*")
        s = sub(strikeRx, s, "~~$1~~")
        s = sub(underlineRx, s, "$1")
        s = sub(citeRx, s, "*$1*")
        s = sub(supRx, s, "$1")
        s = sub(spanRx, s, "$1")
        s = sub(wikiLinkRx, s, "$1")
        s = sub(footRefRx, s, " ($1)")
        if !issueBase.isEmpty {
            s = sub(issueRefRx, s, "[#$1](\(NSRegularExpression.escapedTemplate(for: issueBase))/issues/$1)")
        }
        return s
    }

    /// Converts a line, leaving @code@ content untouched.
    static func inline(_ line: String, issueBase: String) -> String {
        let text = sub(htmlCodeRx, line, "@$1@")
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in codeSpanRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += spans(ns.substring(with: NSRange(location: last, length: m.range.location - last)), issueBase: issueBase)
            out += "`" + ns.substring(with: m.range(at: 1)) + "`"
            last = m.range.location + m.range.length
        }
        out += spans(ns.substring(from: last), issueBase: issueBase)
        return out
    }

    private static func tableRow(_ line: String, issueBase: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|").map { cell -> String in
            var c = cell.trimmingCharacters(in: .whitespaces)
            c = sub(cellModRx, c, "")
            return inline(c.trimmingCharacters(in: .whitespaces), issueBase: issueBase)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    static func toMarkdown(_ source: String, issueBase rawBase: String = "") -> String {
        var issueBase = rawBase
        while issueBase.hasSuffix("/") { issueBase.removeLast() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        var inPre = false
        var inTable = false
        var counters: [Int: Int] = [:]

        for raw in lines {
            var line = raw

            // <pre> blocks become code blocks, content left uninterpreted.
            if inPre {
                if let end = line.range(of: "</pre>", options: .caseInsensitive) {
                    let before = sub(codeTagRx, String(line[..<end.lowerBound]), "")
                    if !before.isEmpty { out.append(decodeEntities(before)) }
                    out.append("```")
                    inPre = false
                    let after = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { out.append(inline(after, issueBase: issueBase)) }
                } else {
                    out.append(decodeEntities(sub(codeTagRx, line, "")))
                }
                continue
            }
            if let start = line.range(of: "<pre>", options: .caseInsensitive) {
                let before = String(line[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { out.append(inline(before, issueBase: issueBase)) }
                out.append("```")
                var rest = String(line[start.upperBound...])
                if let end = rest.range(of: "</pre>", options: .caseInsensitive) {
                    let code = sub(codeTagRx, String(rest[..<end.lowerBound]), "")
                    out.append(decodeEntities(code))
                    out.append("```")
                } else {
                    rest = sub(codeTagRx, rest, "")
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty { out.append(decodeEntities(rest)) }
                    inPre = true
                }
                inTable = false
                counters = [:]
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Tables: Markdown requires a separator row after the first one.
            if trimmed.hasPrefix("|") && trimmed.count > 1 {
                if !inTable, let last = out.last, !last.isEmpty { out.append("") }
                let row = tableRow(trimmed, issueBase: issueBase)
                out.append(row)
                if !inTable {
                    let columns = row.components(separatedBy: " | ").count
                    out.append("|" + String(repeating: " --- |", count: columns))
                    inTable = true
                }
                counters = [:]
                continue
            }
            if inTable {
                inTable = false
                if !trimmed.isEmpty { out.append("") }
            }

            if let g = match(listRx, trimmed) {
                let depth = g[1].count
                let indent = String(repeating: "  ", count: depth - 1)
                counters = counters.filter { $0.key <= depth }
                if g[1].hasSuffix("#") {
                    counters[depth, default: 0] += 1
                    out.append("\(indent)\(counters[depth] ?? 1). \(inline(g[2], issueBase: issueBase))")
                } else {
                    counters[depth] = nil
                    out.append("\(indent)- \(inline(g[2], issueBase: issueBase))")
                }
                continue
            }
            counters = [:]

            if let g = match(headingRx, trimmed) {
                out.append(String(repeating: "#", count: Int(g[1]) ?? 2) + " " + inline(g[2], issueBase: issueBase))
                out.append("")
                continue
            }
            if let g = match(bqRx, trimmed) {
                out.append("> " + inline(g[1], issueBase: issueBase))
                continue
            }
            if let g = match(paraRx, trimmed) {
                out.append(inline(g[1], issueBase: issueBase))
                continue
            }
            if let g = match(footRx, trimmed) {
                out.append("(\(g[1])) " + inline(g[2], issueBase: issueBase))
                continue
            }
            if match(macroLineRx, trimmed) != nil { continue }
            if let g = match(collapseRx, trimmed) {
                out.append(g[1].isEmpty ? "" : "**\(g[1])**")
                continue
            }
            if trimmed == "}}" { continue }
            if trimmed.hasPrefix(">") {
                // E-mail style quote: Markdown already understands it.
                var body = trimmed
                var level = ""
                while body.hasPrefix(">") { level += ">"; body.removeFirst(); body = body.trimmingCharacters(in: .whitespaces) }
                out.append("\(level) \(inline(body, issueBase: issueBase))")
                continue
            }
            if trimmed == "---" || trimmed == "----" {
                out.append("")
                out.append("---")
                continue
            }
            line = inline(line, issueBase: issueBase)
            out.append(line)
        }
        if inPre { out.append("```") }
        return out.joined(separator: "\n")
    }
}
