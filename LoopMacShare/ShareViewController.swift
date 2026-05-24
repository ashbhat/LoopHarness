//
//  ShareViewController.swift
//  LoopShareMac (macOS Share Extension)
//
//  Mac counterpart to the iOS share extension. Appears in the system Share
//  menu of Photos, Safari, Finder, and any other app that supports
//  com.apple.share-services. Receives an image, writes it to the App Group
//  inbox, and opens LoopMac via the commandintel://share URL so the user
//  ends up at the recorder bar with the image staged.
//

import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {

    private static let urlScheme = "commandintel"
    private static let shareHost = "share"

    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Adding to Loop…")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        root.wantsLayer = true
        // No explicit fill — the system share-extension chrome paints the
        // window backdrop. Adding our own NSColor.windowBackgroundColor
        // would double-up and read as a flat panel.

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        root.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        processSharedItems()
    }

    private func processSharedItems() {
        let providers: [NSItemProvider] = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

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
            if let image = item as? NSImage,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                completion(.success((jpeg, "jpg"))); return
            }
            completion(.failure(NSError(domain: "LoopShareMac", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Couldn't read the shared image."])))
        }
    }

    private func stageAndOpenMainApp(data: Data, ext: String) {
        let filename: String
        do {
            filename = try SharedInbox.writeImage(data, suggestedExtension: ext)
        } catch {
            failAndDismiss(reason: error.localizedDescription)
            return
        }

        guard var components = URLComponents(string: "\(Self.urlScheme)://\(Self.shareHost)") else {
            completeRequest()
            return
        }
        components.queryItems = [URLQueryItem(name: "file", value: filename)]
        guard let url = components.url else { completeRequest(); return }

        // NSWorkspace.shared.open works from a macOS share extension without
        // any responder-chain gymnastics — extensions aren't sandboxed away
        // from launching apps the way iOS extensions are.
        NSWorkspace.shared.open(url)
        completeRequest()
    }

    private func failAndDismiss(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't share to Loop"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        if let window = self.view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in self?.cancelRequest() }
        } else {
            alert.runModal()
            cancelRequest()
        }
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
