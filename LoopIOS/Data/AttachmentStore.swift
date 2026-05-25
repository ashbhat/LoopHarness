//
//  AttachmentStore.swift
//  Loop
//
//  Persists user-uploaded files (images + PDFs) into the workspace's
//  `attachments/` folder so they ride along with the conversation and sync
//  to iCloud the same way generated images do. Mirrors the atomic-write
//  pattern in `ImageGenerationService.saveImage` — directory ensured up
//  front, bytes written with `Data.write(options: .atomic)`, original
//  filename preserved on the returned `FileAttachment`.
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Vision)
import Vision
#endif

final class AttachmentStore {
    static let shared = AttachmentStore()

    /// Subfolder under the workspace root where user uploads land. Keeping
    /// uploads in a dedicated bucket means future tools (search, cleanup,
    /// "files I sent the assistant") can scan one place.
    private static let folderName = "attachments"

    enum AttachmentError: Error, LocalizedError {
        case writeFailed(String)
        case readSourceFailed(String)
        case unsupportedKind(String)
        case tooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let m):       return "Could not save attachment: \(m)"
            case .readSourceFailed(let m):  return "Could not read source file: \(m)"
            case .unsupportedKind(let m):   return "Unsupported attachment type: \(m)"
            case .tooLarge(let bytes):
                let mb = Double(bytes) / 1024.0 / 1024.0
                return String(format: "File is too large (%.1f MB). Maximum is 20 MB.", mb)
            }
        }
    }

    /// Hard ceiling on user-uploaded file size. Cards are previews only — the
    /// underlying file stays on disk, so we don't need to inline anything huge
    /// to make the UI work. 20 MB is generous for source / markdown / PDFs
    /// while still keeping iCloud sync responsive.
    static let maxFileBytes: Int64 = 20 * 1024 * 1024

    private init() {}

    /// Save raw image bytes. `mime` is one of `image/jpeg`, `image/png`,
    /// `image/heic`, etc. — used to pick the file extension and propagated
    /// onto the returned attachment.
    func saveImage(_ data: Data, suggestedName: String, mime: String) throws -> FileAttachment {
        let ext = Self.fileExtension(forMime: mime, fallback: "jpg")
        return try persist(data,
                           suggestedName: suggestedName,
                           kind: .image,
                           mimeType: mime,
                           preferredExtension: ext)
    }

    /// Save raw PDF bytes.
    func savePDF(_ data: Data, suggestedName: String) throws -> FileAttachment {
        try persist(data,
                    suggestedName: suggestedName,
                    kind: .pdf,
                    mimeType: "application/pdf",
                    preferredExtension: "pdf")
    }

    /// Copy a file off a security-scoped URL (UIDocumentPicker / NSDragging
    /// pasteboard) into the workspace. The source URL is left untouched so
    /// the picker / drag operation can clean it up.
    ///
    /// Size is checked off the filesystem before we load the bytes — bouncing
    /// a 1 GB drop in `Data(contentsOf:)` would balloon memory before we ever
    /// got to validate. Files inside the cap are kinded heuristically by
    /// extension: image / pdf / markdown / text / source-code / generic.
    func saveFromFileURL(_ src: URL) throws -> FileAttachment {
        if let bytes = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize),
           Int64(bytes) > Self.maxFileBytes {
            throw AttachmentError.tooLarge(Int64(bytes))
        }
        let data: Data
        do {
            data = try Data(contentsOf: src)
        } catch {
            throw AttachmentError.readSourceFailed(error.localizedDescription)
        }
        if Int64(data.count) > Self.maxFileBytes {
            throw AttachmentError.tooLarge(Int64(data.count))
        }
        let ext = src.pathExtension.lowercased()
        let mime = Self.mimeType(forExtension: ext)
        let kind: FileAttachment.Kind
        let languageTag: String?
        if ext == "pdf" {
            kind = .pdf
            languageTag = nil
        } else if Self.imageExtensions.contains(ext) {
            kind = .image
            languageTag = nil
        } else if Self.markdownExtensions.contains(ext) {
            kind = .markdown
            languageTag = nil
        } else if let tag = Self.sourceLanguageTag(forExtension: ext) {
            kind = .text
            languageTag = tag
        } else if Self.textExtensions.contains(ext) {
            kind = .text
            languageTag = nil
        } else {
            // Catch-all rather than throwing — the preview card surfaces "we
            // can't render this inline" while still keeping the file around
            // for the assistant to tool-call against if needed.
            kind = .generic
            languageTag = nil
        }
        return try persist(data,
                           suggestedName: src.lastPathComponent,
                           kind: kind,
                           mimeType: mime,
                           preferredExtension: ext.isEmpty ? "bin" : ext,
                           languageTag: languageTag)
    }

    // MARK: - Internals

    private func persist(_ data: Data,
                         suggestedName: String,
                         kind: FileAttachment.Kind,
                         mimeType: String,
                         preferredExtension: String,
                         languageTag: String? = nil) throws -> FileAttachment {
        let id = UUID().uuidString
        let folder = Workspace.shared.rootURL.appendingPathComponent(Self.folderName, isDirectory: true)
        do {
            try Workspace.shared.coordinatedCreateDirectory(at: folder)
        } catch {
            throw AttachmentError.writeFailed("could not create attachments folder: \(error.localizedDescription)")
        }
        let destURL = folder.appendingPathComponent("\(id).\(preferredExtension)")
        do {
            try Workspace.shared.coordinatedWrite(to: destURL) { writeURL in
                try data.write(to: writeURL, options: .atomic)
            }
        } catch {
            throw AttachmentError.writeFailed(error.localizedDescription)
        }

        // Pull text out of the file at attach time so the chat body can
        // carry it inline. Done on the calling thread because attaches are
        // interactive and we want the resulting MessageStruct to ship with
        // text already baked in.
        //
        // PDFs go through PDFKit's per-page `.string` — fast for the small
        // documents typical here. Images run Vision's on-device OCR so
        // screenshots, receipts, and document photos give the assistant
        // something to read even without backend vision support. For "what
        // is this object" style queries on photos with no text, OCR returns
        // nothing and the AI falls back to the bare attachment hint.
        var extracted: String?
        switch kind {
        case .pdf:
            extracted = Self.extractText(fromPDFData: data)
        case .image:
            extracted = Self.extractText(fromImageData: data)
        case .markdown, .text:
            // Markdown and source/text files are already text — decode + trim
            // to the cap so the assistant sees the same prefix as the preview
            // card. Falls back to ISO-Latin-1 for the occasional log file
            // that isn't strict UTF-8.
            extracted = Self.extractText(fromTextData: data)
        case .generic:
            extracted = nil
        }

        return FileAttachment(
            id: id,
            fileURL: destURL,
            fileName: suggestedName.isEmpty ? "\(id).\(preferredExtension)" : suggestedName,
            kind: kind,
            mimeType: mimeType,
            languageTag: languageTag,
            status: .ready,
            extractedText: extracted
        )
    }

    /// Extract concatenated page text from PDF bytes. Returns nil if PDFKit
    /// can't parse the data or the document is empty/image-only.
    private static func extractText(fromPDFData data: Data) -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data) else { return nil }
        var pieces: [String] = []
        let cap = FileAttachment.extractedTextCharCap
        var running = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let pageText = page.string else { continue }
            pieces.append(pageText)
            running += pageText.count
            if running >= cap { break }
        }
        let joined = pieces.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
        #else
        return nil
        #endif
    }

    /// On-device OCR for an image attachment. Returns the recognized text
    /// joined line-by-line, or nil if the image has no text (or Vision
    /// failed to parse the bytes). `.accurate` recognition is slower than
    /// `.fast` but produces meaningfully better output on real-world docs
    /// — and attaches are user-initiated, so an extra ~1s isn't a problem.
    private static func extractText(fromImageData data: Data) -> String? {
        #if canImport(Vision)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("AttachmentStore: Vision OCR failed (\(error))")
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
        #else
        return nil
        #endif
    }

    /// Decode markdown / text / source-code bytes as a string, truncated to
    /// `extractedTextCharCap`. UTF-8 first; ISO-Latin-1 fallback so the
    /// occasional log file with stray non-UTF bytes still surfaces something
    /// useful. Returns nil only if the file is empty after decoding.
    private static func extractText(fromTextData data: Data) -> String? {
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let s = decoded, !s.isEmpty else { return nil }
        let cap = FileAttachment.extractedTextCharCap
        return s.count > cap ? String(s.prefix(cap)) : s
    }

    // MARK: - MIME / extension lookup

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif"
    ]

    /// Mirrors `MarkdownSourceHighlighter.markdownExtensions` but kept private
    /// here so AttachmentStore doesn't reach into the highlighter's internals.
    /// If either list grows, both should be updated together.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"
    ]

    /// Extensions we treat as plain text without a specific language. Source
    /// files with a recognized language go through `sourceLanguageTag` first
    /// and don't show up here. `.csv` and `.tsv` are kept "plain" rather than
    /// trying to render them as a table — the preview card is a snippet, not
    /// a grid, and full table rendering belongs in a tool / dedicated viewer.
    static let textExtensions: Set<String> = [
        "txt", "log", "csv", "tsv", "rtf"
    ]

    /// Recognized source-code extensions and their language identifiers. The
    /// language string is short, lowercase, and meant for display in the
    /// preview-card badge ("SWIFT", "JSON") as well as the assistant hint
    /// ("swift source"). Add entries here when adding new language support.
    private static let sourceExtensionLanguages: [String: String] = [
        "swift": "swift",
        "py": "python", "pyw": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript",
        "jsx": "jsx",
        "tsx": "tsx",
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "html": "html", "htm": "html",
        "css": "css", "scss": "scss",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "m": "objective-c", "mm": "objective-c++",
        "rs": "rust",
        "go": "go",
        "rb": "ruby",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell",
        "kt": "kotlin", "kts": "kotlin",
        "java": "java",
        "sql": "sql",
        "xml": "xml", "plist": "xml",
        "ini": "ini", "conf": "ini", "cfg": "ini", "env": "ini",
        "dockerfile": "dockerfile",
        "lua": "lua",
        "php": "php",
        "r": "r",
        "scala": "scala",
        "dart": "dart",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang",
        "hs": "haskell",
        "ml": "ocaml",
        "clj": "clojure", "cljs": "clojure",
        "vue": "vue",
        "svelte": "svelte",
        "graphql": "graphql", "gql": "graphql",
        "proto": "protobuf",
    ]

    static func sourceLanguageTag(forExtension ext: String) -> String? {
        sourceExtensionLanguages[ext.lowercased()]
    }

    private static func fileExtension(forMime mime: String, fallback: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        #endif
        switch mime.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png":  return "png"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        default: return fallback
        }
    }

    private static func mimeType(forExtension ext: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        #endif
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "heic":        return "image/heic"
        case "heif":        return "image/heif"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "pdf":         return "application/pdf"
        default:            return "application/octet-stream"
        }
    }
}
