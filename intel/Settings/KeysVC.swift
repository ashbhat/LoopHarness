//
//  KeysVC.swift
//  Loop
//
//  Lists every third-party service the app integrates with — one row per
//  `KeyStore.Service`, not per raw key. Each row shows the service's name,
//  a one-line summary, and a ✓ if the service's primary key is set. Tapping a
//  row pushes the editor, which stacks one input per key the service exposes
//  (e.g. GitHub: PAT + optional API base URL).
//

import UIKit

final class KeysVC: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let services: [KeyStore.Service] = KeyStore.Service.allCases

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Keys"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(KeyRowCell.self, forCellReuseIdentifier: "service")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyStoreDidChange),
            name: KeyStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func keyStoreDidChange() {
        tableView.reloadData()
    }
}

extension KeysVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return services.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "service", for: indexPath) as! KeyRowCell
        let service = services[indexPath.row]
        cell.configure(
            title: service.displayName,
            subtitle: service.summary,
            preview: KeyStore.shared.maskedPreview(for: service.primaryKey),
            isSet: KeyStore.shared.source(for: service.primaryKey) != .missing
        )
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let service = services[indexPath.row]
        navigationController?.pushViewController(KeyEditVC(service: service), animated: true)
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "Keys are stored securely in the iOS Keychain on this device. They are never synced or sent to Loop's servers."
    }
}

/// Two-line cell with a masked value on the trailing edge. We can't use the
/// stock `.value1` cell here because we want the preview to wrap visually
/// distinct from the subtitle and to be in monospace.
private final class KeyRowCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let previewLabel = UILabel()
    /// Green checkmark shown only when the service's primary key has an
    /// effective value. Hidden (not removed) when unset so the row's preview
    /// column stays aligned.
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2

        previewLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        previewLabel.textColor = .secondaryLabel
        previewLabel.textAlignment = .right
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.setContentHuggingPriority(.required, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        checkmark.tintColor = .systemGreen
        checkmark.contentMode = .scaleAspectFit
        checkmark.setContentHuggingPriority(.required, for: .horizontal)
        checkmark.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            checkmark.widthAnchor.constraint(equalToConstant: 18),
            checkmark.heightAnchor.constraint(equalToConstant: 18),
        ])

        let row = UIStackView(arrangedSubviews: [textStack, previewLabel, checkmark])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, preview: String, isSet: Bool) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        previewLabel.text = preview
        checkmark.isHidden = !isSet
    }
}
