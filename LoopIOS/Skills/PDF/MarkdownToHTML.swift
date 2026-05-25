//
//  MarkdownToHTML.swift
//  Loop
//
//  Built from LoopIOS/pdf_spec.md.
//
//  Focused GFM → HTML converter for the PDF renderer. Scope is the subset
//  the model is told to use: headings, paragraphs, **bold** / *italic*,
//  `code` / fenced ```code```, lists (flat ul/ol), GFM pipe tables,
//  blockquotes, links, images, horizontal rules.
//
//  Why not bring in cmark / swift-markdown:
//  - Zero deps to add to the Xcode targets.
//  - The model's output is constrained by the system prompt — we don't need
//    full CommonMark coverage, just the shapes we actually produce.
//  - HTML escaping + image rewriting (workspace:// → file://) is bespoke
//    enough that even with a full library we'd be post-processing anyway.
//

import Foundation

enum MarkdownToHTML {

    /// Convert `markdown` to an HTML body fragment (no <html>/<head>/<body>
    /// wrapper — the template shell supplies those). Image URLs that begin
    /// with `workspace://` are rewritten to `file://` URLs anchored at the
    /// workspace root so WKWebView can load them. Other URLs are left alone.
    static func render(_ markdown: String, workspaceRoot: URL) -> String {
        var out = ""
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
                            .components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ```lang … ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                                .trimmingCharacters(in: .whitespaces)
                var code = ""
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code += (code.isEmpty ? "" : "\n") + l
                    i += 1
                }
                i += 1   // consume closing fence
                let classAttr = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out += "<pre><code\(classAttr)>\(escape(code))</code></pre>\n"
                continue
            }

            // Horizontal rule: --- or *** on a line of its own
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out += "<hr>\n"
                i += 1
                continue
            }

            // ATX heading
            if let heading = parseHeading(trimmed) {
                out += "<h\(heading.level)>\(renderInline(heading.text, workspaceRoot: workspaceRoot))</h\(heading.level)>\n"
                i += 1
                continue
            }

            // GFM table: a line with pipes followed by a separator row of
            // `| --- | --- |`. We detect by looking ahead; if no separator
            // we fall through and treat the pipes as plain inline.
            if trimmed.contains("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                let (block, consumed) = parseTable(lines: lines,
                                                   startIndex: i,
                                                   workspaceRoot: workspaceRoot)
                out += block
                i += consumed
                continue
            }

            // Blockquote: consume contiguous `>` lines.
            if trimmed.hasPrefix(">") {
                var collected: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if !l.hasPrefix(">") { break }
                    var rest = String(l.dropFirst())
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    collected.append(rest)
                    i += 1
                }
                let inner = collected.joined(separator: "\n")
                out += "<blockquote>\(renderParagraphs(inner, workspaceRoot: workspaceRoot))</blockquote>\n"
                continue
            }

            // Unordered list: contiguous `- ` / `* ` / `+ ` lines.
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isUnorderedListItem(t) { break }
                    let body = String(t.dropFirst(2))
                    items.append(renderInline(body, workspaceRoot: workspaceRoot))
                    i += 1
                }
                out += "<ul>\n"
                for it in items { out += "<li>\(it)</li>\n" }
                out += "</ul>\n"
                continue
            }

            // Ordered list: lines like `1. ` / `12. `.
            if isOrderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isOrderedListItem(t) { break }
                    if let dot = t.firstIndex(of: ".") {
                        let after = t.index(after: dot)
                        let body = String(t[after...]).trimmingCharacters(in: .whitespaces)
                        items.append(renderInline(body, workspaceRoot: workspaceRoot))
                    }
                    i += 1
                }
                out += "<ol>\n"
                for it in items { out += "<li>\(it)</li>\n" }
                out += "</ol>\n"
                continue
            }

            // Blank line → paragraph break (handled implicitly).
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Plain paragraph: collect contiguous non-blank, non-block lines.
            var paragraph: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") { break }
                if t.hasPrefix("#") { break }
                if t.hasPrefix(">") { break }
                if isUnorderedListItem(t) || isOrderedListItem(t) { break }
                if t == "---" || t == "***" || t == "___" { break }
                paragraph.append(l)
                i += 1
            }
            if !paragraph.isEmpty {
                let joined = paragraph.joined(separator: " ")
                out += "<p>\(renderInline(joined, workspaceRoot: workspaceRoot))</p>\n"
            }
        }

        return out
    }

    // MARK: - Block helpers

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" && level < 6 { level += 1 } else { break }
        }
        guard level > 0, line.count > level,
              line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        let text = String(line.dropFirst(level + 1))
        return (level, text)
    }

    private static func isUnorderedListItem(_ t: String) -> Bool {
        return (t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ "))
    }

    private static func isOrderedListItem(_ t: String) -> Bool {
        guard let dot = t.firstIndex(of: ".") else { return false }
        let prefix = t[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return false }
        let afterDot = t.index(after: dot)
        guard afterDot < t.endIndex else { return false }
        return t[afterDot] == " "
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return false }
        // Drop leading/trailing pipes, split on the rest.
        let inner = t.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = inner.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "")
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
        }
    }

    /// Returns (rendered table HTML, number of lines consumed).
    private static func parseTable(lines: [String],
                                   startIndex: Int,
                                   workspaceRoot: URL) -> (String, Int) {
        let header = splitTableRow(lines[startIndex])
        let alignments = parseTableAlignment(lines[startIndex + 1])
        var bodyRows: [[String]] = []
        var i = startIndex + 2
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || !t.contains("|") { break }
            bodyRows.append(splitTableRow(lines[i]))
            i += 1
        }
        let consumed = i - startIndex

        var html = "<table>\n<thead>\n<tr>"
        for (idx, cell) in header.enumerated() {
            let align = idx < alignments.count ? alignments[idx] : ""
            let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
            html += "<th\(style)>\(renderInline(cell, workspaceRoot: workspaceRoot))</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in bodyRows {
            html += "<tr>"
            for (idx, cell) in row.enumerated() {
                let align = idx < alignments.count ? alignments[idx] : ""
                let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
                html += "<td\(style)>\(renderInline(cell, workspaceRoot: workspaceRoot))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return (html, consumed)
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseTableAlignment(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { raw -> String in
            let s = raw.trimmingCharacters(in: .whitespaces)
            let left = s.hasPrefix(":")
            let right = s.hasSuffix(":")
            switch (left, right) {
            case (true, true):  return "center"
            case (false, true): return "right"
            case (true, false): return "left"
            default:            return ""
            }
        }
    }

    /// Stitch a multi-line block back into paragraphs separated by blank
    /// lines (used inside blockquotes).
    private static func renderParagraphs(_ block: String, workspaceRoot: URL) -> String {
        let paragraphs = block.components(separatedBy: "\n\n")
        return paragraphs
            .map { renderInline($0.replacingOccurrences(of: "\n", with: " "), workspaceRoot: workspaceRoot) }
            .filter { !$0.isEmpty }
            .map { "<p>\($0)</p>" }
            .joined(separator: "\n")
    }

    // MARK: - Inline

    /// Inline pass: HTML-escape, then re-introduce inline markup. Order
    /// matters — code spans short-circuit so backtick-wrapped content isn't
    /// touched by emphasis/link/image substitutions.
    private static func renderInline(_ raw: String, workspaceRoot: URL) -> String {
        // Tokenize: walk the string, peeling off the lowest-precedence
        // tokens first into placeholder slots so the rest of the passes
        // can run on the surrounding text.
        var working = escape(raw)

        // Code spans: `…`. Escape inner content (already escaped above).
        working = replaceMatches(in: working, pattern: "`([^`]+)`") { groups in
            return "<code>\(groups[1])</code>"
        }

        // Images: ![alt](url). Run before links so the `!` prefix wins.
        working = replaceMatches(in: working,
                                 pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\)") { groups in
            let alt = groups[1]
            let rawURL = groups[2]
            let title = groups[3]
            let resolved = rewriteWorkspaceURL(rawURL, root: workspaceRoot)
            let titleAttr = title.isEmpty ? "" : " title=\"\(title)\""
            return "<img src=\"\(resolved)\" alt=\"\(alt)\"\(titleAttr)>"
        }

        // Links: [text](url)
        working = replaceMatches(in: working,
                                 pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\)") { groups in
            let text = groups[1]
            let url = groups[2]
            let title = groups[3]
            let titleAttr = title.isEmpty ? "" : " title=\"\(title)\""
            return "<a href=\"\(url)\"\(titleAttr)>\(text)</a>"
        }

