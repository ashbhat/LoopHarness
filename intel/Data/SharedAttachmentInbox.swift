//
//  SharedAttachmentInbox.swift
//  intel
//
//  One-slot inbox the SceneDelegate uses to hand a freshly-shared
//  attachment to MessagingVC when the share-in URL arrives before
//  the view controller has loaded (cold start). MessagingVC drains
//  the inbox in `viewDidLoad`; later shares (warm path) skip the
//  inbox entirely and call `MessagingVC.stageIncomingAttachment`
//  directly.
//

import Foundation

final class SharedAttachmentInbox {
    static let shared = SharedAttachmentInbox()
    private init() {}

    /// Set by the SceneDelegate's share-in handler; read once by
    /// MessagingVC's viewDidLoad. Drained on read so the same file
    /// isn't re-staged on subsequent view reloads.
    var pending: FileAttachment?

    /// Atomically read + clear the inbox. Use over a bare property
    /// access so two competing MessagingVC instances couldn't both
    /// pick up the same attachment.
    func drain() -> FileAttachment? {
        let p = pending
        pending = nil
        return p
    }
}
