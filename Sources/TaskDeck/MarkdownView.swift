import SwiftUI

// Simple block-level Markdown renderer (headings, lists, code, quotes, tables).
// SwiftUI only understands inline Markdown; blocks are split here.

enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case code(String)
    case quote(String)
    case list([MDItem])
    case table([[String]])
    case rule
}

struct MDItem {
    let indent: Int
    let marker: String
    var text: String
}

enum MarkdownParser {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Fixed patterns from this file.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let headingRx = regex(#"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let listRx = regex(#"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let ruleRx = regex(#"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)
    private static let tableSepRx = regex(#"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#)
    private static let commentRx = regex(#"<!--[\s\S]*?-->"#)
    private static let imageRx = regex(#"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let htmlImgRx = regex(#"<img[^>]*?src=["']([^"']+)["'][^>]*>"#)
    private static let brRx = regex(#"<br\s*/?>"#)
    private static let tagRx = regex(#"</?(details|summary|p|div|span|sub|sup|kbd|picture|source)[^>]*>"#)

    private static func groups(_ rx: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func replace(_ rx: NSRegularExpression, _ s: String, _ template: String) -> String {
        rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ raw: String) -> [MDBlock] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(commentRx, text, "")
        text = replace(imageRx, text, "[🖼 $1]($2)")
        text = replace(htmlImgRx, text, "[🖼 image]($1)")
        text = replace(brRx, text, "\n")
        text = replace(tagRx, text, "")

        let lines = text.components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var para: [String] = []
        var items: [MDItem] = []

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
        }
        func flush() { flushPara(); flushList() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let g = groups(headingRx, line) {
                flush()
                blocks.append(.heading(g[1].count, g[2]))
                i += 1
                continue
            }
            if groups(ruleRx, line) != nil {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    quote.append(q.hasPrefix(" ") ? String(q.dropFirst()) : q)
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if let g = groups(listRx, line) {
                flushPara()
                let indent = g[1].replacingOccurrences(of: "\t", with: "    ").count / 2
                var marker = ["-", "*", "+"].contains(g[2]) ? "•" : g[2].replacingOccurrences(of: ")", with: ".")
                var body = g[3]
                if body.hasPrefix("[ ] ") { marker = "☐"; body = String(body.dropFirst(4)) }
                else if body.lowercased().hasPrefix("[x] ") { marker = "☑"; body = String(body.dropFirst(4)) }
                items.append(MDItem(indent: indent, marker: marker, text: body))
                i += 1
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"),
               groups(tableSepRx, lines[i + 1]) != nil {
                flush()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }
            // Continuation line of a list item.
            if !items.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                items[items.count - 1].text += "\n" + trimmed
                i += 1
                continue
            }
            flushList()
            para.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(level <= 1 ? .title2.weight(.bold)
                      : level == 2 ? .title3.weight(.semibold)
                      : level == 3 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownParser.inline(cell))
                                    .fontWeight(r == 0 ? .semibold : .regular)
                                    .textSelection(.enabled)
                            }
                        }
                        if r == 0 { Divider() }
                    }
                }
                .padding(10)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }
}

/// Converts Atlassian Document Format (Jira Cloud, API v3) to Markdown.
enum ADF {
    static func markdown(_ doc: [String: Any]) -> String {
        block(doc, indent: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func children(_ node: [String: Any]) -> [[String: Any]] {
        (node["content"] as? [[String: Any]]) ?? []
    }

    private static func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { node -> String in
            let attrs = (node["attrs"] as? [String: Any]) ?? [:]
            switch node["type"] as? String ?? "" {
            case "text":
                var t = (node["text"] as? String) ?? ""
                let marks = (node["marks"] as? [[String: Any]]) ?? []
                let types = marks.compactMap { $0["type"] as? String }
                // Markdown markers must touch the text.
                let lead = String(t.prefix { $0 == " " })
                let trail = String(t.reversed().prefix { $0 == " " })
                t = t.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return lead.isEmpty ? trail : lead }
                if types.contains("code") { t = "`\(t)`" } else {
                    if types.contains("strong") { t = "**\(t)**" }
                    if types.contains("em") { t = "*\(t)*" }
                    if types.contains("strike") { t = "~~\(t)~~" }
                }
                if let link = marks.first(where: { ($0["type"] as? String) == "link" }),
                   let href = (link["attrs"] as? [String: Any])?["href"] as? String {
                    t = "[\(t)](\(href))"
                }
                return lead + t + trail
            case "hardBreak": return "\n"
            case "mention": return (attrs["text"] as? String) ?? "@user"
            case "emoji": return (attrs["text"] as? String) ?? (attrs["shortName"] as? String) ?? ""
            case "inlineCard", "blockCard", "embedCard":
                let url = (attrs["url"] as? String) ?? ""
                return url.isEmpty ? "" : "[\(url)](\(url))"
            case "status": return "`\((attrs["text"] as? String) ?? "")`"
            case "date":
                if let ts = attrs["timestamp"] as? String, let ms = Double(ts) {
                    return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
                }
                return ""
            case "media", "mediaInline": return "🖼 *(attachment)*"
            default: return inline(children(node))
            }
        }.joined()
    }

    private static func listItem(_ node: [String: Any], marker: String, indent: String) -> String {
        var lines: [String] = []
        var first = true
        for child in children(node) {
            let type = child["type"] as? String ?? ""
            if ["bulletList", "orderedList", "taskList"].contains(type) {
                lines.append(block(child, indent: indent + "  "))
            } else {
                let body = type == "paragraph" ? inline(children(child)) : block(child, indent: "")
                let flat = body.replacingOccurrences(of: "\n", with: "\n\(indent)  ")
                lines.append(first ? "\(indent)\(marker) \(flat)" : "\(indent)  \(flat)")
                first = false
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func block(_ node: [String: Any], indent: String) -> String {
        let attrs = (node["attrs"] as? [String: Any]) ?? [:]
        let kids = children(node)
        switch node["type"] as? String ?? "" {
        case "paragraph":
            return inline(kids)
        case "heading":
            let level = (attrs["level"] as? Int) ?? 2
            return String(repeating: "#", count: max(1, min(6, level))) + " " + inline(kids)
        case "bulletList":
            return kids.map { listItem($0, marker: "-", indent: indent) }.joined(separator: "\n")
        case "orderedList":
            let start = (attrs["order"] as? Int) ?? 1
            return kids.enumerated().map { listItem($1, marker: "\($0 + start).", indent: indent) }.joined(separator: "\n")
        case "taskList":
            return kids.map { item -> String in
                if (item["type"] as? String) == "taskList" { return block(item, indent: indent + "  ") }
                let done = ((item["attrs"] as? [String: Any])?["state"] as? String) == "DONE"
                return "\(indent)- [\(done ? "x" : " ")] \(inline(children(item)))"
            }.joined(separator: "\n")
        case "codeBlock":
            let code = kids.compactMap { $0["text"] as? String }.joined()
            return "```\n\(code)\n```"
        case "blockquote", "panel":
            return kids.map { block($0, indent: "") }.joined(separator: "\n\n")
                .components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        case "rule":
            return "---"
        case "table":
            var rows: [String] = []
            for (i, row) in kids.enumerated() {
                let cells = children(row).map { cell in
                    children(cell).map { block($0, indent: "") }.joined(separator: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "|", with: "\\|")
                }
                rows.append("| " + cells.joined(separator: " | ") + " |")
                if i == 0 { rows.append("|" + cells.map { _ in " --- |" }.joined()) }
            }
            return rows.joined(separator: "\n")
        case "mediaSingle", "mediaGroup":
            return "🖼 *(attachment)*"
        case "expand", "nestedExpand":
            let title = (attrs["title"] as? String) ?? ""
            let body = kids.map { block($0, indent: indent) }.joined(separator: "\n\n")
            return title.isEmpty ? body : "**\(title)**\n\n\(body)"
        default:
            if kids.isEmpty { return inline([node]) }
            return kids.map { block($0, indent: indent) }.joined(separator: "\n\n")
        }
    }
}
