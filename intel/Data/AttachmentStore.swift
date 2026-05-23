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

        var errorDescription: String? {
            switch self {
            case .writeFailed(let m):       return "Could not save attachment: \(m)"
            case .readSourceFailed(let m):  return "Could not read source file: \(m)"
            case .unsupportedKind(let m):   return "Unsupported attachment type: \(m)"
            }
        }
    }

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
    func saveFromFileURL(_ src: URL) throws -> FileAttachment {
        let data: Data
        do {
            data = try Data(contentsOf: src)
        } catch {
            throw AttachmentError.readSourceFailed(error.localizedDescription)
        }
        let ext = src.pathExtension.lowercased()
        let mime = Self.mimeType(forExtension: ext)
        let kind: FileAttachment.Kind
        if ext == "pdf" {
            kind = .pdf
        } else if Self.imageExtensions.contains(ext) {
            kind = .image
        } else {
            throw AttachmentError.unsupportedKind(".\(ext)")
        }
        return try persist(data,
                           suggestedName: src.lastPathComponent,
                           kind: kind,
                           mimeType: mime,
                           preferredExtension: ext.isEmpty ? "bin" : ext)
    }

    // MARK: - Internals

    private func persist(_ data: Data,
                         suggestedName: String,
                         kind: FileAttachment.Kind,
                         mimeType: String,
                         preferredExtension: String) throws -> FileAttachment {
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
        }

        return FileAttachment(
            id: id,
            fileURL: destURL,
            fileName: suggestedName.isEmpty ? "\(id).\(preferredExtension)" : suggestedName,
            kind: kind,
            mimeType: mimeType,
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

    // MARK: - MIME / extension lookup

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif"
    ]

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
