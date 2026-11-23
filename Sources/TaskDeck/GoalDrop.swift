import Foundation
import UniformTypeIdentifiers

/// Turns what is dropped on a goal into goal items: links, files, and messages dragged from Mail.
///
/// A message dragged from Mail carries a `message:` link and its subject, which is all a goal
/// needs to open it again. Mail also promises an .eml copy; its headers add the sender, and are
/// the way in when a drag has no link (an .eml file from Finder). Only those headers are kept;
/// the file itself is not.
enum GoalDrop {
    /// The types a goal's drop area accepts. `.item` too, so a drop that fits none of the others
    /// still arrives and can be reported instead of silently refused.
    static let types: [UTType] = [mailMessage, .emailMessage, .fileURL, .url, .plainText, .item]

    /// What Mail calls the file it promises for a dragged message.
    static let mailMessage = UTType("com.apple.mail.email") ?? UTType(importedAs: "com.apple.mail.email")

    enum Failure: LocalizedError {
        case unreadable([String])

        var errorDescription: String? {
            switch self {
            case .unreadable(let types):
                return "That could not be added. It offered: \(types.joined(separator: ", "))."
            }
        }
    }

    /// Reads every dropped item. Items that cannot be read are reported together in one failure,
    /// after the readable ones are returned.
    static func items(from providers: [NSItemProvider]) async -> (items: [GoalItem], failure: Failure?) {
        var items: [GoalItem] = []
        var unreadable: [String] = []
        for provider in providers {
            // Mail adds a second item that only describes the promised file; the first already
            // stands for the message.
            if !items.isEmpty, provider.registeredTypeIdentifiers.allSatisfy(isPromiseDetail) { continue }
            if let item = await item(from: provider) {
                items.append(item)
            } else {
                unreadable.append(contentsOf: provider.registeredTypeIdentifiers)
            }
        }
        return (items, unreadable.isEmpty ? nil : .unreadable(Array(Set(unreadable)).sorted()))
    }

    private static func item(from provider: NSItemProvider) async -> GoalItem? {
        let types = provider.registeredTypeIdentifiers
        NSLog("TaskDeck goal drop: %@", types.joined(separator: ", "))
        // Mail's own link first: it also offers a plain-text copy, which would land as a note.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider, UTType.url), url.scheme?.lowercased() == "message" {
            var item = GoalItem.from(url)
            if let subject = await loadText(provider, type: "public.url-name"), !subject.isEmpty { item.title = subject }
            // The sender is a nicety: a promise Mail is slow to keep is not waited for.
            if let type = types.first(where: isMessage), let copy = await message(from: provider, type: type, timeout: 3) {
                item.text = copy.text
                if item.title == "Mail message" { item.title = copy.title }
            }
            return item
        }
        if let type = types.first(where: isMessage), let item = await message(from: provider, type: type, timeout: 10) {
            return item
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, UTType.fileURL) {
            return url.pathExtension.lowercased() == "eml" ? (message(at: url) ?? GoalItem.from(url)) : GoalItem.from(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await loadURL(provider, UTType.url) {
            return GoalItem.from(url)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider, type: UTType.plainText.identifier) {
            return GoalItem.from(text)
        }
        return nil
    }

    private static func isPromiseDetail(_ identifier: String) -> Bool {
        identifier.hasPrefix("com.apple.pasteboard.") || identifier == "com.apple.NSFilePromiseItemMetaData"
            || isMessage(identifier)
    }

    private static func isMessage(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return identifier == mailMessage.identifier }
        return type == mailMessage || type.conforms(to: .emailMessage)
    }

    // MARK: Loading

    /// Waits for a loader's callback, or gives up after `timeout` seconds. A callback that never
    /// comes would otherwise hold the whole drop, and nothing would be added.
    private static func load<T: Sendable>(timeout: Double,
                                          _ start: @escaping (@escaping @Sendable (T?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { done.resume(returning: nil) }
            }
            start { value in
                if once.claim() { done.resume(returning: value) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    private static func message(from provider: NSItemProvider, type: String, timeout: Double) async -> GoalItem? {
        await load(timeout: timeout) { done in
            // The file only exists until this handler returns: it is read here, not later.
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                done(url.flatMap(message(at:)))
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        await load(timeout: 5) { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                done(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider, type: String) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
        return await load(timeout: 5) { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                done(data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: Messages

    /// A goal item for the message saved at `url`, from its headers; nil when it has no Message-ID
    /// to open it by.
    static func message(at url: URL) -> GoalItem? {
        // The headers are at the top; the rest may be megabytes of attachments.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let headers = headers(in: text)
        guard let id = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")),
              !id.isEmpty else { return nil }
        let link = "message://" + "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_")))!
        let subject = headers["subject"].map(decodeWords) ?? ""
        let from = headers["from"].map(decodeWords) ?? ""
        return GoalItem(kind: .mail, title: subject.isEmpty ? "(no subject)" : subject, url: link,
                        text: from.isEmpty ? "" : "From \(from)")
    }

    /// The header block, names lower-cased. Folded lines (starting with a space or tab) continue
    /// the header above them.
    static func headers(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var last: String?
        for line in text.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                if let last { result[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // The first one counts: forwarded headers further down are not this message's.
            if result[name] == nil {
                result[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = name
            } else {
                last = nil
            }
        }
        return result
    }

    /// Decodes RFC 2047 encoded words ("=?UTF-8?B?...?="), which is how headers carry anything
    /// but plain ASCII.
    static func decodeWords(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        // Spaces between two encoded words are not part of the text.
        let joined = value.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        var output = ""
        var cursor = joined.startIndex
        for match in regex.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)) {
            guard let whole = Range(match.range, in: joined), let charsetRange = Range(match.range(at: 1), in: joined),
                  let modeRange = Range(match.range(at: 2), in: joined),
                  let bodyRange = Range(match.range(at: 3), in: joined) else { continue }
            output += joined[cursor..<whole.lowerBound]
            let charset = String(joined[charsetRange]).lowercased()
            let body = String(joined[bodyRange])
            let bytes: Data?
            if joined[modeRange].lowercased() == "b" {
                var padded = body
                while padded.count % 4 != 0 { padded += "=" }
                bytes = Data(base64Encoded: padded)
            } else {
                bytes = quotedPrintable(body)
            }
            let encoding: String.Encoding = charset.contains("8859-1") || charset.contains("latin1") ? .isoLatin1
                : charset.contains("1252") ? .windowsCP1252 : .utf8
            output += bytes.flatMap { String(data: $0, encoding: encoding) } ?? String(joined[whole])
            cursor = whole.upperBound
        }
        output += joined[cursor...]
        return output
    }

    private static func quotedPrintable(_ text: String) -> Data? {
        var data = Data()
        var bytes = Array(text.utf8)[...]
        while let byte = bytes.popFirst() {
            switch byte {
            case UInt8(ascii: "_"): data.append(0x20)
            case UInt8(ascii: "="):
                guard bytes.count >= 2, let value = UInt8(String(decoding: bytes.prefix(2), as: UTF8.self), radix: 16) else {
                    return nil
                }
                data.append(value)
                bytes = bytes.dropFirst(2)
            default: data.append(byte)
            }
        }
        return data
    }
}
