import Foundation
import Testing

@testable import DSHRemoteKit

/// The markdown block parser, against the shapes a model actually writes.
///
/// The transcript used to render inline styling and fenced code and nothing else, so every
/// heading, list and table arrived as literal punctuation. These cases are that complaint,
/// written down.
@Suite("Markdown blocks")
struct MarkdownBlocksTests {

    @Test("a heading is a heading, at every level")
    func headings() {
        #expect(MarkdownBlocks.parse("# Title") == [.heading(level: 1, text: "Title")])
        #expect(MarkdownBlocks.parse("### Deeper") == [.heading(level: 3, text: "Deeper")])
        // `#hashtag` and `#` alone are not headings — the first needs its space.
        #expect(MarkdownBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlocks.parse("####### seven") == [.paragraph("####### seven")])
    }

    @Test("bullets nest by indentation, and keep their inline styling for the renderer")
    func bullets() {
        let blocks = MarkdownBlocks.parse("""
        - top level
          - nested one
            - nested two
        * star bullet
        + plus bullet
        """)
        #expect(blocks == [
            .bullet(depth: 0, text: "top level"),
            .bullet(depth: 1, text: "nested one"),
            .bullet(depth: 2, text: "nested two"),
            .bullet(depth: 0, text: "star bullet"),
            .bullet(depth: 0, text: "plus bullet"),
        ])
    }

    @Test("a numbered list keeps the number it was written with")
    func numbered() {
        let blocks = MarkdownBlocks.parse("""
        3. third
        4. fourth
        1) paren form
        """)
        #expect(blocks == [
            .numbered(depth: 0, marker: "3", text: "third"),
            .numbered(depth: 0, marker: "4", text: "fourth"),
            .numbered(depth: 0, marker: "1", text: "paren form"),
        ])
        // A four-digit marker is still a marker, because that is what CommonMark says and
        // what the harness's own renderer does. The trade is deliberate: a "2026. …" line
        // would show as a one-item list, and the alternative — requiring one or two digits —
        // silently swallows any real list that reaches item 100. Written down here because it
        // is the one case where the parser is knowingly stricter than the eye.
        #expect(MarkdownBlocks.parse("2026. was a good year")
            == [.numbered(depth: 0, marker: "2026", text: "was a good year")])
        // A version is not a list: `.2.3` is not `. `.
        #expect(MarkdownBlocks.parse("1.2.3 release notes")
            == [.paragraph("1.2.3 release notes")])
    }

    @Test("a table needs its delimiter row; pipes alone are prose")
    func tables() {
        let blocks = MarkdownBlocks.parse("""
        | Setting | Value |
        | --- | ---: |
        | host | 10.1.0.138 |
        | port | 3443 |
        """)
        #expect(blocks == [.table(
            headers: ["Setting", "Value"],
            rows: [["host", "10.1.0.138"], ["port", "3443"]]
        )])

        #expect(MarkdownBlocks.parse("| not a table |") == [.paragraph("| not a table |")])
    }

    @Test("a quote is one block, however many lines it covers")
    func quotes() {
        let blocks = MarkdownBlocks.parse("""
        > first line
        > second line

        after
        """)
        #expect(blocks == [.quote("first line\nsecond line"), .paragraph("after")])
    }

    @Test("rules, and the three spellings of them")
    func rules() {
        #expect(MarkdownBlocks.parse("---") == [.rule])
        #expect(MarkdownBlocks.parse("***") == [.rule])
        #expect(MarkdownBlocks.parse("_ _ _") == [.rule])
        // Two dashes is a paragraph, not a rule.
        #expect(MarkdownBlocks.parse("--") == [.paragraph("--")])
    }

    @Test("fenced code survives verbatim, markers and all, and an open fence is still code")
    func code() {
        let blocks = MarkdownBlocks.parse("""
        before

        ```swift
        let x = 1  // # not a heading
        - not a bullet
        ```

        after
        """)
        #expect(blocks == [
            .paragraph("before"),
            .code(language: "swift", text: "let x = 1  // # not a heading\n- not a bullet"),
            .paragraph("after"),
        ])

        // A streaming reply is mid-fence constantly; the text must not vanish or leak out
        // as prose until the closing fence lands.
        #expect(MarkdownBlocks.parse("```\nlet y = 2") == [.code(language: nil, text: "let y = 2")])
    }

    @Test("a realistic reply comes apart into the blocks a renderer needs")
    func aRealisticReply() {
        // The shape the harness actually writes: a heading, a list with bold leads, a table,
        // a code block and a closing rule.
        let reply = """
        ## What I changed

        - **Archived sessions** are filtered out of the browse mapping.
        - The drawer button toggles.

        | File | Change |
        | --- | --- |
        | `BrowsePresentation.swift` | filter |

        ```swift
        let archived = Set(snapshot.archivedSessionIds)
        ```

        ---
        """
        let blocks = MarkdownBlocks.parse(reply)
        #expect(blocks.count == 6)
        #expect(blocks[0] == .heading(level: 2, text: "What I changed"))
        #expect(blocks[1] == .bullet(depth: 0, text: "**Archived sessions** are filtered out of the browse mapping."))
        #expect(blocks[2] == .bullet(depth: 0, text: "The drawer button toggles."))
        #expect(blocks[3] == .table(
            headers: ["File", "Change"],
            rows: [["`BrowsePresentation.swift`", "filter"]]
        ))
        #expect(blocks[4] == .code(language: "swift", text: "let archived = Set(snapshot.archivedSessionIds)"))
        #expect(blocks[5] == .rule)
        // Nothing was dropped on the floor: the plain text still contains every phrase.
        let plain = blocks.map(\.plainText).joined(separator: " ")
        #expect(plain.contains("Archived sessions"))
        #expect(plain.contains("BrowsePresentation.swift"))
    }

    @Test("a construct this build has not learned yet shows up as text, not as nothing")
    func unknownSyntaxSurvives() {
        // A footnote, a definition list and an HTML tag: none are modelled, all must survive.
        for input in ["[^1]: a note", "term\n: definition", "<details>hi</details>"] {
            let plain = MarkdownBlocks.parse(input).map(\.plainText).joined(separator: "\n")
            #expect(plain.contains(input.components(separatedBy: "\n").last ?? input))
        }
    }
}
