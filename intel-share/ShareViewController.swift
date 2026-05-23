//
//  ShareViewController.swift
//  LoopShare (iOS Share Extension)
//
//  Receives images from the iOS Share Sheet (Photos, Safari, etc.), writes
//  them to the App Group inbox, and pings the main app via the existing
//  commandintel:// URL scheme so the image lands on the message bar with
//  the keyboard up.
//
//  Designed to be near-invisible: iOS always wraps a share extension in a
//  presentation sheet, but we render a transparent view with no chrome of
//  our own and complete the extension request the instant we hand off to
//  Loop. The user perceives "tap → Loop opens with the image staged"
//  rather than a compose/post screen.
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    /// Loop's URL scheme. The main app's SceneDelegate routes commandintel://
    /// URLs; `share` host carries the staged-filename payload.
    private static let urlScheme = "commandintel"
    private static let shareHost = "share"

    /// Guards against running the extraction twice — both viewWillAppear and
    /// viewDidAppear fire during the brief lifetime of the extension sheet.
    private var hasStarted = false

    override func loadView() {
        // Clear/empty view. No spinner, no label, no buttons — the sheet
        // will still flash on screen because the system owns its presentation
        // animation, but nothing user-facing sits inside it. Failure cases
        // surface an alert on top; the happy path completes before the sheet
        // even finishes animating in.
        let v = UIView()
        v.backgroundColor = .clear
        self.view = v
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // viewWillAppear is the earliest the view is in the window
        // hierarchy — calling app.open() through the responder chain works
        // here, but not from loadView (no window) or viewDidLoad (not yet
        // attached).
        startIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        processSharedItems()
    }

    private func processSharedItems() {
        let providers: [NSItemProvider] = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        // Prefer the first image provider. Safari sometimes hands us both a
        // webpage URL and an image — the image wins because that's what we
        // want to attach.
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            failAndDismiss(reason: "No image found in shared content.")
            return
        }

        loadImageData(from: provider) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let (data, ext)):
                    self.stageAndOpenMainApp(data: data, ext: ext)
                case .failure(let error):
                    self.failAndDismiss(reason: error.localizedDescription)
                }
            }
        }
    }

    /// NSItemProvider hands the image back as either Data, UIImage, or a
    /// file URL depending on which app shared it. Try each path in order so
    /// we get the original bytes (and original file extension) whenever
    /// possible — re-encoding via UIImage.jpegData throws away EXIF and
    /// inflates file size for screenshots.
    private func loadImageData(from provider: NSItemProvider,
                               completion: @escaping (Result<(Data, String), Error>) -> Void) {
        let imageType = UTType.image.identifier

        provider.loadItem(forTypeIdentifier: imageType, options: nil) { (item, error) in
            if let error = error {
                completion(.failure(error)); return
            }
            if let url = item as? URL, url.isFileURL {
                do {
                    let data = try Data(contentsOf: url)
                    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
                    completion(.success((data, ext))); return
                } catch {
                    completion(.failure(error)); return
                }
            }
            if let data = item as? Data {
                completion(.success((data, "jpg"))); return
            }
            if let image = item as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                completion(.success((data, "jpg"))); return
            }
            completion(.failure(NSError(domain: "LoopShare", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Couldn't read the shared image."])))
        }
    }

    private func stageAndOpenMainApp(data: Data, ext: String) {
        // Save to App Group inbox; the main app reads from here on URL handoff
        // (or as a fallback, on the next foreground enter).
        let filename: String
        do {
            filename = try SharedInbox.writeImage(data, suggestedExtension: ext)
        } catch {
            failAndDismiss(reason: error.localizedDescription)
            return
        }

        guard var components = URLComponents(string: "\(Self.urlScheme)://\(Self.shareHost)") else {
            // No URL = can't ping the main app, but the file's already in
            // the App Group inbox so the next foreground will pick it up.
            // Treat as a soft success and dismiss.
            completeRequest()
            return
        }
        components.queryItems = [URLQueryItem(name: "file", value: filename)]
        guard let url = components.url else {
            completeRequest()
            return
        }

        openMainApp(url: url) { [weak self] _ in
            // Complete the extension request immediately after open(). On
            // success the system tears down our sheet and brings Loop
            // forward; on failure the inbox drain on next foreground will
            // pick the file up.
            self?.completeRequest()
        }
    }

    /// Walks the responder chain to find a `UIApplication` and calls its
    /// `open(_:)`. iOS deprecated direct app-launching for share extensions
    /// in modern SDKs (`extensionContext.open` only works for some types),
    /// but responder-chain lookup remains the standard escape hatch used by
    /// most share extensions in the wild — see e.g. the Reddit, Notion, and
    /// Drafts share extensions.
    private func openMainApp(url: URL, completion: @escaping (Bool) -> Void) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:]) { ok in completion(ok) }
                return
            }
            responder = r.next
        }
        completion(false)
    }

    private func failAndDismiss(reason: String) {
        // Only surface UI on the failure path — happy path stays silent.
        let alert = UIAlertController(title: "Couldn't share to Loop",
                                      message: reason,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.cancelRequest()
        })
        present(alert, animated: true)
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancelRequest() {
        let cancel = NSError(domain: NSCocoaErrorDomain,
                             code: NSUserCancelledError,
                             userInfo: nil)
        extensionContext?.cancelRequest(withError: cancel)
    }
}
