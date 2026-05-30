//
//  SSHTerminalAccessoryView.swift
//  Loop
//
//  Redesigned terminal accessory bar ("Direction A" toolbar). Replaces
//  SwiftTerm's default cramped key row with: a command-palette button pinned
//  left, then a horizontally-scrollable strip of comfortably-sized keys
//  (esc / ctrl / tab · arrows · ~ / | -) with a right-edge fade hinting at more.
//
//  Used as the TerminalView's `inputAccessoryView`. Keys send bytes straight to
//  the terminal via the public `send([UInt8])`; `ctrl` toggles the view's public
//  `controlModifier`, which SwiftTerm applies to the next typed character
//  (so Ctrl-C etc. work with the system keyboard). We listen for SwiftTerm's
//  control-reset notification to un-highlight the ctrl key after it fires.
//
//  iOS-only (UIKit + SwiftTerm); excluded from the Mac/Vision targets.
//

import UIKit
import SwiftTerm

final class SSHTerminalAccessoryView: UIView {

    weak var terminalView: TerminalView?
    var onPalette: (() -> Void)?

    private var theme: TerminalTheme
    private let barHeight: CGFloat = 58

    private var paletteButton: UIButton!
    private var ctrlButton: UIButton!
    private let scrollView = UIScrollView()
    private let keyStack = UIStackView()
    private let fade = CAGradientLayer()
    private let topBorder = CALayer()

    init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 58))
        autoresizingMask = .flexibleWidth
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(controlReset),
            name: Notification.Name("SwiftTerm.TerminalView.controlModifierReset"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    // MARK: - Build

    private func build() {
        backgroundColor = theme.panel

        topBorder.backgroundColor = theme.line.cgColor
        layer.addSublayer(topBorder)

        // Command-palette trigger (pinned, accent fill).
        paletteButton = UIButton(type: .system)
        paletteButton.backgroundColor = theme.accent
        paletteButton.tintColor = theme.onAccent
        paletteButton.layer.cornerRadius = 10
        paletteButton.setImage(UIImage(systemName: "command",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        paletteButton.translatesAutoresizingMaskIntoConstraints = false
        paletteButton.addTarget(self, action: #selector(paletteTapped), for: .touchUpInside)
        addSubview(paletteButton)

        // Scrollable key strip.
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        keyStack.axis = .horizontal
        keyStack.spacing = 7
        keyStack.alignment = .center
        keyStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(keyStack)

        buildKeys()

        // Right-edge fade hint.
        fade.colors = [theme.panel.withAlphaComponent(0).cgColor, theme.panel.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(fade)

        NSLayoutConstraint.activate([
            paletteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            paletteButton.centerYAnchor.constraint(equalTo: topAnchor, constant: 9 + 20),
            paletteButton.widthAnchor.constraint(equalToConstant: 48),
            paletteButton.heightAnchor.constraint(equalToConstant: 40),

            scrollView.leadingAnchor.constraint(equalTo: paletteButton.trailingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: barHeight),

            keyStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            keyStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -26),
            keyStack.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
        ])
    }

    private func buildKeys() {
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        keyStack.addArrangedSubview(textKey("esc") { [weak self] in self?.send([0x1b]) })
        ctrlButton = textKey("ctrl") { [weak self] in self?.toggleControl() }
        keyStack.addArrangedSubview(ctrlButton)
        keyStack.addArrangedSubview(textKey("tab") { [weak self] in self?.send([0x09]) })
        keyStack.addArrangedSubview(separator())
        keyStack.addArrangedSubview(iconKey("arrow.left") { [weak self] in self?.send([0x1b, 0x5b, 0x44]) })
        keyStack.addArrangedSubview(iconKey("arrow.down") { [weak self] in self?.send([0x1b, 0x5b, 0x42]) })
        keyStack.addArrangedSubview(iconKey("arrow.up") { [weak self] in self?.send([0x1b, 0x5b, 0x41]) })
        keyStack.addArrangedSubview(iconKey("arrow.right") { [weak self] in self?.send([0x1b, 0x5b, 0x43]) })
        keyStack.addArrangedSubview(separator())
        for sym in ["~", "/", "|", "-"] {
            keyStack.addArrangedSubview(textKey(sym) { [weak self] in self?.send(Array(sym.utf8)) })
        }
    }

    // MARK: - Key factories

    private func keyBase(width: CGFloat) -> KeyButton {
        let b = KeyButton(type: .system)
        b.backgroundColor = theme.keyBg
        b.layer.cornerRadius = 10
        b.layer.borderWidth = 0.5
        b.layer.borderColor = theme.keyEdge.cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return b
    }

    private func textKey(_ title: String, action: @escaping () -> Void) -> KeyButton {
        // Roomy min width (the design uses generous horizontal padding); short
        // labels stay comfortably centered without relying on contentEdgeInsets.
        let b = keyBase(width: 52)
        b.setTitle(title, for: .normal)
        b.setTitleColor(theme.keyFg, for: .normal)
        b.titleLabel?.font = UIFont(name: "Menlo", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .semibold)
        b.onTap = action
        b.addTarget(b, action: #selector(KeyButton.fire), for: .touchUpInside)
        return b
    }

    private func iconKey(_ symbol: String, action: @escaping () -> Void) -> KeyButton {
        let b = keyBase(width: 44)
        b.setImage(UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        b.tintColor = theme.keyFg
        b.onTap = action
        b.addTarget(b, action: #selector(KeyButton.fire), for: .touchUpInside)
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = theme.line
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }

    // MARK: - Actions

    private func send(_ bytes: [UInt8]) {
        terminalView?.send(bytes)
    }

    private func toggleControl() {
        guard let tv = terminalView else { return }
        tv.controlModifier.toggle()
        setCtrlActive(tv.controlModifier)
    }

    @objc private func controlReset() {
        setCtrlActive(false)
    }

    private func setCtrlActive(_ active: Bool) {
        ctrlButton.backgroundColor = active ? theme.accent : theme.keyBg
        ctrlButton.setTitleColor(active ? theme.onAccent : theme.keyFg, for: .normal)
    }

    @objc private func paletteTapped() {
        onPalette?()
    }

    // MARK: - Theming

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = theme.panel
        topBorder.backgroundColor = theme.line.cgColor
        paletteButton.backgroundColor = theme.accent
        paletteButton.tintColor = theme.onAccent
        fade.colors = [theme.panel.withAlphaComponent(0).cgColor, theme.panel.cgColor]
        buildKeys()
        setCtrlActive(terminalView?.controlModifier ?? false)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        topBorder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
        fade.frame = CGRect(x: bounds.width - 30, y: 0, width: 30, height: barHeight)
    }
}

/// Button that fires a stored closure and gives a brief press dim.
private final class KeyButton: UIButton {
    var onTap: (() -> Void)?
    @objc func fire() { onTap?() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.55 : 1 }
    }
}
