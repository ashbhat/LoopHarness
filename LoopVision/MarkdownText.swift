//
//  MarkdownText.swift
//  LoopVision
//
//  Renders the assistant's raw markdown as formatted text. Inline marks
//  (bold/italic/links/code) come from SwiftUI's native markdown parser
//  via `.inlineOnlyPreservingWhitespace`; block-level GFM tables are
//  parsed by the shared MarkdownSegmenter and laid out as SwiftUI
//  `Grid`s so they render as real tables instead of raw pipe syntax.
//  Falls back to the raw string if inline parsing fails so text is
//  never lost.
//

import SwiftUI

struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownSegmenter.segments(from: markdown).enumerated()),
                    id: \.offset) { _, segment in
                switch segment {
                case .text(let prose):
                    Text(Self.attributed(prose))
                case .table(let table):
                    MarkdownTableView(table: table)
                case .codeBlock(let block):
                    MarkdownCodeBlockView(block: block)
                }
            }
        }
    }

    static func attributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: raw, options: options) {
            return parsed
        }
        return AttributedString(raw)
    }
}

/// A SwiftUI Grid laid out from a parsed `MarkdownTable`. Header row is
/// bold over a tinted material; body rows alternate background fill.
/// Per-column horizontal alignment comes from the GFM separator row.
private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .topLeading,
             horizontalSpacing: 0,
             verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { i, cell in
                    cellView(text: cell,
                             alignment: alignment(at: i),
                             isHeader: true)
                }
            }
            .background(Color.secondary.opacity(0.18))

            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                Divider()
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, cell in
                        cellView(text: cell,
                                 alignment: alignment(at: i),
                                 isHeader: false)
                    }
                }
                .background(rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : Color.secondary.opacity(0.06))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Without an explicit max-width frame the Grid hugs its column
        // content, so a grid of short cells collapses to a thumbnail
        // inside the bubble. Letting it stretch gives the table room to
        // breathe and pushes the bubble to use available space.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignment(at index: Int) -> MarkdownColumnAlignment {
        index < table.alignments.count ? table.alignments[index] : .left
    }

    @ViewBuilder
    private func cellView(text: String,
                          alignment: MarkdownColumnAlignment,
                          isHeader: Bool) -> some View {
        Text(MarkdownText.attributed(text))
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(swiftUIAlignment(alignment))
            .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func swiftUIAlignment(_ a: MarkdownColumnAlignment) -> TextAlignment {
        switch a {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }

    private func frameAlignment(_ a: MarkdownColumnAlignment) -> Alignment {
        switch a {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }
}

/// Renders a fenced code block as monospaced text inside a rounded,
/// tinted container with an optional language label.
private struct MarkdownCodeBlockView: View {
    let block: MarkdownCodeBlock

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(block.code)
                .font(.system(.subheadline, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let lang = block.language, !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.trailing, 10)
            }
        }
        .background(Color.secondary.opacity(0.12),
                     in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Previews

#Preview("Markdown with code block") {
    MarkdownText(markdown: """
    Here's a Swift example:

    ```swift
    struct Greeting {
        let name: String
        var message: String {
            "Hello, \\(name)!"
        }
    }
    ```

    And some `inline code` too.
    """)
    .padding()
}
