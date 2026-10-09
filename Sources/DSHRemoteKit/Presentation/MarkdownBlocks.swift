import Foundation

/// One block of a markdown document.
///
/// The harness writes real markdown — headings, bullet lists, tables, quotes, fenced code —
/// and a transcript that only understood fenced code showed all of the rest as literal
/// punctuation. This is the block structure a renderer needs, parsed with no dependency and
/// no HTML.
public enum MarkdownBlock: Sendable, Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A bullet item, with its nesting depth (0 for top level).
    case bullet(depth: Int, text: String)
    /// A numbered item. `marker` is the number as written, because a list that starts at 3
    /// should keep saying 3.
    case numbered(depth: Int, marker: String, text: String)
    case quote(String)
    case rule
    case code(language: String?, text: String)
    case table(headers: [String], rows: [[String]])

    /// The plain text, for search, previews and tests.
    public var plainText: String {
        switch self {
        case .paragraph(let text), .heading(_, let text), .bullet(_, let text),
             .quote(let text):
            text
        case .numbered(_, _, let text):
            text
        case .rule:
            ""
        case .code(_, let text):
            text
        case .table(let headers, let rows):
            ([headers] + rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
        }
    }
}

/// Parses the markdown a model actually emits into renderable blocks.
///
/// Deliberately a **block** parser: inline styling (bold, italic, code spans, links) is left
/// to the platform's inline markdown support, which is good at it. What the platform will not
/// do is decide that `- item` is a list — so that is what this does, and it does only that.
///
/// Two rules shape everything here:
///
/// * **Never lose text.** Anything unrecognised becomes a paragraph, so a construct this
///   build has not learned yet shows up as its own text rather than disappearing.
/// * **An unterminated fence is code.** A streaming reply is in that state constantly, and
///   the alternative is text that flickers in and out as the closing fence arrives.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language: String?
        let lines = text.components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]

            // Fenced code first: inside a fence nothing else is markup.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if code == nil {
                    flushParagraph()
                    code = []
                    let tag = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                } else {
                    blocks.append(.code(language: language, text: (code ?? []).joined(separator: "\n")))
                    code = nil
                    language = nil
                }
                index += 1
                continue
            }
            if code != nil {
                code?.append(line)
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A table needs its delimiter row to be a table at all: `| a |` followed by
            // `|---|` is one, a lone `| a |` is prose that happens to have pipes.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableDelimiter(lines[index + 1]) {
                flushParagraph()
                let headers = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let item = bullet(trimmed, indent: indentation(of: line)) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            if let item = numbered(trimmed, indent: indentation(of: line)) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                // A multi-line quote is one block: the harness quotes several lines at once
                // and a rule between each of them would be noise.
                var quoted: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quoted.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        if let code { blocks.append(.code(language: language, text: code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    // MARK: - The individual rules

    /// `# ` through `###### `, and the `Heading` / `Heading\n===` forms too.
    static func heading(_ line: String) -> MarkdownBlock? {
        var hashes = 0
        for character in line {
            if character == "#" { hashes += 1 } else { break }
        }
        if hashes > 0, hashes <= 6 {
            let rest = line.dropFirst(hashes)
            guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
            return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// `---`, `***`, `___`, and the spaced-out variants.
    static func isRule(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        guard let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// How deep a list item sits: two spaces or one tab per level, which is what models emit.
    static func indentation(of line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 2 } else { break }
        }
        return min(6, spaces / 2)
    }

    static func bullet(_ line: String, indent: Int) -> MarkdownBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return .bullet(depth: indent, text: String(line.dropFirst(marker.count)))
        }
        // `-` on its own is an empty item, which some models emit as a spacer.
        if line == "-" || line == "*" || line == "+" {
            return .bullet(depth: indent, text: "")
        }
        return nil
    }

    static func numbered(_ line: String, indent: Int) -> MarkdownBlock? {
        // `1. ` or `1) `, and the number is kept as written — a list starting at 3 keeps its 3.
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return .numbered(depth: indent, marker: digits, text: String(rest.dropFirst(2)))
    }

    /// `| a | b |` and `|---|---|` split on the pipes that separate cells.
    static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body = String(body.dropFirst()) }
        if body.hasSuffix("|") { body = String(body.dropLast()) }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The `|---|:--:|` row that turns a line of pipes into a table.
    static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let body = part.filter { $0 != ":" }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }
}
