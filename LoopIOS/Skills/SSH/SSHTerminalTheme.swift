//
//  SSHTerminalTheme.swift
//  Loop
//
//  Color + type tokens for the redesigned mobile terminal ("Direction A —
//  Refined Terminal" from the Claude Design handoff). Two themes, light + dark,
//  matching the design's `tokens()`. `apply(to:)` pushes the relevant tokens
//  into SwiftTerm: font, background/foreground, caret, selection, and a
//  functional 16-color ANSI palette (identity green, paths/links blue,
//  warnings amber, errors red) so real server output renders in the design's
//  palette.
//
//  iOS-only (UIKit + SwiftTerm); excluded from the Mac/Vision targets.
//

import UIKit
import SwiftTerm

struct TerminalTheme {

    let isDark: Bool

    // Chrome / UI surfaces
    let background: UIColor
    let panel: UIColor
    let panel2: UIColor
    let line: UIColor
    let fg: UIColor
    let bright: UIColor
    let dim: UIColor
    let faint: UIColor
    let green: UIColor
    let blue: UIColor
    let amber: UIColor
    let red: UIColor
    let accent: UIColor
    let keyBg: UIColor
    let keyFg: UIColor
    let keyEdge: UIColor

    // Extra ANSI hues not called out in the design tokens.
    let magenta: UIColor
    let cyan: UIColor

    /// On-accent foreground (text/icons drawn on the accent fill).
    var onAccent: UIColor { isDark ? Self.hex(0x06140A) : .white }

    // MARK: - Presets (mirror tokens() in terminal-kit.jsx)

    static let dark = TerminalTheme(
        isDark: true,
        background: hex(0x0C0E12), panel: hex(0x14171D), panel2: hex(0x1B1F27),
        line: UIColor(white: 1, alpha: 0.08),
        fg: hex(0xCDD3DC), bright: hex(0xF2F5F9), dim: hex(0x697283), faint: hex(0x454C59),
        green: hex(0x4BB85C), blue: hex(0x5BA7FF), amber: hex(0xE0A33A), red: hex(0xF0625A),
        accent: hex(0x4BB85C),
        keyBg: UIColor(white: 1, alpha: 0.07), keyFg: hex(0xC3C9D2), keyEdge: UIColor(white: 1, alpha: 0.05),
        magenta: hex(0xB57BE0), cyan: hex(0x4FB6C7))

    static let light = TerminalTheme(
        isDark: false,
        background: hex(0xFBFBFA), panel: hex(0xFFFFFF), panel2: hex(0xF4F5F3),
        line: UIColor(red: 20/255, green: 22/255, blue: 28/255, alpha: 0.10),
        fg: hex(0x232730), bright: hex(0x0E1116), dim: hex(0x6B7382), faint: hex(0xA3AAB6),
        green: hex(0x1A7F37), blue: hex(0x0B69D4), amber: hex(0x9A6700), red: hex(0xCF222E),
        accent: hex(0x1A7F37),
        keyBg: UIColor(red: 20/255, green: 22/255, blue: 28/255, alpha: 0.05),
        keyFg: hex(0x414855),
        keyEdge: UIColor(red: 20/255, green: 22/255, blue: 28/255, alpha: 0.06),
        magenta: hex(0x8250DF), cyan: hex(0x0E7490))

    static func current(for traits: UITraitCollection) -> TerminalTheme {
        traits.userInterfaceStyle == .light ? .light : .dark
    }

    // MARK: - Apply to SwiftTerm

    func apply(to terminalView: TerminalView) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = background
        terminalView.nativeForegroundColor = fg
        terminalView.caretColor = accent
        terminalView.selectedTextBackgroundColor =
            (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.18)
        terminalView.installColors(ansiPalette())
        terminalView.backgroundColor = background
    }

    /// 16-entry ANSI palette: indices 0–7 normal, 8–15 bright. The grays are
    /// lifted (faint→dim→fg→bright) so dimmed boilerplate and emphasis both read.
    private func ansiPalette() -> [SwiftTerm.Color] {
        let normal: [UIColor] = [faint, red, green, amber, blue, magenta, cyan, fg]
        let brights: [UIColor] = [dim, red, green, amber, blue, magenta, cyan, bright]
        return (normal + brights).map { $0.swiftTermColor }
    }

    // MARK: - Hex helper

    static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

extension UIColor {
    /// Converts to SwiftTerm's 16-bit-per-channel color.
    var swiftTermColor: SwiftTerm.Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func chan(_ x: CGFloat) -> UInt16 { UInt16(max(0, min(1, x)) * 65535) }
        return SwiftTerm.Color(red: chan(r), green: chan(g), blue: chan(b))
    }
}
