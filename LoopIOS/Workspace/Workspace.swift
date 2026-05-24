//
//  Workspace.swift
//  Loop
//
//  Built from LoopIOS/Specs/file_system_spec.md.
//
//  The agent's persistent file system. Resolves the workspace root once, prefers
//  the iCloud Drive ubiquity container so the user can browse/edit files in the
//  Files app and changes sync across devices, and falls back to a local
//  Documents/Workspace folder when iCloud isn't available (simulator without
//  iCloud signed in, missing entitlements, etc.).
//
//  Owns path resolution + sandboxing — every read/write goes through resolve(_:)
//  which rejects traversal and absolute paths.
//

import Foundation

final class Workspace {
    static let shared = Workspace()

    /// iCloud container identifier. Must match the value declared in
    /// LoopIOS.entitlements and in NSUbiquitousContainers in Info.plist.
    static let containerIdentifier = "iCloud.com.bhat.intel"

    /// Subfolder of the Documents directory that the user sees in the Files app.
    /// Living under Documents/ is required for NSUbiquitousContainerIsDocumentScopePublic.
    private static let workspaceFolderName = "Workspace"

    /// Hard cap on per-file read/write size to keep the agent from blowing up
    /// the chat context with a runaway file. Spec §Safety Constraints.
    static let maxFileBytes = 1_048_576

    enum Backend {
        case iCloud
        case local
    }

    let backend: Backend
    let rootURL: URL

