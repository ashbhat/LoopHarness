//
//  CodeSyntaxHighlighter.swift
//  Loop / LoopMac (shared — compiled into both targets)
//
//  Regex-based token-level syntax highlighting for fenced code blocks.
//  Produces an NSAttributedString with language-appropriate coloring for
//  keywords, types, strings, comments, numbers, and operators. Designed
//  to be lightweight, dependency-free, and cross-platform (UIKit/AppKit).
//
//  Supported languages: Swift, Python, JavaScript/TypeScript, JSON.
//  Unknown languages fall back to a generic mode that still highlights
//  strings, comments, and numbers.
//

import Foundation

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#endif

// MARK: - Public API

enum CodeSyntaxHighlighter {

    /// Returns a syntax-highlighted attributed string for the given source.
    /// `language` is the optional fence language hint (e.g. "swift", "python").
    /// Falls back to generic highlighting when the language is nil or unknown.
    static func highlight(_ source: String,
                          language: String?,
                          font: PlatformFont) -> NSAttributedString {
        let theme = Theme.current
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.plain,
        ]
        let result = NSMutableAttributedString(string: source, attributes: baseAttrs)
        let fullRange = NSRange(location: 0, length: (source as NSString).length)

        let grammar = Grammar.forLanguage(language)
        var masked = IndexSet()

        // Apply rules in priority order; earlier matches mask later ones
        // so (e.g.) a keyword inside a string doesn't color-bleed.
        for rule in grammar.rules {
            rule.pattern.enumerateMatches(
                in: source,
                options: [],
                range: fullRange
            ) { match, _, _ in
                guard let match = match else { return }
                let range = match.range
                // Skip if any character in this range was already claimed.
                if masked.intersects(integersIn: range.location..<(range.location + range.length)) {
                    return
                }
                result.addAttribute(.foregroundColor, value: rule.color(theme), range: range)
                masked.insert(integersIn: range.location..<(range.location + range.length))
            }
        }

        return result
    }

    /// SwiftUI-friendly variant that returns an `AttributedString`.
    /// Uses the system monospaced font at the given size.
    @available(iOS 15, macOS 12, visionOS 1, *)
    static func highlightedAttributedString(_ source: String,
                                            language: String?,
                                            fontSize: CGFloat) -> AttributedString {
        let font = PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let nsAttr = highlight(source, language: language, font: font)
        #if canImport(UIKit)
        return (try? AttributedString(nsAttr, including: \.uiKit)) ?? AttributedString(source)
        #elseif canImport(AppKit)
        return (try? AttributedString(nsAttr, including: \.appKit)) ?? AttributedString(source)
        #endif
    }
}

// MARK: - Theme (adapts to light/dark mode)

private struct Theme {
    let plain: PlatformColor
    let keyword: PlatformColor
    let type: PlatformColor
    let string: PlatformColor
    let number: PlatformColor
    let comment: PlatformColor
    let property: PlatformColor
    let function: PlatformColor

    static var current: Theme {
        #if canImport(UIKit)
        return Theme(
            plain: .label,
            keyword: UIColor(red: 0.78, green: 0.24, blue: 0.67, alpha: 1),     // magenta/purple
            type: UIColor(red: 0.11, green: 0.56, blue: 0.73, alpha: 1),         // teal
            string: UIColor(red: 0.77, green: 0.26, blue: 0.18, alpha: 1),       // red-orange
            number: UIColor(red: 0.16, green: 0.50, blue: 0.73, alpha: 1),       // blue
            comment: UIColor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1),      // gray
            property: UIColor(red: 0.11, green: 0.56, blue: 0.73, alpha: 1),     // teal
            function: UIColor(red: 0.26, green: 0.45, blue: 0.76, alpha: 1)      // blue
        )
        #elseif canImport(AppKit)
        return Theme(
            plain: .labelColor,
            keyword: NSColor(red: 0.78, green: 0.24, blue: 0.67, alpha: 1),
            type: NSColor(red: 0.11, green: 0.56, blue: 0.73, alpha: 1),
            string: NSColor(red: 0.77, green: 0.26, blue: 0.18, alpha: 1),
            number: NSColor(red: 0.16, green: 0.50, blue: 0.73, alpha: 1),
            comment: NSColor(red: 0.42, green: 0.47, blue: 0.51, alpha: 1),
            property: NSColor(red: 0.11, green: 0.56, blue: 0.73, alpha: 1),
            function: NSColor(red: 0.26, green: 0.45, blue: 0.76, alpha: 1)
        )
        #endif
    }
}

