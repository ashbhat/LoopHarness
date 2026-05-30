//
//  SSHCommandPaletteViewController.swift
//  Loop
//
//  Command palette sheet for the redesigned terminal ("Direction A"). Slides up
//  over the toolbar as a bottom sheet: a search field, then grouped actions —
//  Suggested (reconnect / clear / scroll-to-latest) and Saved commands. Picking
//  a row dismisses and reports the chosen action to the terminal screen.
//
//  iOS-only (UIKit); excluded from the Mac/Vision targets.
//

import UIKit

struct PaletteItem {
    enum Action {
        case reconnect
        case clear
        case scrollToLatest
        case runCommand(String)
    }
    enum Tone { case accent, fg, green }

    let glyph: String
    let title: String
    let meta: String
    let tone: Tone
    let action: Action
}

final class SSHCommandPaletteViewController: UIViewController {

    var onSelect: ((PaletteItem.Action) -> Void)?

    private let theme: TerminalTheme
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let searchField = UITextField()

    private let groups: [(title: String, items: [PaletteItem])] = [
        ("Suggested", [
            PaletteItem(glyph: "↻", title: "Reconnect session", meta: "", tone: .accent, action: .reconnect),
            PaletteItem(glyph: "⌫", title: "Clear screen", meta: "clear", tone: .fg, action: .clear),
            PaletteItem(glyph: "⤓", title: "Scroll to latest", meta: "G", tone: .fg, action: .scrollToLatest),
        ]),
        ("Saved commands", [
            PaletteItem(glyph: "$", title: "apt update && apt upgrade", meta: "updates", tone: .green, action: .runCommand("apt update && apt upgrade")),
            PaletteItem(glyph: "$", title: "htop", meta: "monitor", tone: .green, action: .runCommand("htop")),
            PaletteItem(glyph: "$", title: "tail -f /var/log/syslog", meta: "logs", tone: .green, action: .runCommand("tail -f /var/log/syslog")),
            PaletteItem(glyph: "$", title: "systemctl status nginx", meta: "service", tone: .green, action: .runCommand("systemctl status nginx")),
        ]),
    ]

    /// Groups after applying the current search filter.
    private var filtered: [(title: String, items: [PaletteItem])] = []

    init(theme: TerminalTheme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
        filtered = groups
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.panel
        setupSearch()
        setupTable()

        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 22
        }
    }

    private func setupSearch() {
        let container = UIView()
        container.backgroundColor = theme.panel2
        container.layer.cornerRadius = 11
        container.layer.borderWidth = 0.5
        container.layer.borderColor = theme.line.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.tintColor = theme.dim
        glass.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = "Search commands…"
        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = theme.bright
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .go
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.addTarget(self, action: #selector(searchSubmit), for: .editingDidEndOnExit)

        container.addSubview(glass)
        container.addSubview(searchField)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            container.heightAnchor.constraint(equalToConstant: 40),

            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            glass.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 15),
            glass.heightAnchor.constraint(equalToConstant: 15),

            searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 9),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        self.searchContainer = container
    }

    private var searchContainer: UIView!

    private func setupTable() {
        tableView.backgroundColor = theme.panel
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(PaletteCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 6),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Search

    @objc private func searchChanged() {
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = groups
        } else {
            filtered = groups.compactMap { group in
                let items = group.items.filter { $0.title.lowercased().contains(q) }
                return items.isEmpty ? nil : (group.title, items)
            }
        }
        tableView.reloadData()
    }

    /// Enter in the search field runs whatever was typed as a literal command.
    @objc private func searchSubmit() {
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        finish(.runCommand(q))
    }

    private func finish(_ action: PaletteItem.Action) {
        dismiss(animated: true) { [weak self] in self?.onSelect?(action) }
    }
}

// MARK: - Table data

extension SSHCommandPaletteViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { filtered.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filtered[section].items.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let label = UILabel()
        label.text = filtered[section].title.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = theme.dim
        let container = UIView()
        container.backgroundColor = theme.panel
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 32 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 46 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! PaletteCell
        cell.configure(with: filtered[indexPath.section].items[indexPath.row], theme: theme)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        finish(filtered[indexPath.section].items[indexPath.row].action)
    }
}

// MARK: - Cell

private final class PaletteCell: UITableViewCell {
    private let glyphBox = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default

        glyphBox.textAlignment = .center
        glyphBox.font = UIFont(name: "Menlo", size: 15) ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        glyphBox.layer.cornerRadius = 8
        glyphBox.layer.borderWidth = 0.5
        glyphBox.clipsToBounds = true
        glyphBox.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        contentView.addSubview(glyphBox)
        contentView.addSubview(titleLabel)
        contentView.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            glyphBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            glyphBox.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            glyphBox.widthAnchor.constraint(equalToConstant: 30),
            glyphBox.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.leadingAnchor.constraint(equalTo: glyphBox.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            metaLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            metaLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: PaletteItem, theme: TerminalTheme) {
        let tone: UIColor
        switch item.tone {
        case .accent: tone = theme.accent
        case .green: tone = theme.green
        case .fg: tone = theme.fg
        }
        glyphBox.text = item.glyph
        glyphBox.textColor = tone
        glyphBox.backgroundColor = theme.panel2
        glyphBox.layer.borderColor = theme.line.cgColor

        let mono = item.tone == .green
        titleLabel.text = item.title
        titleLabel.textColor = theme.bright
        titleLabel.font = mono
            ? (UIFont(name: "Menlo", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
            : .systemFont(ofSize: 14, weight: .semibold)

        metaLabel.text = item.meta
        metaLabel.textColor = theme.dim

        let bg = UIView()
        bg.backgroundColor = theme.panel2
        selectedBackgroundView = bg
    }
}
