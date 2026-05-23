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
    static func urlForFilename(_ filename: String) -> URL? {
        return inboxDirectory()?.appendingPathComponent(filename)
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
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