// MARK: - Token Rule

private struct TokenRule {
    let pattern: NSRegularExpression
    let color: (Theme) -> PlatformColor

    init(_ pattern: String, _ color: @escaping (Theme) -> PlatformColor) {
        // swiftlint:disable:next force_try
        self.pattern = try! NSRegularExpression(pattern: pattern)
        self.color = color
    }
}

// MARK: - Grammar definitions

private struct Grammar {
    let rules: [TokenRule]

    static func forLanguage(_ lang: String?) -> Grammar {
        guard let lang = lang?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return generic
        }
        switch lang {
        case "swift":
            return swift
        case "python", "py":
            return python
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return javaScript
        case "json", "jsonc":
            return json
        default:
            return generic
        }
    }

    // MARK: Swift

    static let swift: Grammar = {
        let keywords = [
            "import", "class", "struct", "enum", "protocol", "extension",
            "func", "var", "let", "static", "private", "fileprivate",
            "internal", "public", "open", "override", "mutating",
            "throws", "throw", "rethrows", "async", "await",
            "if", "else", "guard", "switch", "case", "default",
            "for", "while", "repeat", "do", "try", "catch",
            "return", "break", "continue", "fallthrough",
            "where", "in", "is", "as", "self", "Self", "super",
            "init", "deinit", "subscript", "typealias", "associatedtype",
            "weak", "unowned", "lazy", "convenience", "required",
            "some", "any", "nil", "true", "false",
            "defer", "inout", "operator", "precedencegroup",
        ]
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"

        let types = [
            "String", "Int", "Double", "Float", "Bool", "Array",
            "Dictionary", "Set", "Optional", "Result", "Error",
            "Void", "Any", "AnyObject", "Never",
            "URL", "Data", "Date", "UUID",
            "CGFloat", "CGPoint", "CGSize", "CGRect",
            "View", "ObservableObject", "Published", "State",
            "Binding", "Environment", "EnvironmentObject",
        ]
        let typePattern = "\\b(" + types.joined(separator: "|") + ")\\b"

        return Grammar(rules: [
            // Single-line comments
            TokenRule("//[^\\n]*", { $0.comment }),
            // Multi-line comments
            TokenRule("/\\*[\\s\\S]*?\\*/", { $0.comment }),
            // Multi-line strings (triple-quote)
            TokenRule("\"\"\"[\\s\\S]*?\"\"\"", { $0.string }),
            // Double-quoted strings (with escape support)
            TokenRule("\"(?:[^\"\\\\\\n]|\\\\.)*\"", { $0.string }),
            // Keywords
            TokenRule(keywordPattern, { $0.keyword }),
            // @attributes
            TokenRule("@\\w+", { $0.keyword }),
            // #directives
            TokenRule("#\\w+", { $0.keyword }),
            // Known types
            TokenRule(typePattern, { $0.type }),
            // Capitalized identifiers (likely types)
            TokenRule("\\b[A-Z][A-Za-z0-9_]*\\b", { $0.type }),
            // Numbers
            TokenRule("\\b\\d[\\d_]*(\\.[\\d_]+)?([eE][+-]?\\d+)?\\b", { $0.number }),
            TokenRule("\\b0x[\\da-fA-F_]+\\b", { $0.number }),
        ])
    }()

    // MARK: Python

    static let python: Grammar = {
        let keywords = [
            "import", "from", "as", "class", "def", "return",
            "if", "elif", "else", "for", "while", "break",
            "continue", "pass", "try", "except", "finally",
            "raise", "with", "yield", "lambda", "and", "or",
            "not", "in", "is", "True", "False", "None",
            "global", "nonlocal", "del", "assert", "async", "await",
        ]
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"

        let builtins = [
            "print", "len", "range", "int", "str", "float",
            "list", "dict", "set", "tuple", "bool", "type",
            "isinstance", "hasattr", "getattr", "setattr",
            "open", "super", "enumerate", "zip", "map", "filter",
            "sorted", "reversed", "input", "format",
        ]
        let builtinPattern = "\\b(" + builtins.joined(separator: "|") + ")(?=\\s*\\()"

        return Grammar(rules: [
            // Single-line comments
            TokenRule("#[^\\n]*", { $0.comment }),
            // Triple-quoted strings
            TokenRule("(\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?''')", { $0.string }),
            // Strings
            TokenRule("(\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*')", { $0.string }),
            // f-string prefix
            TokenRule("\\b[fFrRbBuU]{1,2}(?=\"|')", { $0.string }),
            // Keywords
            TokenRule(keywordPattern, { $0.keyword }),
            // Decorators
            TokenRule("@\\w+", { $0.keyword }),
            // Builtins
            TokenRule(builtinPattern, { $0.function }),
            // self/cls
            TokenRule("\\bself\\b|\\bcls\\b", { $0.keyword }),
            // Numbers
            TokenRule("\\b\\d[\\d_]*(\\.[\\d_]+)?([eE][+-]?\\d+)?\\b", { $0.number }),
            TokenRule("\\b0[xX][\\da-fA-F_]+\\b", { $0.number }),
            TokenRule("\\b0[oO][0-7_]+\\b", { $0.number }),
            TokenRule("\\b0[bB][01_]+\\b", { $0.number }),
        ])
    }()

    // MARK: JavaScript / TypeScript

    static let javaScript: Grammar = {
        let keywords = [
            "import", "export", "from", "default", "as",
            "function", "class", "extends", "new", "this",
            "const", "let", "var", "return", "if", "else",
            "for", "while", "do", "switch", "case", "break",
            "continue", "throw", "try", "catch", "finally",
            "typeof", "instanceof", "in", "of", "void", "delete",
            "async", "await", "yield", "static", "get", "set",
            "true", "false", "null", "undefined", "NaN", "Infinity",
            // TypeScript
            "type", "interface", "enum", "namespace", "declare",
            "readonly", "keyof", "infer", "extends", "implements",
        ]
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"

        let builtins = [
            "console", "Math", "JSON", "Object", "Array",
            "String", "Number", "Boolean", "Promise", "Map",
            "Set", "RegExp", "Date", "Error", "Symbol",
            "parseInt", "parseFloat", "isNaN", "isFinite",
            "setTimeout", "setInterval", "fetch", "require",
        ]
        let builtinPattern = "\\b(" + builtins.joined(separator: "|") + ")\\b"

        return Grammar(rules: [
            // Single-line comments
            TokenRule("//[^\\n]*", { $0.comment }),
            // Multi-line comments
            TokenRule("/\\*[\\s\\S]*?\\*/", { $0.comment }),
            // Template literals
            TokenRule("`(?:[^`\\\\]|\\\\.)*`", { $0.string }),
            // Strings
            TokenRule("(\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*')", { $0.string }),
            // Keywords
            TokenRule(keywordPattern, { $0.keyword }),
            // Builtins
            TokenRule(builtinPattern, { $0.type }),
            // Capitalized identifiers
            TokenRule("\\b[A-Z][A-Za-z0-9_]*\\b", { $0.type }),
            // Numbers
            TokenRule("\\b\\d[\\d_]*(\\.[\\d_]+)?([eE][+-]?\\d+)?\\b", { $0.number }),
            TokenRule("\\b0[xX][\\da-fA-F]+\\b", { $0.number }),
        ])
    }()

    // MARK: JSON

    static let json: Grammar = {
        return Grammar(rules: [
            // Keys (string followed by colon)
            TokenRule("\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)", { $0.property }),
            // String values
            TokenRule("\"(?:[^\"\\\\]|\\\\.)*\"", { $0.string }),
            // Booleans and null
            TokenRule("\\b(true|false|null)\\b", { $0.keyword }),
            // Numbers
            TokenRule("-?\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", { $0.number }),
        ])
    }()

    // MARK: Generic fallback

    static let generic: Grammar = {
        return Grammar(rules: [
            // Single-line comments (// or #)
            TokenRule("(//|#)[^\\n]*", { $0.comment }),
            // Multi-line comments
            TokenRule("/\\*[\\s\\S]*?\\*/", { $0.comment }),
            // Strings (double or single quoted)
            TokenRule("(\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*')", { $0.string }),
            // Numbers
            TokenRule("\\b\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", { $0.number }),
            // Capitalized identifiers (likely types/classes)
            TokenRule("\\b[A-Z][A-Za-z0-9_]+\\b", { $0.type }),
        ])
    }()
}
