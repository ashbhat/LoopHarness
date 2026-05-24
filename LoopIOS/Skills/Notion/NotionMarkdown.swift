//
//  NotionMarkdown.swift
//  Loop
//
//  Tiny markdown ↔ Notion blocks bridge. The Notion API doesn't accept
//  markdown — it wants typed blocks with rich-text runs. This file is the
//  smallest mapper that round-trips Loop's typical Notion usage: headings,
//  bullet / numbered / todo lists, code fences, block quotes, dividers, and
//  paragraphs with inline bold / italic / code / link.
//
//  Not a full CommonMark implementation — for anything fancier the user can
//  open the page in Notion directly. The goal is "what the model writes ends
//  up looking right in Notion, and what's already in Notion reads back as
//  recognizable markdown."
//

import Foundation

enum NotionMarkdown {

    /// Notion's hard cap on a single rich-text text segment's content.
    private static let maxTextChunk = 2000

    // MARK: - Markdown → blocks

    /// Parse a markdown string into an array of Notion block dicts ready to
    /// be sent as `children` in a create-page or append-block-children call.
    static func blocks(fromMarkdown md: String) -> [[String: Any]] {
        guard !md.isEmpty else { return [] }
        var out: [[String: Any]] = []
        // Split on \n but keep empty lines so paragraph breaks survive.
        // Normalize CRLF first so Windows-style input behaves.
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                         omittingEmptySubsequences: false)
                                                                    .map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Code fence — consume until the closing ```.
            if let lang = openingCodeFence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count, !isClosingCodeFence(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume the closing fence
                out.append(codeBlock(language: lang, text: body.joined(separator: "\n")))
                continue
            }

            // Horizontal rule.
            if line.trimmingCharacters(in: .whitespaces) == "---"
                || line.trimmingCharacters(in: .whitespaces) == "***" {
                out.append(["object": "block", "type": "divider", "divider": [String: Any]()])
                i += 1
                continue
            }

            // Headings (#, ##, ### — collapse 4–6 to ### so they stay in the
            // Notion-supported set without losing the hierarchy entirely).
            if let (level, content) = headingPrefix(line) {
                let kind = level == 1 ? "heading_1" : (level == 2 ? "heading_2" : "heading_3")
                out.append([
                    "object": "block",
                    "type": kind,
                    kind: ["rich_text": richText(for: content)]
                ])
                i += 1
                continue
            }

            // Block quote — single line; chained quotes become separate blocks.
            if line.hasPrefix("> ") || line == ">" {
                let content = line.hasPrefix("> ") ? String(line.dropFirst(2)) : ""
                out.append([
                    "object": "block",
                    "type": "quote",
                    "quote": ["rich_text": richText(for: content)]
                ])
                i += 1
                continue
            }

            // To-do.
            if let (checked, content) = todoPrefix(line) {
                out.append([
                    "object": "block",
                    "type": "to_do",
                    "to_do": ["rich_text": richText(for: content), "checked": checked]
                ])
                i += 1
                continue
            }

            // Bulleted list.
            if let content = bulletedListPrefix(line) {
                out.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": ["rich_text": richText(for: content)]
                ])
                i += 1
                continue
            }

            // Numbered list.
            if let content = numberedListPrefix(line) {
                out.append([
                    "object": "block",
                    "type": "numbered_list_item",
                    "numbered_list_item": ["rich_text": richText(for: content)]
                ])
                i += 1
                continue
            }

            // Blank line — paragraph separator. Already handled by the fact
            // that paragraphs are one-line each; just skip.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Default: paragraph. Greedy join with subsequent non-blank,
            // non-special lines so a soft-wrapped paragraph survives as one
            // Notion block.
            var paragraphLines = [line]
            var j = i + 1
            while j < lines.count,
                  !lines[j].trimmingCharacters(in: .whitespaces).isEmpty,
                  !isBlockStarter(lines[j]) {
                paragraphLines.append(lines[j])
                j += 1
            }
            out.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": richText(for: paragraphLines.joined(separator: " "))]
            ])
            i = j
        }
        return out
    }

    // MARK: - Blocks → markdown

    /// Convert an array of Notion block dicts back into a markdown string.
    /// Used by `read_notion_page` so the model sees recognizable markdown
    /// rather than raw JSON blocks. Walks `_loop_children` (populated by
    /// NotionClient.listAllBlockChildrenRecursive) so toggle bodies, table
    /// rows, column layouts, callouts, and nested lists are not silently
    /// dropped.
    static func markdown(fromBlocks blocks: [[String: Any]]) -> String {
        var out: [String] = []
        for block in blocks {
            if let chunk = renderBlock(block), !chunk.isEmpty {
                out.append(chunk)
            }
        }
        return out.joined(separator: "\n\n")
    }

    /// Render a single block (plus its inlined children) to a markdown string.
    /// Returns nil/empty when the block has nothing worth surfacing.
    private static func renderBlock(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        let payload = (block[type] as? [String: Any]) ?? [:]
        let children = (block["_loop_children"] as? [[String: Any]]) ?? []

        switch type {
        case "paragraph":
            let text = plainText(from: payload["rich_text"])
            return appendChildren(text, children)
        case "heading_1":
            return appendChildren("# " + plainText(from: payload["rich_text"]), children)
        case "heading_2":
            return appendChildren("## " + plainText(from: payload["rich_text"]), children)
        case "heading_3":
            return appendChildren("### " + plainText(from: payload["rich_text"]), children)
        case "bulleted_list_item":
            return appendChildren("- " + plainText(from: payload["rich_text"]), children)
        case "numbered_list_item":
            return appendChildren("1. " + plainText(from: payload["rich_text"]), children)
        case "to_do":
            let checked = (payload["checked"] as? Bool) == true
            return appendChildren("- [\(checked ? "x" : " ")] " + plainText(from: payload["rich_text"]),
                                  children)
        case "quote":
            return appendChildren("> " + plainText(from: payload["rich_text"]), children)
        case "code":
            let lang = (payload["language"] as? String) ?? ""
            let body = plainText(from: payload["rich_text"])
            return "```\(lang)\n\(body)\n```"
        case "divider":
            return "---"
        case "child_page":
            // Notion stores child page references as their own block — surface
            // the title so the model can decide to follow up.
            if let title = payload["title"] as? String, !title.isEmpty {
                return "- 📄 \(title)"
            }
            return nil
        case "child_database":
            if let title = payload["title"] as? String, !title.isEmpty {
                return "- 📊 \(title) (database — body not inlined)"
            }
            return "- 📊 Linked database (body not inlined)"
        case "toggle":
            // Toggle header + its body inlined underneath so the contents
            // aren't lost just because Notion collapsed them.
            let header = "▸ " + plainText(from: payload["rich_text"])
            return appendChildren(header, children)
        case "callout":
            let icon = (payload["icon"] as? [String: Any])?["emoji"] as? String ?? "💡"
            let text = plainText(from: payload["rich_text"])
            return appendChildren("> \(icon) \(text)", children)
        case "table":
            return renderTable(block: block)
        case "table_row":
            // Normally consumed by the parent `table` renderer; if we reach it
            // standalone (no parent context), fall back to a pipe-joined line.
            if let cells = payload["cells"] as? [[[String: Any]]] {
                let parts = cells.map { escapeTableCell(plainText(from: $0)) }
                return "| " + parts.joined(separator: " | ") + " |"
            }
            return nil
        case "column_list", "column", "synced_block":
            // Transparent containers — just inline the children, no marker.
            guard !children.isEmpty else { return nil }
            return markdown(fromBlocks: children)
        case "bookmark", "embed", "link_preview":
            guard let url = payload["url"] as? String, !url.isEmpty else { return nil }
            let caption = plainText(from: payload["caption"])
            let icon = type == "bookmark" ? "🔖" : "🔗"
            if caption.isEmpty { return "\(icon) \(url)" }
            return "\(icon) [\(caption)](\(url))"
        case "image", "video", "file", "pdf", "audio":
            guard let url = mediaURL(from: payload) else { return nil }
            let caption = plainText(from: payload["caption"])
            let icon: String
            switch type {
            case "image": icon = "🖼️"
            case "video": icon = "🎥"
            case "audio": icon = "🔊"
            case "pdf":   icon = "📄"
            default:      icon = "📎"
            }
            if caption.isEmpty { return "\(icon) \(url)" }
            return "\(icon) [\(caption)](\(url))"
        case "link_to_page":
            if let id = (payload["page_id"] as? String) ?? (payload["database_id"] as? String),
               !id.isEmpty {
                return "→ Linked page: \(id)"
            }
            return nil
        case "equation":
            if let expr = payload["expression"] as? String, !expr.isEmpty {
                return "$$\(expr)$$"
            }
            return nil
        case "table_of_contents":
            return "[table of contents]"
        case "breadcrumb":
            return nil
        case "unsupported":
            return "[unsupported block]"
        default:
            // Unknown block — best-effort surface any rich_text it has plus
            // any children we managed to fetch.
            var pieces: [String] = []
            if let rt = payload["rich_text"] {
                let text = plainText(from: rt)
                if !text.isEmpty { pieces.append(text) }
            }
            if !children.isEmpty {
                let sub = markdown(fromBlocks: children)
                if !sub.isEmpty { pieces.append(sub) }
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
        }
    }

    /// Combine a block's own line with its inlined children's markdown so
    /// nested content (sub-bullets under a toggle, etc.) reads naturally.
    private static func appendChildren(_ head: String, _ children: [[String: Any]]) -> String {
        guard !children.isEmpty else { return head }
        let body = markdown(fromBlocks: children)
        if body.isEmpty { return head }
        if head.isEmpty { return body }
        return head + "\n\n" + body
    }

    /// Render a Notion `table` block (with its `table_row` children attached
    /// under `_loop_children`) as a real markdown table. Empty cells become a
    /// single space; pipes and newlines inside cells are escaped so the table
    /// stays well-formed.
    private static func renderTable(block: [String: Any]) -> String? {
        let payload = (block["table"] as? [String: Any]) ?? [:]
        let hasHeader = (payload["has_column_header"] as? Bool) ?? false
        let rowsRaw = (block["_loop_children"] as? [[String: Any]]) ?? []

        var rows: [[String]] = []
        for child in rowsRaw {
            guard (child["type"] as? String) == "table_row",
                  let rowPayload = child["table_row"] as? [String: Any],
                  let cells = rowPayload["cells"] as? [[[String: Any]]] else { continue }
            rows.append(cells.map { escapeTableCell(plainText(from: $0)) })
        }
        guard !rows.isEmpty else { return nil }

        let columnCount = max(rows.map { $0.count }.max() ?? 0,
                              (payload["table_width"] as? Int) ?? 0)
        guard columnCount > 0 else { return nil }
        rows = rows.map { row in
            var r = row
            while r.count < columnCount { r.append(" ") }
            return r.map { $0.isEmpty ? " " : $0 }
        }

        var lines: [String] = []
        let separator = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        if hasHeader {
            lines.append("| " + rows[0].joined(separator: " | ") + " |")
            lines.append(separator)
            for row in rows.dropFirst() {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
        } else {
            lines.append("| " + Array(repeating: " ", count: columnCount).joined(separator: " | ") + " |")
            lines.append(separator)
            for row in rows {
                lines.append("| " + row.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown tables are line-oriented and pipe-delimited — escape both so a
    /// cell that contains either doesn't blow the table apart.
    private static func escapeTableCell(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Notion's media blocks (image/video/file/pdf/audio) wrap the URL in
    /// either an `external` or `file` envelope depending on whether the asset
    /// was linked or uploaded. Probe both.
    private static func mediaURL(from payload: [String: Any]) -> String? {
        if let external = payload["external"] as? [String: Any],
           let url = external["url"] as? String, !url.isEmpty { return url }
        if let file = payload["file"] as? [String: Any],
           let url = file["url"] as? String, !url.isEmpty { return url }
        return nil
    }

    // MARK: - Block builders

    private static func codeBlock(language: String, text: String) -> [String: Any] {
        // Notion's known languages are a closed list; anything we don't
        // recognize gets mapped to "plain text" so the API doesn't 400.
        let normalized = normalizeCodeLanguage(language)
        return [
            "object": "block",
            "type": "code",
            "code": [
                "language": normalized,
                "rich_text": [
                    ["type": "text", "text": ["content": text]]
                ]
            ]
        ]
    }

    /// Notion accepts a fixed set of language strings on code blocks; passing
    /// anything else returns validation_error. Map the common aliases and
    /// fall back to "plain text" for the rest.
    private static func normalizeCodeLanguage(_ raw: String) -> String {
        let lang = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch lang {
        case "":                                       return "plain text"
        case "js", "javascript":                       return "javascript"
        case "ts", "typescript":                       return "typescript"
        case "py", "python":                           return "python"
        case "rb", "ruby":                             return "ruby"
        case "rs", "rust":                             return "rust"
        case "go", "golang":                           return "go"
        case "swift":                                  return "swift"
        case "kt", "kotlin":                           return "kotlin"
        case "java":                                   return "java"
        case "c":                                      return "c"
        case "cpp", "c++":                             return "c++"
        case "cs", "csharp", "c#":                     return "c#"
        case "sh", "bash", "zsh", "shell":             return "shell"
        case "json":                                   return "json"
        case "yaml", "yml":                            return "yaml"
        case "html":                                   return "html"
        case "css":                                    return "css"
        case "sql":                                    return "sql"
        case "md", "markdown":                         return "markdown"
        case "xml":                                    return "xml"
        case "toml":                                   return "toml"
        case "graphql":                                return "graphql"
        case "diff":                                   return "diff"
        case "objc", "objective-c":                    return "objective-c"
        default:                                       return "plain text"
        }
    }

    // MARK: - Block prefix recognizers

    private static func headingPrefix(_ line: String) -> (level: Int, content: String)? {
        // Match 1–6 # then a required space (Notion only has 3 heading levels;
        // we collapse h4–h6 to h3 in the caller).
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", count < 6 {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 1, idx < line.endIndex, line[idx] == " " else { return nil }
        let content = String(line[line.index(after: idx)...])
        let clamped = min(count, 3)
        return (clamped, content)
    }

    private static func todoPrefix(_ line: String) -> (checked: Bool, content: String)? {
        // "- [ ] foo" / "- [x] foo" / "* [X] foo"
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "-" || first == "*" else { return nil }
        let afterMark = trimmed.dropFirst().drop(while: { $0 == " " })
        guard afterMark.hasPrefix("[") else { return nil }
        guard afterMark.count >= 4 else { return nil }
        let openIdx = afterMark.startIndex
        let boxIdx = afterMark.index(after: openIdx)
        let closeIdx = afterMark.index(boxIdx, offsetBy: 1)
        guard closeIdx < afterMark.endIndex, afterMark[closeIdx] == "]" else { return nil }
        let mark = afterMark[boxIdx]
        let checked = (mark == "x" || mark == "X")
        let isUnchecked = (mark == " ")
        guard checked || isUnchecked else { return nil }
        let after = afterMark[afterMark.index(after: closeIdx)...].drop(while: { $0 == " " })
        return (checked, String(after))
    }

    private static func bulletedListPrefix(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("* ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("+ ") { return String(trimmed.dropFirst(2)) }
        return nil
    }

    private static func numberedListPrefix(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        var digitIdx = trimmed.startIndex
        while digitIdx < trimmed.endIndex, trimmed[digitIdx].isNumber {
            digitIdx = trimmed.index(after: digitIdx)
        }
        guard digitIdx != trimmed.startIndex,
              digitIdx < trimmed.endIndex,
              trimmed[digitIdx] == ".",
              trimmed.index(after: digitIdx) < trimmed.endIndex,
              trimmed[trimmed.index(after: digitIdx)] == " " else { return nil }
        return String(trimmed[trimmed.index(digitIdx, offsetBy: 2)...])
    }

    private static func openingCodeFence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return lang  // empty string is valid (plain text)
    }

    private static func isClosingCodeFence(_ line: String) -> Bool {
        return line.trimmingCharacters(in: .whitespaces) == "```"
    }

    /// True if this line starts a block other than a paragraph — used to know
    /// when to stop greedily joining paragraph continuations.
    private static func isBlockStarter(_ line: String) -> Bool {
        if openingCodeFence(line) != nil { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == "***" { return true }
        if headingPrefix(line) != nil { return true }
        if line.hasPrefix("> ") || line == ">" { return true }
        if todoPrefix(line) != nil { return true }
        if bulletedListPrefix(line) != nil { return true }
        if numberedListPrefix(line) != nil { return true }
        return false
    }

    // MARK: - Inline rich-text builder

    /// Build Notion `rich_text` array from a single-line content string. Walks
    /// the string left-to-right and emits a `text` segment per run, applying
    /// bold / italic / code annotations and link hrefs as it goes.
    private static func richText(for content: String) -> [[String: Any]] {
        // Tokenize into runs by repeatedly looking for the earliest inline
        // marker (`**`, `*`, `` ` ``, `[`).
        var out: [[String: Any]] = []
        var remaining = Substring(content)

        while !remaining.isEmpty {
            if let match = nextInlineMatch(in: remaining) {
                if match.range.lowerBound > remaining.startIndex {
                    out.append(textSegment(String(remaining[remaining.startIndex..<match.range.lowerBound]),
                                            annotations: [:], link: nil))
                }
                out.append(match.segment)
                remaining = remaining[match.range.upperBound...]
            } else {
                out.append(textSegment(String(remaining), annotations: [:], link: nil))
                remaining = Substring()
            }
        }

        // Notion rejects an empty rich_text array on some block types
        // (it wants at least one entry), and rejects each text chunk longer
        // than 2000 chars. Enforce both invariants here.
        let chunked = out.flatMap { segment -> [[String: Any]] in
            guard var text = segment["text"] as? [String: Any],
                  let content = text["content"] as? String,
                  content.count > maxTextChunk else { return [segment] }
            var pieces: [[String: Any]] = []
            var idx = content.startIndex
            while idx < content.endIndex {
                let end = content.index(idx, offsetBy: maxTextChunk, limitedBy: content.endIndex) ?? content.endIndex
                text["content"] = String(content[idx..<end])
                var copy = segment
                copy["text"] = text
                pieces.append(copy)
                idx = end
            }
            return pieces
        }
        return chunked.isEmpty ? [textSegment("", annotations: [:], link: nil)] : chunked
    }

    /// Single inline-marker hit: the substring range it covered and the
    /// rich-text segment to emit in its place.
    private struct InlineMatch {
        let range: Range<Substring.Index>
        let segment: [String: Any]
    }

    /// Scan for the next inline marker and parse it.
    private static func nextInlineMatch(in text: Substring) -> InlineMatch? {
        var best: InlineMatch?

        // Helper to update `best` only if this match starts earlier than
        // whatever we have so far.
        func consider(_ match: InlineMatch?) {
            guard let match else { return }
            if let current = best {
                if match.range.lowerBound < current.range.lowerBound { best = match }
            } else {
                best = match
            }
        }

        consider(matchPair(in: text, marker: "**", annotations: ["bold": true]))
        consider(matchPair(in: text, marker: "*",  annotations: ["italic": true]))
        consider(matchPair(in: text, marker: "`",  annotations: ["code": true]))
        consider(matchLink(in: text))
        return best
    }

    /// Match `<marker>X<marker>` (no nested marker, non-empty inner).
    private static func matchPair(in text: Substring,
                                  marker: String,
                                  annotations: [String: Bool]) -> InlineMatch? {
        guard let openRange = text.range(of: marker) else { return nil }
        // Skip the `**` case being misread as `*` when scanning for italic.
        if marker == "*",
           openRange.upperBound < text.endIndex,
           text[openRange.upperBound] == "*" {
            return nil
        }
        // Also skip when the `*` is the second half of a `**` already covered.
        if marker == "*",
           openRange.lowerBound > text.startIndex,
           text[text.index(before: openRange.lowerBound)] == "*" {
            return nil
        }
        let afterOpen = openRange.upperBound
        guard afterOpen < text.endIndex,
              let closeRange = text.range(of: marker, range: afterOpen..<text.endIndex),
              closeRange.lowerBound > afterOpen else { return nil }
        let inner = String(text[afterOpen..<closeRange.lowerBound])
        guard !inner.isEmpty else { return nil }
        let segment = textSegment(inner, annotations: annotations, link: nil)
        return InlineMatch(range: openRange.lowerBound..<closeRange.upperBound, segment: segment)
    }

    /// Match `[text](url)`.
    private static func matchLink(in text: Substring) -> InlineMatch? {
        guard let openText = text.firstIndex(of: "["),
              let closeText = text.range(of: "]", range: openText..<text.endIndex)?.lowerBound,
              text.index(after: closeText) < text.endIndex,
              text[text.index(after: closeText)] == "(",
              let closeURL = text.range(of: ")", range: text.index(closeText, offsetBy: 2)..<text.endIndex)?.lowerBound
        else { return nil }
        let label = String(text[text.index(after: openText)..<closeText])
        let urlStart = text.index(closeText, offsetBy: 2)
        let url = String(text[urlStart..<closeURL])
        guard !label.isEmpty, !url.isEmpty else { return nil }
        let segment = textSegment(label, annotations: [:], link: url)
        return InlineMatch(range: openText..<text.index(after: closeURL), segment: segment)
    }

    private static func textSegment(_ content: String,
                                    annotations: [String: Bool],
                                    link: String?) -> [String: Any] {
        var text: [String: Any] = ["content": content]
        if let link, !link.isEmpty {
            text["link"] = ["url": link]
        }
        var segment: [String: Any] = [
            "type": "text",
            "text": text
        ]
        if !annotations.isEmpty {
            segment["annotations"] = annotations
        }
        return segment
    }

    /// Flatten a `rich_text` array back into a single string by concatenating
    /// each segment's `plain_text` (or `text.content` as fallback).
    private static func plainText(from richText: Any?) -> String {
        guard let array = richText as? [[String: Any]] else { return "" }
        var out = ""
        for seg in array {
            if let plain = seg["plain_text"] as? String { out += plain; continue }
            if let text = seg["text"] as? [String: Any],
               let content = text["content"] as? String { out += content }
        }
        return out
    }
}
