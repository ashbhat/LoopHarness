import Foundation

/// Converts a filesystem-path substring into a `(displayName, url)` pair
/// the chat UI can render as a tappable link. Vault-relative paths become
/// `obsidian://open?vault=…&file=…` URLs when an Obsidian vault name is
/// configured; everything else falls back to a plain `file://` URL so the
/// system handler can preview/open it.
///
/// Detection regex is shared with `SpeechSanitizer.filePathPattern` so the
/// TTS-stripping pass and the UI-linkifying pass agree on what counts as
/// a path.
enum FilePathLinkifier {

    static var pattern: String { SpeechSanitizer.filePathPattern }

    struct Resolved {
        let displayName: String
        let url: URL
    }

    static func resolve(_ rawPath: String) -> Resolved? {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard let name = path.split(separator: "/").last.map(String.init), !name.isEmpty else {
            return nil
        }

        if path.hasPrefix(OBSIDIAN_VAULT_ROOT + "/"),
           let vault = KeyStore.shared.value(for: .obsidianVaultName)?
                       .trimmingCharacters(in: .whitespaces),
           !vault.isEmpty,
           let v = vault.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let f = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?vault=\(v)&file=\(f)") {
            return Resolved(displayName: name, url: url)
        }

        let expanded = path.hasPrefix("~/")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
            : path
        guard let encoded = expanded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "file://\(encoded)") else {
            return nil
        }
        return Resolved(displayName: name, url: url)
    }
}