        // Bold: **…**. Run before italic so `**` doesn't get eaten by `*`.
        working = replaceMatches(in: working, pattern: "\\*\\*([^*]+)\\*\\*") { groups in
            return "<strong>\(groups[1])</strong>"
        }

        // Italic: *…*  (single asterisks not adjacent to alphanumerics on
        // both sides — keeps file names like `foo*bar` intact). Cheap
        // approximation: any `*…*` not containing whitespace at the edges.
        working = replaceMatches(in: working, pattern: "(?<!\\*)\\*([^*\\s][^*]*[^*\\s]|[^*\\s])\\*(?!\\*)") { groups in
            return "<em>\(groups[1])</em>"
        }

        return working
    }

    // MARK: - URL rewriting

    /// `workspace://attachments/foo.png` → file URL inside Workspace root.
    /// Anything else is returned unchanged.
    private static func rewriteWorkspaceURL(_ raw: String, root: URL) -> String {
        guard raw.hasPrefix("workspace://") else { return raw }
        var path = String(raw.dropFirst("workspace://".count))
        while path.hasPrefix("/") { path.removeFirst() }
        let url = root.appendingPathComponent(path)
        return url.absoluteString
    }

    // MARK: - Regex helper

    private static func replaceMatches(in input: String,
                                       pattern: String,
                                       transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var result = ""
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return result
    }

    // MARK: - Escape

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}
