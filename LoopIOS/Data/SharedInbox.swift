//
//  SharedInbox.swift
//  Loop
//
//  App Group inbox for the share-extension hand-off. The iOS and Mac share
//  extensions write incoming images here; the main apps drain it on the next
//  URL handoff or foreground-enter and stage the bytes on the message bar.
//
//  Using an App Group container (not the extension's own sandbox) is what
//  lets the main app actually find the bytes — share extensions can't write
//  into the host app's directly.
//

import Foundation

enum SharedInbox {

    /// App Group identifier. Must be present in the entitlements file of
    /// every target that needs to read or write this directory (main app,
    /// share extension).
    static let appGroup = "group.com.bhat.intel"

    /// Resolves the App Group container's `Inbox/` subdirectory, creating it
    /// if needed. Returns nil if the group isn't configured for this target —
    /// callers fall back to their own caches in that case.
    static func inboxDirectory() -> URL? {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        if !fm.fileExists(atPath: inbox.path) {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
    }

    /// Writes `data` into the inbox under a fresh UUID-derived filename and
    /// returns just the filename — callers re-resolve via `urlForFilename(_:)`
    /// to keep the path opaque across the URL-scheme hop into the main app.
    @discardableResult
    static func writeImage(_ data: Data, suggestedExtension ext: String) throws -> String {
        guard let dir = inboxDirectory() else {
            throw NSError(domain: "SharedInbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group not configured"])
        }
        let safeExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let filename = "\(UUID().uuidString).\(safeExt.isEmpty ? "bin" : safeExt)"
        let target = dir.appendingPathComponent(filename)
        try data.write(to: target, options: [.atomic])
        return filename
    }

    /// Resolves a previously-returned filename back to its full URL. Used by
    /// the main app's URL handler so callers don't have to know about the
    /// App Group path layout.
    ///
    /// Strictly validates the filename: it must match the `<uuid>.<ext>` shape
    /// `writeImage` produces. Without this gate, the `commandintel://share?file=`
    /// URL scheme would let any installed app pass `..`/`/` segments and reach
    /// arbitrary files Loop can read (notably the iCloud workspace at the
    /// deterministic `iCloud~com~bhat~intel/Documents/` path) — they'd be
    /// copied into `workspace/attachments/`, deleted at their original
    /// location via `remove(_:)`, and queued for the next outgoing chat turn.
    /// `URL.appendingPathComponent` doesn't percent-encode `/` so the
    /// traversal would otherwise resolve normally. After resolving, we also
    /// assert the path stays inside `inboxDirectory()` as belt-and-suspenders
    /// against future encoding quirks.
    static func urlForFilename(_ filename: String) -> URL? {
        guard isValidInboxFilename(filename),
              let dir = inboxDirectory() else { return nil }
        let candidate = dir.appendingPathComponent(filename).standardizedFileURL
        let dirPath = dir.standardizedFileURL.path
        guard candidate.path.hasPrefix(dirPath + "/") else { return nil }
        return candidate
    }

    /// Allowlist for filenames the share-extension hand-off can name. Matches
    /// `<UUID>.<1-8 alnum>` — the exact shape `writeImage` emits. Anything
    /// else (path separators, `..` segments, empty, oversize extension) is
    /// rejected before it can reach a file-read or file-delete site.
    private static let inboxFilenamePattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\.[A-Za-z0-9]{1,8}$"#
        )
    }()

    static func isValidInboxFilename(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..., in: filename)
        return Self.inboxFilenamePattern.firstMatch(in: filename, range: range) != nil
    }

    /// Every file currently sitting in the inbox, sorted oldest-first.
    /// `drain(_:)` calls this and removes each entry after the caller has
    /// successfully copied it elsewhere.
    static func listPending() -> [URL] {
        guard let dir = inboxDirectory() else { return [] }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])
        else { return [] }
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Hand each pending file to `handler` and only delete the source once
    /// the handler signals success. Pickup-on-foreground uses this so a
    /// crash mid-stage doesn't lose the user's shared image.
    static func drain(_ handler: (URL) -> Bool) {
        for url in listPending() {
            let ok = handler(url)
            if ok {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Remove a single file by URL. Used by the URL-handoff path which
    /// processes one specific filename rather than draining the whole inbox.
    ///
    /// Re-validates that `url` actually lives inside the inbox before
    /// deleting. `urlForFilename` already gates resolution, but `remove` is
    /// reachable from any caller that holds a URL — independently guarding
    /// here means a future code path that resolves a URL differently can't
    /// accidentally hand us an arbitrary file to delete.
    static func remove(_ url: URL) {
        guard let dir = inboxDirectory() else { return }
        let dirPath = dir.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(dirPath + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
