//
//  PDFGenerationService.swift
//  Loop
//
//  Built from LoopIOS/pdf_spec.md.
//
//  Owns the WKWebView → PDF render pipeline so PDFSkill stays a thin tool
//  wrapper. Render is fully local (no network), so the surface is simpler
//  than ImageGenerationService — no API keys, no background-task budget,
//  no retry on transient failures. The only async waits are layout +
//  font-loading inside the offscreen WKWebView.
//
//  Why a dedicated service:
//  - WKWebView must live on the main thread, and its delegate callbacks
//    are async. Pulling that into the skill would bury the lifecycle.
//  - Multiple concurrent renders need isolated WKWebView instances so one
//    job's didFinish doesn't trigger another job's PDF capture.
//  - PDFKit thumbnail generation can spike CPU; we hop off main to render
//    the page-1 thumbnail PNG, then come back to notify the host.
//

import Foundation
import WebKit
import PDFKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class PDFGenerationService: NSObject {
    static let shared = PDFGenerationService()

    /// Notified on start/finish. Set by MessagingVC (iOS) and
    /// ConversationWindowController (Mac); nil on visionOS.
    weak var host: PDFSkillHost?

    /// Active jobs keyed by attachment id. Holds the WKWebView strongly so
    /// it doesn't deallocate mid-render. Retain cycle is broken in
    /// `finish(_:)`.
    private var jobs: [String: PDFRenderJob] = [:]
    private let jobsLock = NSLock()

    private override init() { super.init() }

    // MARK: - Public API

    /// Kick off a render. Returns synchronously with the placeholder
    /// attachment so the caller can drop a UI cell immediately. The host's
    /// didStart/didFinish callbacks fire on main.
    @discardableResult
    func submit(title: String,
                document: String,
                template: String,
                attachmentId: String? = nil,
                conversationId: String? = nil) -> PDFAttachment {
        let id = attachmentId ?? UUID().uuidString
        let attachment = PDFAttachment(id: id,
                                       title: title,
                                       template: template,
                                       document: document,
                                       status: .generating,
                                       conversationId: conversationId)
        DispatchQueue.main.async { [weak self] in
            self?.host?.pdfSkillDidStartGenerating(attachment)
            self?.startRender(attachment: attachment)
        }
        return attachment
    }

    /// Cancel any in-flight render for this attachment (used by retry).
    func cancel(attachmentId: String) {
        jobsLock.lock()
        let job = jobs.removeValue(forKey: attachmentId)
        jobsLock.unlock()
        DispatchQueue.main.async {
            job?.cancel()
        }
    }

    /// Re-submit with the same id so the placeholder card mutates in place.
    @discardableResult
    func retry(attachmentId: String,
               title: String,
               document: String,
               template: String,
               conversationId: String? = nil) -> PDFAttachment {
        cancel(attachmentId: attachmentId)
        return submit(title: title,
                      document: document,
                      template: template,
                      attachmentId: attachmentId,
                      conversationId: conversationId)
    }

    // MARK: - Render lifecycle

    private func startRender(attachment: PDFAttachment) {
        let workspace = Workspace.shared
        let html: String
        do {
            html = try PDFGenerationService.buildHTML(attachment: attachment,
                                                      workspaceRoot: workspace.rootURL)
        } catch {
            deliverFailure("Failed to build HTML: \(error.localizedDescription)",
                           attachment: attachment)
            return
        }

        let job = PDFRenderJob(attachment: attachment, html: html, workspaceRoot: workspace.rootURL) { [weak self] outcome in
            guard let self = self else { return }
            self.finish(attachmentId: attachment.id, outcome: outcome)
        }
        jobsLock.lock()
        jobs[attachment.id] = job
        jobsLock.unlock()
        job.start()
    }

    private func finish(attachmentId: String, outcome: PDFRenderOutcome) {
        jobsLock.lock()
        jobs.removeValue(forKey: attachmentId)
        jobsLock.unlock()

        switch outcome {
        case .success(let final):
            DispatchQueue.main.async { [weak self] in
                self?.host?.pdfSkillDidFinishGenerating(final)
            }
        case .failure(let attachment, let reason):
            deliverFailure(reason, attachment: attachment)
        }
    }

    private func deliverFailure(_ message: String, attachment: PDFAttachment) {
        let failed = PDFAttachment(id: attachment.id,
                                   title: attachment.title,
                                   template: attachment.template,
                                   document: attachment.document,
                                   fileURL: nil,
                                   thumbnailURL: nil,
                                   pageCount: nil,
                                   status: .failed,
                                   failureReason: message,
                                   conversationId: attachment.conversationId)
        DispatchQueue.main.async { [weak self] in
            self?.host?.pdfSkillDidFinishGenerating(failed)
        }
    }

    // MARK: - HTML assembly

    /// Wrap the rendered markdown body in the template's HTML shell. The
    /// CSS is inlined so WKWebView doesn't have to resolve a stylesheet
    /// URL — keeps the render self-contained.
    static func buildHTML(attachment: PDFAttachment,
                          workspaceRoot: URL) throws -> String {
        let template = attachment.template
        let css = try loadTemplateCSS(named: template)
        let body = MarkdownToHTML.render(attachment.document, workspaceRoot: workspaceRoot)
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let dateString = formatter.string(from: Date())
        let escapedTitle = MarkdownToHTML.escape(attachment.title)

        // Cover block is rendered for every template; the template's CSS
        // decides whether it gets its own page (report/itinerary/letter)
        // or collapses inline (notes).
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>\(escapedTitle)</title>
            <style>
        \(css)
            </style>
        </head>
        <body>
            <section class="cover">
                <p class="cover-eyebrow">Made with Loop</p>
                <h1 class="cover-title doc-title">\(escapedTitle)</h1>
                <div class="cover-meta">
                    <span class="brand">Loop</span>
                    <span class="date">\(dateString)</span>
                </div>
            </section>
            <section class="body">
        \(body)
            </section>
        </body>
        </html>
        """
    }

    private static func loadTemplateCSS(named template: String) throws -> String {
        let bundle = Bundle.main
        // First look for the file as a normal bundled resource (preferred —
        // Xcode flattens the Templates/ folder into the bundle root by
        // default unless it's added as a folder reference).
        if let url = bundle.url(forResource: template, withExtension: "css") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        // Folder-reference fallback: if the Templates dir was added blue,
        // resources live under a Templates/ subdirectory in the bundle.
        if let url = bundle.url(forResource: template,
                                 withExtension: "css",
                                 subdirectory: "Templates") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw NSError(domain: "PDFGenerationService", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Missing bundled CSS template '\(template).css'"])
    }
}

// MARK: - Render job

/// A single in-flight render. Owns its own WKWebView + navigation delegate
/// so concurrent jobs don't cross-trigger each other's PDF capture.
private final class PDFRenderJob: NSObject, WKNavigationDelegate {

    let attachment: PDFAttachment
    let html: String
    let workspaceRoot: URL
    private let completion: (PDFRenderOutcome) -> Void

    private var webView: WKWebView?
    private var cancelled = false

    init(attachment: PDFAttachment,
         html: String,
         workspaceRoot: URL,
         completion: @escaping (PDFRenderOutcome) -> Void) {
        self.attachment = attachment
        self.html = html
        self.workspaceRoot = workspaceRoot
        self.completion = completion
    }

    func start() {
        // Letter page width at 96dpi is 8.5in × 96 = 816pt. WKWebView's
        // viewport drives layout, so sizing the offscreen frame to the page
        // width keeps line-breaks and image scaling matched to what
        // createPDF will produce.
        let pageWidthPts: CGFloat = 816
        let pageHeightPts: CGFloat = 1056   // 11in × 96dpi
        let frame = CGRect(x: 0, y: 0, width: pageWidthPts, height: pageHeightPts)

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
#if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
#endif
        self.webView = webView

        // baseURL = workspace root so relative `file://` references in
        // image tags resolve. WKWebView refuses to load local file URLs
        // without an allowed base, so this matters.
        webView.loadHTMLString(html, baseURL: workspaceRoot)
    }

    func cancel() {
        cancelled = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !cancelled else { return }
        // Wait for fonts to settle so the snapshot doesn't catch a
        // half-loaded webfont. CSS uses bundled system fonts only, so this
        // is mostly insurance against FOUT on slower devices.
        let waitJS = "document.fonts.ready.then(() => true)"
        webView.evaluateJavaScript(waitJS) { [weak self] _, _ in
            self?.capturePDF()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion(.failure(attachment, "WKWebView load failed: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion(.failure(attachment, "WKWebView load failed (provisional): \(error.localizedDescription)"))
    }

    // MARK: PDF capture

    private func capturePDF() {
        guard !cancelled, let webView = webView else { return }
        let config = WKPDFConfiguration()
        // nil rect = use page rules from CSS (which is what we want — the
        // template specifies @page size and margins, so explicit rect would
        // override the per-template Letter sizing).
        config.rect = nil

        webView.createPDF(configuration: config) { [weak self] result in
            guard let self = self, !self.cancelled else { return }
            switch result {
            case .success(let data):
                self.persistPDF(data: data)
            case .failure(let error):
                self.completion(.failure(self.attachment,
                                          "PDF capture failed: \(error.localizedDescription)"))
            }
        }
    }

    private func persistPDF(data: Data) {
        do {
            let (pdfURL, thumbURL, pageCount) = try PDFRenderJob.persist(data: data,
                                                                          attachment: attachment)
            let final = PDFAttachment(id: attachment.id,
                                      title: attachment.title,
                                      template: attachment.template,
                                      document: attachment.document,
                                      fileURL: pdfURL,
                                      thumbnailURL: thumbURL,
                                      pageCount: pageCount,
                                      status: .ready,
                                      failureReason: nil,
                                      conversationId: attachment.conversationId)
            completion(.success(final))
        } catch {
            completion(.failure(attachment,
                                "Failed to save PDF: \(error.localizedDescription)"))
        }
    }

    // MARK: Storage

    private static let pdfsSubdir = "pdfs"

    private static func persist(data: Data, attachment: PDFAttachment) throws -> (pdf: URL, thumbnail: URL?, pageCount: Int) {
        let workspace = Workspace.shared
        let dir = workspace.rootURL.appendingPathComponent(pdfsSubdir, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let slug = slugify(attachment.title)
        let datePart = filenameDateString()
        // Suffix with the attachment id so retries don't collide on disk.
        let shortId = String(attachment.id.prefix(8))
        let pdfURL = dir.appendingPathComponent("\(slug)-\(datePart)-\(shortId).pdf")
        try data.write(to: pdfURL, options: .atomic)

        // Thumbnail. PDFKit page 1 → small PNG saved next to the PDF.
        let thumbURL = dir.appendingPathComponent("\(slug)-\(datePart)-\(shortId).thumb.png")
        let pageCount = renderThumbnail(pdfData: data, to: thumbURL)
        return (pdfURL, FileManager.default.fileExists(atPath: thumbURL.path) ? thumbURL : nil, pageCount)
    }

    /// Returns the page count regardless of whether the thumbnail wrote.
    /// Thumbnail failures are non-fatal — the cell falls back to a
    /// generic doc icon.
    @discardableResult
    private static func renderThumbnail(pdfData: Data, to url: URL) -> Int {
        guard let doc = PDFDocument(data: pdfData) else { return 0 }
        let count = doc.pageCount
        guard count > 0, let page = doc.page(at: 0) else { return count }
        let pageBounds = page.bounds(for: .mediaBox)
        // Aim for a long-edge of ~480pt at 2× so the chat cell can render
        // a sharp 240×... preview. WKWebView's createPDF uses pt units, so
        // pageBounds is already in pt.
        let targetLong: CGFloat = 480
        let scale = targetLong / max(pageBounds.width, pageBounds.height)
        let size = CGSize(width: pageBounds.width * scale,
                          height: pageBounds.height * scale)
#if os(iOS)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
#elseif os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        }
#endif
        return count
    }

    // MARK: Slug helpers

    private static func slugify(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch.isWhitespace || ch == "-" || ch == "_" {
                if !out.hasSuffix("-") { out.append("-") }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "document" }
        // Cap to keep filenames reasonable.
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    private static func filenameDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

private enum PDFRenderOutcome {
    case success(PDFAttachment)
    case failure(PDFAttachment, String)
}
