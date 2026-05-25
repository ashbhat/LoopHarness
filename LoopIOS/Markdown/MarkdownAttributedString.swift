//
//  MarkdownAttributedString.swift
//  Loop
//
//  Shared markdown → NSAttributedString renderer. Originated in
//  `MessagingCell.attributedString(from:)`; lifted here so the chat bubble
//  and the expanded AgentView's transcript both produce the same styled
//  output without duplicating regex passes.
//
//  Handles the project's working subset: ATX headers (`#`-`######`),
//  `**bold**`, `[link](url)`, in-vault filesystem paths via
//  `FilePathLinkifier`, and bare URLs via NSDataDetector. Intentionally
//  permissive on partial input — an unclosed `**bold` reads as the raw
//  characters until the closing pair arrives, which is exactly what the
//  typewriter reveal in AgentLargeView depends on.
//

#if os(iOS)

import UIKit

enum MarkdownAttributedString {

    /// Build a styled attributed string from a markdown source. Returns a
    /// plain body-styled string on regex failure (extremely unlikely — the
    /// patterns are static) so a malformed input can never crash the
    /// renderer.
    static func render(_ text: String) -> NSAttributedString {
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let attributedString = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: UIColor.label
            ]
        )

        // Fenced code blocks: ```lang\n…\n```. Strip the fence markers and
        // style the interior as a monospaced block with a tinted background.
        // Processed first so later passes (headers, bold, links) never touch
        // source code inside a fence.
        do {
            let fencedRegex = try NSRegularExpression(
                pattern: "(?m)^[ \\t]*(`{3,}|~{3,})[^\\n]*\\n([\\s\\S]*?)^[ \\t]*\\1[ \\t]*$",
                options: [.anchorsMatchLines]
            )
            let fencedMatches = fencedRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            let codeFont = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            let codeBg = UIColor.label.withAlphaComponent(0.06)
            for match in fencedMatches.reversed() {
                let codeRange = match.range(at: 2)
                guard codeRange.location != NSNotFound else { continue }
                let codeText = (attributedString.string as NSString).substring(with: codeRange)
                let replacement = NSMutableAttributedString(string: codeText, attributes: [
                    .font: codeFont,
                    .foregroundColor: UIColor.label,
                    .backgroundColor: codeBg,
                ])
                attributedString.replaceCharacters(in: match.range, with: replacement)
            }
        } catch {}

        do {
            // Headers — '#' through '######'. We walk matches in reverse so
            // replacements don't shift the ranges of earlier matches.
            let headerRegex = try NSRegularExpression(
                pattern: "^(#{1,6})\\s*(.*?)$",
                options: [.anchorsMatchLines]
            )
            let headerMatches = headerRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            for match in headerMatches.reversed() {
                let headerLevel = match.range(at: 1).length
                if let headerContentRange = Range(match.range(at: 2), in: attributedString.string) {
                    let headerText = String(attributedString.string[headerContentRange])
                    let headerFont = UIFont.boldSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize
                            - CGFloat(headerLevel - 1) * 2
                    )
                    let headerAttributedString = NSAttributedString(
                        string: headerText,
                        attributes: [
                            .font: headerFont,
                            .foregroundColor: UIColor.label
                        ]
                    )
                    attributedString.replaceCharacters(in: match.range, with: headerAttributedString)
                }
            }

            // **bold**.
            let boldRegex = try NSRegularExpression(pattern: "\\*\\*(.*?)\\*\\*", options: [])
            let boldMatches = boldRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            for match in boldMatches.reversed() {
                if let boldRange = Range(match.range(at: 1), in: attributedString.string) {
                    let boldText = String(attributedString.string[boldRange])
                    let boldAttributedString = NSAttributedString(
                        string: boldText,
                        attributes: [
                            .font: UIFont.boldSystemFont(
                                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize
                            ),
                            .foregroundColor: UIColor.label
                        ]
                    )
                    attributedString.replaceCharacters(in: match.range, with: boldAttributedString)
                }
            }

            // Inline code: `text`. Monospaced font with a subtle background.
            // Runs after bold so backtick-wrapped content inside **bold `code`**
            // picks up the code styling. Skips ranges already styled as code
            // blocks (which carry .backgroundColor from the fenced pass above).
            let inlineCodeRegex = try NSRegularExpression(pattern: "`([^`\\n]+)`", options: [])
            let inlineCodeMatches = inlineCodeRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            let inlineCodeFont = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 0.5, weight: .regular)
            let inlineCodeBg = UIColor.label.withAlphaComponent(0.08)
            for match in inlineCodeMatches.reversed() {
                let innerRange = match.range(at: 1)
                guard innerRange.location != NSNotFound else { continue }
                if attributedString.attribute(.backgroundColor, at: match.range.location, effectiveRange: nil) != nil { continue }
                let codeText = (attributedString.string as NSString).substring(with: innerRange)
                let code = NSAttributedString(string: codeText, attributes: [
                    .font: inlineCodeFont,
                    .foregroundColor: UIColor.label,
                    .backgroundColor: inlineCodeBg,
                ])
                attributedString.replaceCharacters(in: match.range, with: code)
            }

            // [text](url) markdown links.
            let linkRegex = try NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#, options: [])
            let linkMatches = linkRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            for match in linkMatches.reversed() {
                guard match.numberOfRanges == 3 else { continue }
                let textRange = match.range(at: 1)
                let urlRange = match.range(at: 2)
                let urlString = (attributedString.string as NSString).substring(with: urlRange)
                guard let url = URL(string: urlString) else { continue }
                let inner = attributedString.attributedSubstring(from: textRange).mutableCopy() as! NSMutableAttributedString
                let innerRange = NSRange(location: 0, length: inner.length)
                inner.addAttribute(.link, value: url, range: innerRange)
                inner.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: innerRange)
                inner.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: innerRange)
                attributedString.replaceCharacters(in: match.range, with: inner)
            }

            // Filesystem paths → tappable file name. Vault-relative paths
            // become obsidian:// links, others become file://. Runs before
            // the NSDataDetector pass so a path never gets reinterpreted as
            // a generic URL.
            let pathRegex = try NSRegularExpression(pattern: FilePathLinkifier.pattern, options: [])
            let pathMatches = pathRegex.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            for match in pathMatches.reversed() {
                if attributedString.attribute(.link, at: match.range.location, effectiveRange: nil) != nil {
                    continue
                }
                let raw = (attributedString.string as NSString).substring(with: match.range)
                guard let resolved = FilePathLinkifier.resolve(raw) else { continue }
                let replacement = NSMutableAttributedString(string: resolved.displayName, attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.systemBlue,
                ])
                let r = NSRange(location: 0, length: replacement.length)
                replacement.addAttribute(.link, value: resolved.url, range: r)
                replacement.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                attributedString.replaceCharacters(in: match.range, with: replacement)
            }

            // Bare URL detection.
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let urlMatches = detector.matches(
                in: attributedString.string,
                options: [],
                range: NSRange(location: 0, length: attributedString.length)
            )
            for match in urlMatches {
                guard let url = match.url else { continue }
                if attributedString.attribute(.link, at: match.range.location, effectiveRange: nil) != nil {
                    continue
                }
                attributedString.addAttribute(.link, value: url, range: match.range)
                attributedString.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: match.range)
                attributedString.addAttribute(.underlineStyle,
                                              value: NSUnderlineStyle.single.rawValue,
                                              range: match.range)
            }
        } catch {
            // Regex construction can only fail on malformed patterns, and
            // all patterns above are static literals — keep a print here
            // so a future contributor knows where to look if it ever does.
            print("MarkdownAttributedString: regex setup failed — \(error)")
        }

        return attributedString
    }
}

#endif
