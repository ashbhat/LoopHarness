import Foundation

/// Preprocesses raw assistant output before it reaches a TTS engine.
///
/// Loop's language model emits text shaped for *reading*: markdown emphasis,
/// URLs, code fences, tool-call XML, numbered lists, debug artifacts. Feeding
/// that straight into a synthesizer produces speech full of "asterisk asterisk",
/// dictated URLs, and lists that run together because periods after digits
/// barely register as pauses.
///
/// `SpeechSanitizer` is the dedicated layer between LLM output and the
/// synthesizer. V0 is a pure-text preprocessor — it takes a `String` of raw
/// model output and returns a `String` shaped for listening. The pipeline is
/// composed of ordered phases; each phase is a small `(String) -> String`
/// transformation. New phases can be inserted, swapped, or made
/// provider-specific without touching the call sites in `MessagingVC`.
///
/// Future expansion (intentionally out of scope for V0): pronunciation
/// dictionaries, SSML emission, summarization/truncation, speech-aware
/// rewriting, and provider-specific tuning (Deepgram vs. ElevenLabs vs.
/// AVSpeech).
struct SpeechSanitizer {

    struct Configuration {
        /// Replacement spoken aloud in place of a stripped URL. Empty drops
        /// the URL entirely; "link" keeps the listener oriented without
        /// reading characters.
        var urlPlaceholder: String = "link"

        /// Replacement spoken aloud in place of a stripped filesystem path
        /// (vault notes, absolute paths, ~/-rooted paths). Same rationale
        /// as `urlPlaceholder` — keeps the listener oriented.
        var filePathPlaceholder: String = "file"

