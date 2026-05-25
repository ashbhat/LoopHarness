//
//  SharedAttachmentInbox.swift
//  Loop
//
//  Queue the SceneDelegate uses to hand freshly-shared attachments to
//  MessagingVC when the share-in URL arrives before the view controller
//  has loaded (cold start). MessagingVC drains the queue in `viewDidLoad`;
//  later shares (warm path) skip the queue entirely and call
//  `MessagingVC.stageIncomingAttachment` directly.
//
//  Why a queue (not a single slot): the share-in path runs twice on cold
//  start — once when the launch URL arrives in `connectionOptions.urlContexts`,
//  again when `sceneDidBecomeActive` does its safety-net inbox drain. A
//  single-slot box would silently clobber the first attachment with the
//  second. Multiple shares in quick succession have the same failure mode.
//

import Foundation

final class SharedAttachmentInbox {
    static let shared = SharedAttachmentInbox()
    private init() {}

    /// FIFO of attachments waiting for MessagingVC to be on screen. Pushed by
    /// the SceneDelegate's share-in handler; drained by MessagingVC's
    /// `viewDidLoad`. Mutations are serialized through `queue` so a foreground
    /// drain (main thread) can't race with a viewDidLoad pickup.
    private var pending: [FileAttachment] = []
    private let queue = DispatchQueue(label: "loop.sharedattachmentinbox")

    /// Append an attachment to the queue. Idempotent on `id` so a re-drain
    /// of the same App Group file doesn't double-enqueue the same bytes.
    func enqueue(_ attachment: FileAttachment) {
        queue.sync {
            guard !pending.contains(where: { $0.id == attachment.id }) else { return }
            pending.append(attachment)
        }
    }

    /// Atomically read + clear the queue. MessagingVC calls this once it's
    /// ready to stage the attachments, so the same files aren't re-staged on
    /// subsequent view reloads.
    func drainAll() -> [FileAttachment] {
        return queue.sync {
            let snapshot = pending
            pending.removeAll()
            return snapshot
        }
    }
}
