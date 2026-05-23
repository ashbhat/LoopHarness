//
//  MarkdownTableParser.swift
//  intel
//
//  Splits a markdown string into prose and GFM-table segments so each
//  client (iOS UIStackView, macOS NSGridView, visionOS SwiftUI Grid) can
//  render the tables as real grids instead of leaving them as raw pipe
//  syntax in the bubble. Pure Foundation — shared across all three
//  targets via the synchronized intel/ group.
//

import Foundation

public enum MarkdownColumnAlignment {
    case left, center, right
}

public struct MarkdownTable: Equatable {
    public let headers: [String]
    public let alignments: [MarkdownColumnAlignment]
    public let rows: [[String]]

    public var columnCount: Int { headers.count }
}

public enum MarkdownSegment: Equatable {
    case text(String)
    case table(MarkdownTable)
}

public enum MarkdownSegmenter {
    /// Quick check — true if the text contains anything that looks like a
    /// GFM table. Lets callers stay on their existing single-text-view
    /// fast path when there's no table to render.
    public static func containsTable(in markdown: String) -> Bool {
        for segment in segments(from: markdown) {
            if case .table = segment { return true }
        }
        return false
    }

    /// Walks the markdown line-by-line, accumulating prose into text
    /// segments and emitting a table segment for each header + separator
    /// + body block. Lines that don't form a valid table flow through as
    /// plain text untouched.
    public static func segments(from markdown: String) -> [MarkdownSegment] {
        let lines = markdown.components(separatedBy: "\n")
        var result: [MarkdownSegment] = []
        var textBuffer: [String] = []

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            // Trim leading + trailing empty lines that get sandwiched
            // between prose and a table — they're already visually
            // separated by the table block, so we don't want extra blank
            // lines hanging off the prose segments.
            while let first = textBuffer.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                textBuffer.removeFirst()
            }
            while let last = textBuffer.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                textBuffer.removeLast()
            }
            if !textBuffer.isEmpty {
                result.append(.text(textBuffer.joined(separator: "\n")))
            }
            textBuffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            // Pipes inside a fenced code block (```…```) are literal — the
            // model is asking us to render the source, not the table. Walk
            // the whole fence into the text buffer so the parser never
            // treats lines inside it as a table candidate.
            if isFenceLine(lines[i]) {
                textBuffer.append(lines[i])
                i += 1
                while i < lines.count {
                    textBuffer.append(lines[i])
                    let wasFence = isFenceLine(lines[i])
                    i += 1
                    if wasFence { break }
                }
                continue
            }

            if let (table, consumed) = parseTable(startingAt: i, in: lines) {
                flushText()
                result.append(.table(table))
                i += consumed
            } else {
                textBuffer.append(lines[i])
                i += 1
            }
        }
        flushText()
        return result
    }

    /// True for a line whose first non-whitespace character starts a
    /// triple-backtick or triple-tilde fenced code block.
    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: - Table parsing

    private static func parseTable(startingAt index: Int,
                                   in lines: [String]) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let separatorLine = lines[index + 1]

        guard let headers = splitRow(headerLine), !headers.isEmpty else { return nil }
        guard let alignments = parseSeparator(separatorLine,
                                              expectedColumns: headers.count) else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let cells = splitRow(line) else { break }
            // Pad short rows / truncate long ones so the grid renders
            // cleanly even when the model emits a slightly malformed row.
            var normalized = cells
            if normalized.count < headers.count {
                normalized.append(contentsOf:
                    Array(repeating: "", count: headers.count - normalized.count))
            } else if normalized.count > headers.count {
                normalized = Array(normalized.prefix(headers.count))
            }
            rows.append(normalized)
            cursor += 1
        }

        let table = MarkdownTable(headers: headers, alignments: alignments, rows: rows)
        return (table, cursor - index)
    }

    /// Splits a row on unescaped `|`. Leading and trailing pipes are
    /// optional. Returns nil for lines without any pipe so the caller
    /// can fall back to treating them as prose.
    private static func splitRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var content = trimmed
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") && !content.hasSuffix("\\|") {
            content.removeLast()
        }

        // Substitute escaped pipes so a plain split on "|" works, then
        // restore them inside each cell.
        let placeholder = "\u{0001}"
        let escaped = content.replacingOccurrences(of: "\\|", with: placeholder)
        let parts = escaped.components(separatedBy: "|").map { part -> String in
            part.replacingOccurrences(of: placeholder, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
        return parts
    }

    /// A separator row looks like `|---|:---:|---:|`. Each cell must
    /// match `:?-+:?` — at least one dash, with optional colons marking
    /// alignment. Returns the per-column alignments, or nil if the row
    /// isn't a separator (which means we don't have a table after all).
    private static func parseSeparator(_ line: String,
                                       expectedColumns: Int) -> [MarkdownColumnAlignment]? {
        guard let cells = splitRow(line), cells.count == expectedColumns else { return nil }
        var alignments: [MarkdownColumnAlignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil else {
                return nil
            }
            let leftColon = trimmed.hasPrefix(":")
            let rightColon = trimmed.hasSuffix(":")
            if leftColon && rightColon {
                alignments.append(.center)
            } else if rightColon {
                alignments.append(.right)
            } else {
                alignments.append(.left)
            }
        }
        return alignments
    }
}
