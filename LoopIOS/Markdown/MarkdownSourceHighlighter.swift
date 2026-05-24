//
//  MarkdownSourceHighlighter.swift
//  Loop / LoopMac (shared — compiled into both targets)
//
//  Live syntax styling for an *editable* markdown buffer. Unlike the
//  read-only renderers in MessagingCell / ConversationWindowController, this
//  never mutates the text — the raw markdown characters stay exactly where
//  the user typed them. It only layers attributes on top so the source reads
//  like a styled document while remaining fully editable: headings grow and
//  bold, **bold**/*italic*/`code` pick up their styling inline, fenced code
//  blocks go monospace, links/markers dim. Callers re-run `highlight` after
//  every edit (selection is the caller's responsibility to preserve).
//
//  Cross-platform: UIKit on iOS, AppKit on macOS. The regex passes operate
//  purely on NSTextStorage so the only platform-specific bits are the font /
//  color factories below.
//

import Foundation

#if canImport(UIKit)
import UIKit
private typealias MDFont = UIFont
private typealias MDColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias MDFont = NSFont
private typealias MDColor = NSColor
#endif

enum MarkdownSourceHighlighter {

    /// File extensions we treat as markdown — anything here opens in the
    /// editor instead of QuickLook / the system handler. Kept deliberately
    /// generous so the common authoring extensions all work.
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"
    ]

    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Above this length we stop running the inline/heading regexes on every
    /// keystroke and fall back to a flat body style — markdown files are
    /// almost always tiny (Workspace caps everything at 1 MB) but a runaway
    /// pasted blob shouldn't make typing lag.
    private static let richHighlightCharCap = 60_000

    /// Re-apply all styling to `storage`. Safe to call inside
    /// `textViewDidChange` / `textDidChange`; wraps its mutations in
    /// begin/endEditing and only touches attributes, never characters.
    static func highlight(_ storage: NSTextStorage, baseSize: CGFloat) {
        let style = Style(baseSize: baseSize)
        let text = storage.string
        let fullLength = (text as NSString).length
        let full = NSRange(location: 0, length: fullLength)

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.setAttributes([
            .font: style.body,
            .foregroundColor: style.textColor,
        ], range: full)

        guard fullLength <= richHighlightCharCap else { return }

        applyHeadings(storage, text: text, style: style)
        applyBlockquotes(storage, text: text, style: style)
        applyLists(storage, text: text, style: style)
        applyInline(storage, text: text, pattern: Patterns.bold, style: style) { range in
            storage.addAttribute(.font, value: style.bold, range: range)
        }
        applyInline(storage, text: text, pattern: Patterns.italic, style: style) { range in
            storage.addAttribute(.font, value: style.italic, range: range)
        }
        applyInline(storage, text: text, pattern: Patterns.strikethrough, style: style) { range in
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: range)
        }
        applyLinks(storage, text: text, style: style)
        applyInlineCode(storage, text: text, style: style)
        applyFencedCode(storage, text: text, style: style)
    }

    // MARK: - Passes

    private static func applyHeadings(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.heading.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            let markerRange = match.range(at: 1)
            let level = markerRange.length
            storage.addAttribute(.font, value: style.heading(level), range: match.range)
            storage.addAttribute(.foregroundColor, value: style.textColor, range: match.range)
            // Dim the leading #'s so the structure is visible but quiet.
            storage.addAttribute(.foregroundColor, value: style.dim, range: markerRange)
        }
    }

    private static func applyBlockquotes(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.blockquote.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match else { return }
            storage.addAttribute(.foregroundColor, value: style.quote, range: match.range)
            storage.addAttribute(.font, value: style.italic, range: match.range)
        }
    }

    private static func applyLists(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.listMarker.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            let markerRange = match.range(at: 2)
            guard markerRange.location != NSNotFound else { return }
            storage.addAttribute(.foregroundColor, value: style.accent, range: markerRange)
            storage.addAttribute(.font, value: style.bold, range: markerRange)
        }
    }

    private static func applyInline(_ storage: NSTextStorage,
                                    text: String,
                                    pattern: NSRegularExpression,
                                    style: Style,
                                    apply: (NSRange) -> Void) {
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match else { return }
            apply(match.range)
            // Dim the surrounding markers (everything in the full match that
            // isn't the captured content) so emphasis reads cleanly.
            if match.numberOfRanges >= 2 {
                let inner = match.range(at: match.numberOfRanges - 1)
                dimMarkers(storage, fullRange: match.range, contentRange: inner, style: style)
            }
        }
    }

    private static func applyInlineCode(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.inlineCode.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match else { return }
            storage.addAttribute(.font, value: style.mono, range: match.range)
            storage.addAttribute(.backgroundColor, value: style.codeBg, range: match.range)
            if match.numberOfRanges >= 2 {
                dimMarkers(storage, fullRange: match.range, contentRange: match.range(at: 1), style: style)
            }
        }
    }

    private static func applyFencedCode(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.fencedCode.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match else { return }
            storage.addAttribute(.font, value: style.mono, range: match.range)
            storage.addAttribute(.foregroundColor, value: style.textColor, range: match.range)
            storage.addAttribute(.backgroundColor, value: style.codeBg, range: match.range)
        }
    }

    private static func applyLinks(_ storage: NSTextStorage, text: String, style: Style) {
        Patterns.link.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            let labelRange = match.range(at: 1)
            storage.addAttribute(.foregroundColor, value: style.accent, range: labelRange)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: labelRange)
            // The [] and (url) scaffolding dims so the readable label pops.
            dimMarkers(storage, fullRange: match.range, contentRange: labelRange, style: style)
        }
    }

    /// Color every character in `fullRange` that falls outside `contentRange`
    /// with the dim color — used to quiet syntax markers (** _ ` [ ] ( )).
    private static func dimMarkers(_ storage: NSTextStorage,
                                   fullRange: NSRange,
                                   contentRange: NSRange,
                                   style: Style) {
        guard contentRange.location != NSNotFound else {
            storage.addAttribute(.foregroundColor, value: style.dim, range: fullRange)
            return
        }
        let leading = NSRange(location: fullRange.location,
                              length: contentRange.location - fullRange.location)
        if leading.length > 0 {
            storage.addAttribute(.foregroundColor, value: style.dim, range: leading)
        }
        let contentEnd = contentRange.location + contentRange.length
        let fullEnd = fullRange.location + fullRange.length
        let trailing = NSRange(location: contentEnd, length: fullEnd - contentEnd)
        if trailing.length > 0 {
            storage.addAttribute(.foregroundColor, value: style.dim, range: trailing)
        }
    }

    // MARK: - Compiled patterns

    private enum Patterns {
        static let heading = regex("(?m)^[ \\t]*(#{1,6})[ \\t]+[^\\n]*$")
        static let blockquote = regex("(?m)^[ \\t]*>[ \\t]?[^\\n]*$")
        static let listMarker = regex("(?m)^([ \\t]*)([-*+]|\\d+[.)])[ \\t]+")
        // One capture group (the delimiter) + a backreference so the closing
        // run matches the opener; group 2 is the styled content. Keeping it
        // to a single group keeps `applyInline`'s "last group is the content"
        // contract true (an alternation would leave an unmatched group).
        static let bold = regex("(\\*\\*|__)([^\\n]+?)\\1")
        static let italic = regex("(?<![\\*_])([\\*_])(?!\\1)([^\\*_\\n]+?)\\1(?![\\*_])")
        static let strikethrough = regex("~~([^~\\n]+?)~~")
        static let inlineCode = regex("`([^`\\n]+)`")
        static let fencedCode = regex("(?m)^[ \\t]*```[^\\n]*\\n[\\s\\S]*?^[ \\t]*```[ \\t]*$")
        static let link = regex("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // Patterns are compile-time constants — a failure here is a
            // programming error, so trap rather than silently no-op.
            // swiftlint:disable:next force_try
            return try! NSRegularExpression(pattern: pattern)
        }
    }

    // MARK: - Platform style bundle

    private struct Style {
        let body: MDFont
        let bold: MDFont
        let italic: MDFont
        let mono: MDFont
        let textColor: MDColor
        let dim: MDColor
        let accent: MDColor
        let quote: MDColor
        let codeBg: MDColor
        private let baseSize: CGFloat

        init(baseSize: CGFloat) {
            self.baseSize = baseSize
            #if canImport(UIKit)
            let base = UIFont.systemFont(ofSize: baseSize)
            self.body = base
            self.bold = Style.trait(.traitBold, base)
            self.italic = Style.trait(.traitItalic, base)
            self.mono = UIFont.monospacedSystemFont(ofSize: baseSize - 0.5, weight: .regular)
            self.textColor = .label
            self.dim = .tertiaryLabel
            self.accent = .systemBlue
            self.quote = .secondaryLabel
            self.codeBg = UIColor.label.withAlphaComponent(0.08)
            #elseif canImport(AppKit)
            let base = NSFont.systemFont(ofSize: baseSize)
            self.body = base
            self.bold = Style.trait(.bold, base)
            self.italic = Style.trait(.italic, base)
            self.mono = NSFont.monospacedSystemFont(ofSize: baseSize - 0.5, weight: .regular)
            self.textColor = .labelColor
            self.dim = .tertiaryLabelColor
            self.accent = .systemBlue
            self.quote = .secondaryLabelColor
            self.codeBg = NSColor.labelColor.withAlphaComponent(0.10)
            #endif
        }

        /// Bold, scaled-up heading font. Level 1 is biggest; each deeper
        /// level steps back toward the body size.
        func heading(_ level: Int) -> MDFont {
            let bump: CGFloat = [11, 8, 6, 4, 2, 1][max(0, min(5, level - 1))]
            #if canImport(UIKit)
            return UIFont.boldSystemFont(ofSize: baseSize + bump)
            #elseif canImport(AppKit)
            return NSFont.boldSystemFont(ofSize: baseSize + bump)
            #endif
        }

        #if canImport(UIKit)
        private static func trait(_ trait: UIFontDescriptor.SymbolicTraits, _ font: UIFont) -> UIFont {
            var traits = font.fontDescriptor.symbolicTraits
            traits.insert(trait)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
        #elseif canImport(AppKit)
        private static func trait(_ trait: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        #endif
    }
}