    enum WorkspaceError: Error, LocalizedError {
        case invalidPath(String)
        case pathEscapesRoot(String)
        case fileTooLarge(Int)
        case downloadFailed(String)
        case notFound(String)
        case notAFile(String)
        case notADirectory(String)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let p):     return "Invalid path '\(p)' — paths must be relative and may not contain '..'"
            case .pathEscapesRoot(let m): return "Path resolution failed: \(m)"
            case .fileTooLarge(let n):    return "File is \(n) bytes — over the \(Workspace.maxFileBytes)-byte cap"
            case .downloadFailed(let m):  return "iCloud download failed: \(m)"
            case .notFound(let p):        return "No such file or directory: \(p)"
            case .notAFile(let p):        return "Not a file: \(p)"
            case .notADirectory(let p):   return "Not a directory: \(p)"
            case .ioError(let m):         return m
            }
        }
    }

    private init() {
        let fm = FileManager.default

        // Try iCloud first. forUbiquityContainerIdentifier blocks briefly the
        // first time it's called (Apple recommends doing it off the main thread
        // but the singleton bootstraps once at app launch — acceptable here).
        if let ubiquity = fm.url(forUbiquityContainerIdentifier: Workspace.containerIdentifier) {
            let docs = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            if Workspace.ensureDirectory(docs) {
                self.backend = .iCloud
                self.rootURL = docs
                Workspace.migrateLegacySelfDocsIfNeeded(into: docs)
                print("Workspace: using iCloud container at \(docs.path)")
                return
            }
        }

        // Local fallback. We still prefer the user's Documents directory so the
        // files are visible if they ever wire up iCloud later.
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let local = docs.appendingPathComponent(Workspace.workspaceFolderName, isDirectory: true)
        _ = Workspace.ensureDirectory(local)
        self.backend = .local
        self.rootURL = local
        Workspace.migrateLegacySelfDocsIfNeeded(into: local)
        print("Workspace: iCloud unavailable — using local fallback at \(local.path)")
    }

    // MARK: - Path resolution

    /// Resolve a relative path to an absolute URL inside the workspace, or
    /// throw if it tries to escape. Empty / "." / "/" all resolve to root.
    func resolve(_ relativePath: String) throws -> URL {
        var p = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow leading "/" for ergonomics — strip it; everything is relative.
        while p.hasPrefix("/") { p.removeFirst() }
        if p.isEmpty || p == "." { return rootURL }

        let components = p.split(separator: "/", omittingEmptySubsequences: true)
        for c in components {
            if c == ".." || c == "." {
                throw WorkspaceError.invalidPath(relativePath)
            }
        }

        // Append components one at a time. On iOS 16+, passing a string with
        // embedded slashes to URL.appendingPathComponent(_:) percent-encodes
        // them rather than splitting on them, which breaks the safety check
        // below and yields the wrong target URL.
        var resolved = rootURL
        for c in components {
            resolved.appendPathComponent(String(c))
        }

        // Belt-and-braces: confirm the resolved URL is actually under root.
        // We built `resolved` by appending vetted components to rootURL, so
        // this is mostly defense-in-depth. Compare raw .path strings — going
        // through standardizedFileURL on iOS strips the `/private` prefix
        // unpredictably and breaks the comparison.
        let rootPath = rootURL.path
        let resolvedPath = resolved.path
        if resolvedPath != rootPath && !resolvedPath.hasPrefix(rootPath + "/") {
            print("Workspace.resolve: safety check failed — input=\(relativePath) root=\(rootPath) resolved=\(resolvedPath)")
            throw WorkspaceError.pathEscapesRoot(
                "'\(relativePath)' resolved to \(resolvedPath) which is not under \(rootPath)"
            )
        }
        return resolved
    }

    /// Convert an absolute file URL back to its workspace-relative path.
    /// Returns "" for the root.
    func relativePath(of url: URL) -> String {
        let rootStd = rootURL.standardizedFileURL.path
        let urlStd = url.standardizedFileURL.path
        if urlStd == rootStd { return "" }
        if urlStd.hasPrefix(rootStd + "/") {
            return String(urlStd.dropFirst(rootStd.count + 1))
        }
        return urlStd
    }

    // MARK: - iCloud sync helpers

    /// Block (briefly) until an iCloud-evicted file is downloaded. Local
    /// backend or already-present files return immediately.
    func ensureDownloaded(_ url: URL, timeout: TimeInterval = 10) throws {
        guard backend == .iCloud else { return }

        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey
        ])
        let status = values?.ubiquitousItemDownloadingStatus
        if status == .current { return }
        guard (values?.isUbiquitousItem ?? false) else { return }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw WorkspaceError.downloadFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw WorkspaceError.downloadFailed("timed out waiting for iCloud download")
    }

    // MARK: - Coordinated I/O

    // iOS rejects bare FileManager writes into the iCloud ubiquity container
    // when the destination file doesn't already exist — the create has to go
    // through NSFileCoordinator so the iCloud daemon can register the new
    // fileID. macOS without sandboxing is more permissive, which is why this
    // only manifests on iOS. Helpers below no-op the coordination on the
    // local backend.

    /// Perform `write` on `url` under file coordination when on iCloud. The
    /// closure receives the URL the coordinator hands back (which may differ
    /// from the input in rare cases) and must do the actual write to it.
    func coordinatedWrite(to url: URL, _ write: (URL) throws -> Void) throws {
        if backend != .iCloud {
            try write(url)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            do {
                try write(writeURL)
            } catch {
                innerError = error
            }
        }
        if let inner = innerError { throw Self.ioError(from: inner) }
        if let coordError = coordError { throw Self.ioError(from: coordError) }
    }

    /// Coordinated `moveItem`. Uses the two-URL variant so iCloud sees the
    /// rename atomically.
    func coordinatedMove(from src: URL, to dst: URL) throws {
        if backend != .iCloud {
            try FileManager.default.moveItem(at: src, to: dst)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(writingItemAt: src, options: [.forMoving],
                               writingItemAt: dst, options: [.forReplacing],
                               error: &coordError) { srcURL, dstURL in
            do {
                try FileManager.default.moveItem(at: srcURL, to: dstURL)
            } catch {
                innerError = error
            }
        }
        if let inner = innerError { throw Self.ioError(from: inner) }
        if let coordError = coordError { throw Self.ioError(from: coordError) }
    }

    /// Coordinated `removeItem`.
    func coordinatedRemove(_ url: URL) throws {
        if backend != .iCloud {
            try FileManager.default.removeItem(at: url)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { deleteURL in
            do {
                try FileManager.default.removeItem(at: deleteURL)
            } catch {
                innerError = error
            }
        }
        if let inner = innerError { throw Self.ioError(from: inner) }
        if let coordError = coordError { throw Self.ioError(from: coordError) }
    }

    /// Coordinated `createDirectory(withIntermediateDirectories: true)`.
    /// Short-circuits if the directory already exists.
    func coordinatedCreateDirectory(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        if backend != .iCloud {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var innerError: Error?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { dirURL in
            do {
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            } catch {
                innerError = error
            }
        }
        if let inner = innerError { throw Self.ioError(from: inner) }
        if let coordError = coordError { throw Self.ioError(from: coordError) }
    }

    /// Wrap an underlying error into a WorkspaceError.ioError with the NSError
    /// domain + code preserved in the message so it surfaces in tool results.
    private static func ioError(from error: Error) -> WorkspaceError {
        let ns = error as NSError
        return .ioError("\(ns.localizedDescription) [\(ns.domain) \(ns.code)]")
    }

    // MARK: - Helpers

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            print("Workspace: failed to create \(url.path): \(error)")
            return false
        }
    }

    /// One-shot migration from the SelfImprovementSkill v1 location
    /// (Documents/loop_self/<lower>.md) to the canonical workspace location
    /// (<root>/<UPPER>.md). Skips if a destination file already exists.
    private static func migrateLegacySelfDocsIfNeeded(into destination: URL) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let legacy = docs.appendingPathComponent("loop_self", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }

        let names = ["soul", "user", "memory", "agents", "heartbeat"]
        for name in names {
            let src = legacy.appendingPathComponent("\(name).md")
            let dst = destination.appendingPathComponent("\(name.uppercased()).md")
            guard fm.fileExists(atPath: src.path),
                  !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
                print("Workspace: migrated \(src.lastPathComponent) → \(dst.lastPathComponent)")
            } catch {
                print("Workspace: migration of \(src.lastPathComponent) failed: \(error)")
            }
        }
    }
}