        /// When true, replace numbered list markers ("1.", "2.", …) with
        /// ordinal words ("First,", "Second,", …) for 1–9 and "Number N,"
        /// for higher values. Improves pacing because the comma cues a
        /// brief pause that a digit-period does not.
        var rewriteNumberedLists: Bool = true

        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Run the full V0 pipeline. Order matters — code fences must be removed
    /// before markdown emphasis, markdown links must be unwrapped before bare
    /// URLs are stripped, etc.
    func sanitize(_ raw: String) -> String {
        var text = raw
        text = Self.stripCodeFences(text)
        text = Self.stripInlineCode(text)
        text = Self.stripToolArtifacts(text)
        text = Self.unwrapMarkdownLinks(text)
        text = Self.stripUrls(text, placeholder: configuration.urlPlaceholder)
        text = Self.stripFilePaths(text, placeholder: configuration.filePathPlaceholder)
        text = Self.stripImages(text)
        text = Self.stripEmphasis(text)
        text = Self.stripHeadings(text)
        text = Self.stripBlockquotes(text)
        text = Self.stripHorizontalRules(text)
        text = Self.normalizeBullets(text)
        if configuration.rewriteNumberedLists {
            text = Self.rewriteNumberedLists(text)
        }
        text = Self.expandSymbols(text)
        text = Self.collapsePunctuation(text)
        text = Self.stripEmojis(text)
        text = Self.collapseWhitespace(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phases

    /// Drops fenced code blocks (```lang … ```). Reading source aloud is
    /// almost never useful and yields a flood of punctuation.
    private static func stripCodeFences(_ text: String) -> String {
        replacing(text, pattern: "(?s)```[\\s\\S]*?```", with: " ")
    }

    /// Strips backticks around inline code, keeping the contents — short
    /// identifiers like `foo` read fine without the markers.
    private static func stripInlineCode(_ text: String) -> String {
        replacing(text, pattern: "`([^`]*)`", with: "$1")
    }

    /// Removes XML-like tool-call / debug envelopes the model sometimes
    /// echoes (e.g. <tool_call>…</tool_call>, <thinking>…</thinking>) and
    /// leftover "Tool result:" prefixes.
    private static func stripToolArtifacts(_ text: String) -> String {
        var t = text
        t = replacing(t, pattern: "(?is)<\\s*(tool_call|tool_use|tool_result|thinking|scratchpad|system)[^>]*>[\\s\\S]*?<\\s*/\\s*\\1\\s*>", with: " ")
        t = replacing(t, pattern: "(?is)<\\s*/?\\s*[a-z][a-z0-9_-]*[^>]*>", with: " ")
        t = replacing(t, pattern: "(?im)^\\s*(tool result|tool call|debug|trace)\\s*:\\s*.*$", with: " ")
        return t
    }

    /// Markdown links: `[text](https://…)` → `text`. Drops the URL but
    /// keeps the human-readable label.
    private static func unwrapMarkdownLinks(_ text: String) -> String {
        replacing(text, pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", with: "$1")
    }

    /// Bare URLs (http/https/www) get replaced by `placeholder` so the
    /// synthesizer doesn't dictate them character by character.
    private static func stripUrls(_ text: String, placeholder: String) -> String {
        let urlPattern = "(?i)\\b(?:https?://|www\\.)[^\\s)\\]]+"
        return replacing(text, pattern: urlPattern, with: placeholder)
    }

    /// Filesystem path detector. Anchored on a known extension list so we
    /// don't match arbitrary mid-sentence words; allows spaces and U+2013
    /// inside path components so the Obsidian vault's `0. private/17. May
    /// 03 – May 09/…` layout matches as a single path.
    static let filePathPattern: String = {
        let exts = "md|markdown|txt|swift|py|js|ts|tsx|jsx|json|yaml|yml|toml|html|css|sh|rb|go|rs|java|kt|c|h|cpp|hpp|m|mm|png|jpg|jpeg|gif|webp|pdf|csv|log"
        let pathChars = #"[^\n\r<>"|*?]*?"#
        return #"(?<![\w/])"# +
               "(?:" +
                 "/" + pathChars + "|" +
                 "~/" + pathChars + "|" +
                 #"0\. private/"# + pathChars +
               ")" +
               "\\.(?:\(exts))" +
               #"(?=$|[\s)\]\.,;:!?'"])"#
    }()

    /// Filesystem paths get replaced by `placeholder` for the same reason
    /// URLs do — synthesized speech that dictates `/Users/you/…/idea.md`
    /// is unusable. The path is rendered as a tappable link in the chat
    /// UI separately (see `FilePathLinkifier`).
    private static func stripFilePaths(_ text: String, placeholder: String) -> String {
        replacing(text, pattern: filePathPattern, with: placeholder)
    }

    /// Markdown image syntax `![alt](url)` collapses to the alt text — or
    /// nothing if the alt is empty.
    private static func stripImages(_ text: String) -> String {
        replacing(text, pattern: "!\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1")
    }

    /// Removes emphasis markers (`**bold**`, `*italic*`, `_under_`, `~~strike~~`)
    /// while preserving the wrapped text.
    private static func stripEmphasis(_ text: String) -> String {
        var t = text
        t = replacing(t, pattern: "\\*\\*\\*(.+?)\\*\\*\\*", with: "$1")
        t = replacing(t, pattern: "\\*\\*(.+?)\\*\\*", with: "$1")
        t = replacing(t, pattern: "(?<!\\w)\\*(?!\\s)(.+?)(?<!\\s)\\*(?!\\w)", with: "$1")
        t = replacing(t, pattern: "(?<!\\w)_(?!\\s)(.+?)(?<!\\s)_(?!\\w)", with: "$1")
        t = replacing(t, pattern: "~~(.+?)~~", with: "$1")
        return t
    }

    /// Strips leading `#` markers from ATX headings; the heading text is
    /// kept and a trailing period is appended if missing so the synthesizer
    /// pauses before the next paragraph.
    private static func stripHeadings(_ text: String) -> String {
        replacing(text, pattern: "(?m)^\\s{0,3}#{1,6}\\s+(.+?)\\s*#*\\s*$", with: "$1.")
    }

    private static func stripBlockquotes(_ text: String) -> String {
        replacing(text, pattern: "(?m)^\\s{0,3}>\\s?", with: "")
    }

    /// Horizontal rules (---, ***, ___) are visual-only — drop them.
    private static func stripHorizontalRules(_ text: String) -> String {
        replacing(text, pattern: "(?m)^\\s{0,3}([-*_])\\s*\\1\\s*\\1[\\s\\1]*$", with: " ")
    }

    /// Bullet markers at the start of a line ("- ", "* ", "+ ") are dropped.
    /// A period is appended to the previous line if it lacks terminal
    /// punctuation, which gives the synthesizer a real sentence break
    /// between items instead of running them together.
    private static func normalizeBullets(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        let bulletPattern = try? NSRegularExpression(pattern: "^\\s{0,3}[-*+]\\s+(.*)$")
        for raw in lines {
            let range = NSRange(raw.startIndex..., in: raw)
            if let regex = bulletPattern,
               let match = regex.firstMatch(in: raw, range: range),
               match.numberOfRanges == 2,
               let r = Range(match.range(at: 1), in: raw) {
                let item = String(raw[r])
                if let last = out.last, !last.isEmpty, !endsInTerminalPunctuation(last) {
                    out[out.count - 1] = last + "."
                }
                out.append(item)
            } else {
                out.append(raw)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Numbered list markers at the start of a line ("1. ", "2. ", …) get
    /// rewritten so the synthesizer treats them as a spoken cue with a real
    /// pause: "First, …", "Second, …", etc. Past nine, we fall back to
    /// "Number ten, …" form, which still paces better than "10."
    private static func rewriteNumberedLists(_ text: String) -> String {
        let ordinals = [
            1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth",
            6: "Sixth", 7: "Seventh", 8: "Eighth", 9: "Ninth"
        ]
        let pattern = "(?m)^\\s{0,3}(\\d{1,3})[\\.)]\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var cursor = text.startIndex
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match = match,
                  let whole = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let n = Int(text[numRange]) else { return }
            result.append(contentsOf: text[cursor..<whole.lowerBound])
            if let word = ordinals[n] {
                result.append("\(word), ")
            } else {
                result.append("Number \(n), ")
            }
            cursor = whole.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }

    /// Expand a small set of symbols that TTS engines either skip or read
    /// awkwardly. Kept conservative — we don't try to spell out every
    /// number, currency, or unit; the engines already do the common cases.
    private static func expandSymbols(_ text: String) -> String {
        var t = text
        t = replacing(t, pattern: "(\\d)\\s*%", with: "$1 percent")
        t = replacing(t, pattern: "\\s&\\s", with: " and ")
        t = replacing(t, pattern: "\\s/\\s", with: " or ")
        return t
    }

    /// Collapses runs of repeated punctuation that would be read literally.
    /// `....` → `.`, `!!!` → `!`, `???` → `?`, dangling em-dash sequences
    /// become a comma so the synthesizer pauses without saying "dash dash".
    private static func collapsePunctuation(_ text: String) -> String {
        var t = text
        t = replacing(t, pattern: "\\.{2,}", with: ".")
        t = replacing(t, pattern: "!{2,}", with: "!")
        t = replacing(t, pattern: "\\?{2,}", with: "?")
        t = replacing(t, pattern: "-{2,}", with: ",")
        t = replacing(t, pattern: "\\s+([,.!?;:])", with: "$1")
        return t
    }

    /// Drops emoji scalars. Uses `isEmojiPresentation` (not `isEmoji`)
    /// because `isEmoji` is also true for plain digits, `#`, and `*` — they
    /// can form keycap sequences — and stripping those would silently
    /// erase numbers from the spoken text. Also drops the variation
    /// selector and zero-width joiner that glue multi-scalar emoji
    /// together so no leftover combining marks survive.
    private static func stripEmojis(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation { return false }
            switch scalar.value {
            case 0x200D, 0xFE0E, 0xFE0F: return false   // ZWJ, VS-15, VS-16
            case 0x1F1E6...0x1F1FF: return false        // Regional indicators (flags)
            default: return true
            }
        }))
    }

    /// Collapses internal whitespace runs to a single space, preserves
    /// paragraph breaks (a blank line between blocks) so the synthesizer
    /// gets a longer pause between sections.
    private static func collapseWhitespace(_ text: String) -> String {
        var t = text
        t = replacing(t, pattern: "[ \\t]+", with: " ")
        t = replacing(t, pattern: "\\n{3,}", with: "\n\n")
        t = replacing(t, pattern: "(?m)^[ \\t]+|[ \\t]+$", with: "")
        return t
    }

    // MARK: - Helpers

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func endsInTerminalPunctuation(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?;:,".contains(last)
    }
}
